import Accelerate
import CoreML
import Foundation

/// GigaAM v4 e2e RNN-T as native Core ML (`ilsvls/gigaam-v4-coreml` FP16 or quantized INT8 W8A16):
/// the Conformer encoder (`stage-00.mlpackage`) runs on Apple Neural Engine (macOS 15+, including
/// macOS 26/27), while the lightweight log-mel frontend and `e2e.f32` RNN-T head run on the CPU
/// using Accelerate BLAS/vDSP. Bilingual (`ru` + `en`, auto) with punctuation.
/// Instances are not thread-safe; the caller serializes calls (`LocalSpeechRecognizer`'s queue).
struct CoreMLGigaAMV4Model: Equatable, Sendable {
    var encoder: URL
    var runtime: URL
    var window: URL
    var mel: URL
    var head: URL
    var cache: URL
    var computeUnits: MLComputeUnits = .cpuAndNeuralEngine

    static func == (a: Self, b: Self) -> Bool {
        a.encoder == b.encoder && a.runtime == b.runtime && a.window == b.window &&
            a.mel == b.mel && a.head == b.head && a.cache == b.cache &&
            a.computeUnits == b.computeUnits
    }
}

enum CoreMLGigaAMV4Error: LocalizedError, Equatable {
    case badRuntime
    case badHeadWeights(String)
    case badOutput(String)
    case missingModelFiles(String)

    var errorDescription: String? {
        switch self {
        case .badRuntime:
            return L("CoreML GigaAM v4 runtime metadata could not be read.")
        case .badHeadWeights(let detail):
            return L("CoreML GigaAM v4 weights failed validation (%@).", detail)
        case .badOutput(let stage):
            return L("CoreML GigaAM inference failed at %@.", stage)
        case .missingModelFiles(let name):
            return L("CoreML GigaAM model file is missing: %@.", name)
        }
    }
}

final class CoreMLGigaAMV4Recognizer {
    static let sampleRate = 16_000
    static let fft = 320
    static let hop = 160
    static let bins = 161
    static let mels = 64
    static let maxMelFrames = 1024
    static let maxValidMelFrames = 1000
    static let maxSymbolsPerFrame = 3
    static let maxChunkSamples = 158_400

    private let encoder: MLModel
    private let frontEnd: GigaAMV4FrontEnd
    private let head: GigaAMV4RNNTHead
    let loadSeconds: TimeInterval

    init(_ model: CoreMLGigaAMV4Model) throws {
        let started = ProcessInfo.processInfo.systemUptime
        for url in [model.encoder, model.runtime, model.window, model.mel, model.head]
        where !FileManager.default.fileExists(atPath: url.path) {
            throw CoreMLGigaAMV4Error.missingModelFiles(url.lastPathComponent)
        }

        let runtimeData = try Data(contentsOf: model.runtime)
        let runtime = try JSONDecoder().decode(GigaAMV4RuntimeConfig.self, from: runtimeData)
        guard let e2e = runtime.heads["e2e"],
              e2e.shapes.count == 11,
              !e2e.pieces.isEmpty,
              runtime.encoderWidth > 0 else {
            throw CoreMLGigaAMV4Error.badRuntime
        }

        let windowFloats = try Self.loadFloat32Array(from: model.window, expectedCount: Self.fft, name: "window.f32")
        let melFloats = try Self.loadFloat32Array(from: model.mel, expectedCount: Self.mels * Self.bins, name: "mel.f32")
        let expectedHeadCount = e2e.shapes.reduce(0) { $0 + $1.reduce(1, *) }
        let headFloats = try Self.loadFloat32Array(from: model.head, expectedCount: expectedHeadCount, name: "e2e.f32")

        frontEnd = GigaAMV4FrontEnd(window: windowFloats, melBank: melFloats)
        head = try GigaAMV4RNNTHead(
            weights: headFloats,
            shapes: e2e.shapes,
            encoderWidth: runtime.encoderWidth,
            pieces: e2e.pieces
        )
        encoder = try Self.compileAndLoadEncoder(package: model.encoder, cache: model.cache, preferredUnits: model.computeUnits)
        loadSeconds = ProcessInfo.processInfo.systemUptime - started
    }

    private static func loadFloat32Array(from url: URL, expectedCount: Int, name: String) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count == expectedCount * MemoryLayout<Float>.size else {
            throw CoreMLGigaAMV4Error.badHeadWeights(name)
        }
        return data.withUnsafeBytes { raw in
            var result = [Float](repeating: 0, count: expectedCount)
            raw.copyBytes(to: UnsafeMutableBufferPointer(start: &result, count: expectedCount))
            return result
        }
    }

    private static func compileAndLoadEncoder(package: URL, cache: URL, preferredUnits: MLComputeUnits) throws -> MLModel {
        let compiledURL = try CoreMLGigaAMRecognizer.compiled(package, cache: cache)
        do {
            return try loadEncoder(at: compiledURL, preferredUnits: preferredUnits)
        } catch {
            try? FileManager.default.removeItem(at: compiledURL)
            let rebuilt = try CoreMLGigaAMRecognizer.compiled(package, cache: cache)
            return try loadEncoder(at: rebuilt, preferredUnits: preferredUnits)
        }
    }

    private static func loadEncoder(at compiledURL: URL, preferredUnits: MLComputeUnits) throws -> MLModel {
        let preferred = MLModelConfiguration()
        preferred.computeUnits = preferredUnits
        do {
            return try MLModel(contentsOf: compiledURL, configuration: preferred)
        } catch {
            guard preferredUnits != .cpuOnly else { throw error }
            let fallback = MLModelConfiguration()
            fallback.computeUnits = .cpuOnly
            return try MLModel(contentsOf: compiledURL, configuration: fallback)
        }
    }

    /// Transcribes one utterance of 16 kHz mono speech using pause-aware <= 9.9 s chunks.
    func transcribe(_ samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        let chunks = Self.splitChunksPauseAware(samples)
        var parts: [String] = []
        parts.reserveCapacity(chunks.count)
        for chunk in chunks where !chunk.isEmpty {
            let text = try autoreleasepool { try decodeChunk(chunk) }
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeChunk(_ samples: [Float]) throws -> String {
        let featType = encoder.modelDescription.inputDescriptionsByName["features"]?.multiArrayConstraint?.dataType ?? .float16
        let maskType = encoder.modelDescription.inputDescriptionsByName["mask"]?.multiArrayConstraint?.dataType ?? .float16
        let (features, mask, validMelFrames) = try frontEnd.featuresAndMask(
            samples,
            featuresType: featType,
            maskType: maskType
        )
        let provider = try MLDictionaryFeatureProvider(dictionary: ["features": features, "mask": mask])
        let out = try encoder.prediction(from: provider)
        guard let encoded = out.featureValue(for: "encoded")?.multiArrayValue,
              encoded.shape.count == 3 else {
            throw CoreMLGigaAMV4Error.badOutput("encoder")
        }
        let maxTimeSteps = encoded.shape[2].intValue
        let validEncFrames = min(maxTimeSteps, max(1, (validMelFrames + 3) / 4))
        let ids = try head.decode(encoded: encoded, validFrames: validEncFrames)
        return CoreMLGigaAMRecognizer.detokenize(ids, pieces: head.pieces)
    }

    /// Splits speech longer than ~9.9 s near the quietest 200 ms pause between 6.0 s and 9.8 s.
    static func splitChunksPauseAware(_ samples: [Float]) -> [[Float]] {
        guard samples.count > maxChunkSamples else { return [samples] }
        var chunks: [[Float]] = []
        var start = 0
        let win = Int(0.2 * Double(sampleRate))
        let hop = Int(0.05 * Double(sampleRate))
        let searchMinOffset = Int(6.0 * Double(sampleRate))
        let searchMaxOffset = Int(9.8 * Double(sampleRate))

        while start < samples.count {
            if samples.count - start <= maxChunkSamples {
                chunks.append(Array(samples[start...]))
                break
            }
            let searchStart = start + searchMinOffset
            let searchEnd = min(samples.count - win, start + searchMaxOffset)
            var bestSplit = start + maxChunkSamples
            var bestEnergy = Float.infinity
            if searchStart <= searchEnd {
                samples.withUnsafeBufferPointer { buf in
                    var pos = searchStart
                    while pos <= searchEnd {
                        var energy: Float = 0
                        vDSP_dotpr(buf.baseAddress! + pos, 1, buf.baseAddress! + pos, 1, &energy, vDSP_Length(win))
                        if energy < bestEnergy {
                            bestEnergy = energy
                            bestSplit = pos + win / 2
                        }
                        pos += hop
                    }
                }
            }
            chunks.append(Array(samples[start..<bestSplit]))
            start = bestSplit
        }
        return chunks
    }
}

private struct GigaAMV4RuntimeConfig: Decodable {
    struct HeadConfig: Decodable {
        let shapes: [[Int]]
        let pieces: [String]
    }
    let encoderWidth: Int
    let heads: [String: HeadConfig]
}

final class GigaAMV4FrontEnd {
    static let fft = CoreMLGigaAMV4Recognizer.fft
    static let hop = CoreMLGigaAMV4Recognizer.hop
    static let bins = CoreMLGigaAMV4Recognizer.bins
    static let mels = CoreMLGigaAMV4Recognizer.mels
    static let maxMelFrames = CoreMLGigaAMV4Recognizer.maxMelFrames
    static let maxValidMelFrames = CoreMLGigaAMV4Recognizer.maxValidMelFrames

    private let window: [Float]
    private let cosines: [Float] // [bins, fft]
    private let sines: [Float]   // [bins, fft]
    private let melBank: [Float] // [mels, bins]

    init(window: [Float], melBank: [Float]) {
        self.window = window
        self.melBank = melBank
        var cosBuf = [Float](repeating: 0, count: Self.bins * Self.fft)
        var sinBuf = [Float](repeating: 0, count: Self.bins * Self.fft)
        for k in 0..<Self.bins {
            for j in 0..<Self.fft {
                let angle = 2.0 * Double.pi * Double(k * j % Self.fft) / Double(Self.fft)
                cosBuf[k * Self.fft + j] = Float(cos(angle))
                sinBuf[k * Self.fft + j] = Float(sin(angle))
            }
        }
        self.cosines = cosBuf
        self.sines = sinBuf
    }

    func featuresAndMask(
        _ samples: [Float],
        featuresType: MLMultiArrayDataType,
        maskType: MLMultiArrayDataType
    ) throws -> (features: MLMultiArray, mask: MLMultiArray, validMelFrames: Int) {
        let validSamples = min(samples.count, (Self.maxValidMelFrames - 1) * Self.hop + Self.fft)
        let validFrames: Int
        if validSamples >= Self.fft {
            validFrames = max(1, min(Self.maxMelFrames, (validSamples - Self.fft) / Self.hop + 1))
        } else {
            validFrames = 1
        }
        var padded = [Float](repeating: 0, count: (validFrames - 1) * Self.hop + Self.fft)
        let copyCount = min(validSamples, padded.count)
        if copyCount > 0 {
            padded.replaceSubrange(0..<copyCount, with: samples.prefix(copyCount))
        }

        let n = Self.fft
        var framed = [Float](repeating: 0, count: validFrames * n)
        padded.withUnsafeBufferPointer { src in
            for f in 0..<validFrames {
                vDSP_vmul(src.baseAddress! + f * Self.hop, 1, window, 1, &framed[f * n], 1, vDSP_Length(n))
            }
        }
        var real = [Float](repeating: 0, count: validFrames * Self.bins)
        var imag = [Float](repeating: 0, count: validFrames * Self.bins)
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasTrans,
            Int32(validFrames), Int32(Self.bins), Int32(n),
            1.0, framed, Int32(n), cosines, Int32(n), 0.0, &real, Int32(Self.bins)
        )
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasTrans,
            Int32(validFrames), Int32(Self.bins), Int32(n),
            1.0, framed, Int32(n), sines, Int32(n), 0.0, &imag, Int32(Self.bins)
        )
        var power = [Float](repeating: 0, count: validFrames * Self.bins)
        vDSP_vmul(real, 1, real, 1, &power, 1, vDSP_Length(power.count))
        vDSP_vma(imag, 1, imag, 1, power, 1, &power, 1, vDSP_Length(power.count))

        var melOut = [Float](repeating: 0, count: Self.mels * validFrames)
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasTrans,
            Int32(Self.mels), Int32(validFrames), Int32(Self.bins),
            1.0, melBank, Int32(Self.bins), power, Int32(Self.bins), 0.0, &melOut, Int32(validFrames)
        )
        var low: Float = 1e-9, high: Float = 1e9
        vDSP_vclip(melOut, 1, &low, &high, &melOut, 1, vDSP_Length(melOut.count))
        var cnt = Int32(melOut.count)
        vvlogf(&melOut, melOut, &cnt)

        let actualFeatType: MLMultiArrayDataType = (featuresType == .float32) ? .float32 : .float16
        let featArray = try MLMultiArray(
            shape: [1, NSNumber(value: Self.mels), NSNumber(value: Self.maxMelFrames)],
            dataType: actualFeatType
        )
        let fS1 = featArray.strides[1].intValue
        let fS2 = featArray.strides[2].intValue
        let fCount = max(0, (Self.mels - 1) * fS1 + (Self.maxMelFrames - 1) * fS2 + 1)
        featArray.withUnsafeMutableBytes { raw, _ in
            if actualFeatType == .float32 {
                let dst = raw.bindMemory(to: Float.self)
                for i in 0..<fCount { dst[i] = 0 }
                for m in 0..<Self.mels {
                    let srcBase = m * validFrames
                    let dstBase = m * fS1
                    for f in 0..<validFrames {
                        dst[dstBase + f * fS2] = melOut[srcBase + f]
                    }
                }
            } else {
                #if arch(arm64)
                let dst = raw.bindMemory(to: Float16.self)
                for i in 0..<fCount { dst[i] = 0 }
                for m in 0..<Self.mels {
                    let srcBase = m * validFrames
                    let dstBase = m * fS1
                    for f in 0..<validFrames {
                        dst[dstBase + f * fS2] = Float16(melOut[srcBase + f])
                    }
                }
                #endif
            }
        }

        let actualMaskType: MLMultiArrayDataType = (maskType == .float32) ? .float32 : .float16
        let maskArray = try MLMultiArray(shape: [1, NSNumber(value: Self.maxMelFrames)], dataType: actualMaskType)
        let mS1 = maskArray.strides[1].intValue
        let mCount = max(0, (Self.maxMelFrames - 1) * mS1 + 1)
        maskArray.withUnsafeMutableBytes { raw, _ in
            if actualMaskType == .float32 {
                let dst = raw.bindMemory(to: Float.self)
                for i in 0..<mCount { dst[i] = 0 }
                for f in 0..<validFrames { dst[f * mS1] = 1.0 }
            } else {
                #if arch(arm64)
                let dst = raw.bindMemory(to: Float16.self)
                for i in 0..<mCount { dst[i] = 0 }
                for f in 0..<validFrames { dst[f * mS1] = 1.0 }
                #endif
            }
        }

        return (featArray, maskArray, validFrames)
    }
}

private final class GigaAMV4RNNTHead {
    let vocabPlusBlank: Int
    let blank: Int
    let predDim: Int
    let encWidth: Int
    let pieces: [String]

    private let embed: [Float]
    private let wIH: [Float]
    private let wHH: [Float]
    private let bIH: [Float]
    private let bHH: [Float]
    private let jEncW: [Float]
    private let jEncB: [Float]
    private let jPredW: [Float]
    private let jPredB: [Float]
    private let jOutW: [Float]
    private let jOutB: [Float]

    init(weights: [Float], shapes: [[Int]], encoderWidth: Int, pieces: [String]) throws {
        guard shapes.count == 11 else { throw CoreMLGigaAMV4Error.badRuntime }
        self.encWidth = encoderWidth
        self.pieces = pieces
        self.blank = pieces.count
        self.vocabPlusBlank = shapes[0][0]
        self.predDim = shapes[0][1]
        guard vocabPlusBlank > blank,
              shapes[5] == [predDim, encoderWidth],
              shapes[7] == [predDim, predDim],
              shapes[9] == [vocabPlusBlank, predDim] else {
            throw CoreMLGigaAMV4Error.badRuntime
        }

        var slices: [[Float]] = []
        slices.reserveCapacity(11)
        var offset = 0
        for shape in shapes {
            let count = shape.reduce(1, *)
            guard offset + count <= weights.count else { throw CoreMLGigaAMV4Error.badHeadWeights("truncated") }
            slices.append(Array(weights[offset..<(offset + count)]))
            offset += count
        }
        embed = slices[0]
        wIH = slices[1]
        wHH = slices[2]
        bIH = slices[3]
        bHH = slices[4]
        jEncW = slices[5]
        jEncB = slices[6]
        jPredW = slices[7]
        jPredB = slices[8]
        jOutW = slices[9]
        jOutB = slices[10]
    }

    private func lstmStep(input: [Float], h: inout [Float], c: inout [Float]) -> [Float] {
        var gates = [Float](repeating: 0, count: 4 * predDim)
        for idx in 0..<(4 * predDim) { gates[idx] = bIH[idx] + bHH[idx] }
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(4 * predDim), Int32(predDim),
                    1.0, wIH, Int32(predDim), input, 1, 1.0, &gates, 1)
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(4 * predDim), Int32(predDim),
                    1.0, wHH, Int32(predDim), h, 1, 1.0, &gates, 1)

        var newH = [Float](repeating: 0, count: predDim)
        var newC = [Float](repeating: 0, count: predDim)
        for j in 0..<predDim {
            let i = 1.0 / (1.0 + exp(-gates[j]))
            let f = 1.0 / (1.0 + exp(-gates[predDim + j]))
            let g = tanh(gates[2 * predDim + j])
            let o = 1.0 / (1.0 + exp(-gates[3 * predDim + j]))
            let cj = f * c[j] + i * g
            newC[j] = cj
            newH[j] = o * tanh(cj)
        }
        h = newH
        c = newC
        return newH
    }

    func decode(encoded: MLMultiArray, validFrames: Int) throws -> [Int] {
        guard encoded.shape[1].intValue == encWidth else {
            throw CoreMLGigaAMV4Error.badOutput("encoder-shape")
        }
        let encodedStorage = CoreMLGigaAMRecognizer.floats(encoded)
        let s1 = encoded.strides[1].intValue
        let s2 = encoded.strides[2].intValue

        var h = [Float](repeating: 0, count: predDim)
        var c = [Float](repeating: 0, count: predDim)
        var decOut = lstmStep(input: [Float](repeating: 0, count: predDim), h: &h, c: &c)

        var projDec = [Float](repeating: 0, count: predDim)
        var projEnc = [Float](repeating: 0, count: predDim)
        var hidden = [Float](repeating: 0, count: predDim)
        var logits = [Float](repeating: 0, count: vocabPlusBlank)
        var encT = [Float](repeating: 0, count: encWidth)

        func updatePredProj() {
            projDec = jPredB
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(predDim), Int32(predDim),
                        1.0, jPredW, Int32(predDim), decOut, 1, 1.0, &projDec, 1)
        }
        updatePredProj()

        var ids: [Int] = []
        for t in 0..<validFrames {
            for d in 0..<encWidth {
                encT[d] = encodedStorage[d * s1 + t * s2]
            }
            projEnc = jEncB
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(predDim), Int32(encWidth),
                        1.0, jEncW, Int32(encWidth), encT, 1, 1.0, &projEnc, 1)

            for _ in 0..<CoreMLGigaAMV4Recognizer.maxSymbolsPerFrame {
                for j in 0..<predDim {
                    let v = projEnc[j] + projDec[j]
                    hidden[j] = v > 0 ? v : 0
                }
                logits = jOutB
                cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(vocabPlusBlank), Int32(predDim),
                            1.0, jOutW, Int32(predDim), hidden, 1, 1.0, &logits, 1)
                var best = 0
                var bestVal: Float = -Float.infinity
                for idx in 0..<vocabPlusBlank where logits[idx] > bestVal {
                    bestVal = logits[idx]
                    best = idx
                }
                if best == blank { break }
                ids.append(best)
                let embStart = best * predDim
                let embVec = Array(embed[embStart..<(embStart + predDim)])
                decOut = lstmStep(input: embVec, h: &h, c: &c)
                updatePredProj()
            }
        }
        return ids
    }
}
