import AppKit
import AVFoundation
import CoreML
import CoreVideo
import XCTest
@testable import MeetingEngine
@testable import RockNativeDesktop

/// Native Core ML GigaAM: tokens to text, the mel front-end against torchaudio, the
/// recognizer against the conversion's own Python loop, and the meeting pipeline.
/// Model-backed tests need `.build/asr-bench` (asr_bench.py --fleurs 1, the catalog's
/// gigaam-v3-e2e-rnnt-coreml under models/, and gigaam_coreml_reference.py).
@MainActor final class CoreMLGigaAMTests: XCTestCase {
    private var bench: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/asr-bench")
    }
    private var modelFolder: URL { bench.appendingPathComponent("models/gigaam-v3-e2e-rnnt-coreml") }
    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gigaam-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func model(_ units: MLComputeUnits, cache: URL) throws -> CoreMLGigaAMModel {
        guard FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent("tokens.json").path) else {
            throw XCTSkip("Download gigaam-v3-e2e-rnnt-coreml into .build/asr-bench/models first")
        }
        return .init(encoder: modelFolder.appendingPathComponent("GigaAMv3Encoder.mlpackage"),
                     decoder: modelFolder.appendingPathComponent("GigaAMv3DecoderStep.mlpackage"),
                     joint: modelFolder.appendingPathComponent("GigaAMv3JointStep.mlpackage"),
                     tokens: modelFolder.appendingPathComponent("tokens.json"), cache: cache, computeUnits: units)
    }
    private func sample() throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: bench.appendingPathComponent("sample-ru.wav")),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XCTSkip("Run Experiments/ASRBench/asr_bench.py --fleurs 1 first")
        }
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        // One read can return fewer frames than asked; read to the end.
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        XCTAssertEqual(samples.count, Int(file.length))
        return samples
    }

    /// The launch warm-up relies on this: once the Neural Engine model was loaded in this
    /// process, loading it again after it was freed is fast.
    func testReloadAfterFreeingIsFast() throws {
        let configuration = try model(.cpuAndNeuralEngine, cache: temporaryFolder())
        var first: CoreMLGigaAMRecognizer? = try CoreMLGigaAMRecognizer(configuration)
        let firstSeconds = first!.loadSeconds
        first = nil
        let second = try CoreMLGigaAMRecognizer(configuration)
        print("COREML-LOAD first \(firstSeconds) s, after freeing \(second.loadSeconds) s")
        XCTAssertLessThan(second.loadSeconds, 2)
    }

    func testTokensBecomeTextWithWordStartsAndByteFallback() {
        let pieces = ["▁При", "вет", ",", "▁мир", "<0xE2>", "<0x80>", "<0x94>", "!"]
        XCTAssertEqual(CoreMLGigaAMRecognizer.detokenize([0, 1, 2, 3], pieces: pieces), "Привет, мир")
        XCTAssertEqual(CoreMLGigaAMRecognizer.detokenize([3, 4, 5, 6, 7], pieces: pieces), "мир—!", "Byte pieces join into UTF-8")
        XCTAssertEqual(CoreMLGigaAMRecognizer.detokenize([], pieces: pieces), "")
    }

    func testMelFiltersMatchTheHTKScale() {
        let filters = GigaAMMelFrontEnd.melFilters()
        XCTAssertEqual(filters.count, 161 * 64)
        // The lowest bands are narrower than one FFT bin, so their peaks sit between bins.
        for m in 0..<64 { XCTAssertGreaterThan((0..<161).map { filters[$0 * 64 + m] }.max()!, 0.1, "band \(m) has a peak") }
        XCTAssertEqual((0..<64).map { filters[$0] }.max()!, 0, "DC belongs to no band")
    }

    /// The Swift front-end against torchaudio on the same 30 s window.
    func testMelFeaturesMatchTorchaudio() throws {
        let reference = bench.appendingPathComponent("sample-ru.gigaam-mel.f32")
        guard let data = try? Data(contentsOf: reference) else { throw XCTSkip("Run Experiments/ASRBench/gigaam_coreml_reference.py first") }
        let expected = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let frames = CoreMLGigaAMRecognizer.melFrames
        XCTAssertEqual(expected.count, 64 * frames)
        let array = try GigaAMMelFrontEnd().features(try sample(), frames: frames, window: CoreMLGigaAMRecognizer.window)
        let strides = array.strides.map(\.intValue)
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        // Where a band holds next to no energy, rounding noise is magnified by the log (and
        // one side may hit the 1e-9 clamp); compare where the band carries signal (> e^-10).
        var maxDiff: Float = 0, sumDiff: Float = 0, cells = 0, quiet = 0
        for m in 0..<64 {
            for f in 0..<frames {
                let reference = expected[m * frames + f]
                guard reference > -10 else { quiet += 1; continue }
                let diff = abs(pointer[m * strides[1] + f * strides[2]] - reference)
                maxDiff = max(maxDiff, diff); sumDiff += diff; cells += 1
            }
        }
        let meanDiff = sumDiff / Float(max(1, cells))
        print("GIGAAM-MEL compared \(cells) cells (\(quiet) near-silent skipped): max \(maxDiff) mean \(meanDiff)")
        XCTAssertGreaterThan(cells, 10_000, "8 s of speech gives many cells with energy")
        XCTAssertLessThan(meanDiff, 1e-3); XCTAssertLessThan(maxDiff, 0.05)
    }

    /// CPU and GPU reproduce the conversion's reference transcript exactly; the Neural
    /// Engine may flip a borderline token, so it must keep the meaning.
    func testRecognizerMatchesTheReferenceTranscript() throws {
        guard let reference = try? String(contentsOf: bench.appendingPathComponent("sample-ru.gigaam-coreml.txt"), encoding: .utf8) else {
            throw XCTSkip("Run Experiments/ASRBench/gigaam_coreml_reference.py first")
        }
        let speech = try sample(), cache = temporaryFolder()
        let exact = try CoreMLGigaAMRecognizer(model(.cpuAndGPU, cache: cache))
        XCTAssertEqual(try exact.transcribe(speech), reference.trimmingCharacters(in: .whitespacesAndNewlines))
        let started = ProcessInfo.processInfo.systemUptime
        let neural = try CoreMLGigaAMRecognizer(model(.cpuAndNeuralEngine, cache: cache))
        let loaded = ProcessInfo.processInfo.systemUptime - started
        let decodeStart = ProcessInfo.processInfo.systemUptime
        let text = try neural.transcribe(speech)
        let decode = ProcessInfo.processInfo.systemUptime - decodeStart
        print("GIGAAM-ANE load \(loaded) s decode \(decode) s for \(Double(speech.count) / 16_000) s: \(text)")
        XCTAssertTrue(text.contains("Молдавии") && text.contains("православное"), text)
        XCTAssertEqual(try neural.transcribe([]), "")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).contains { $0.hasSuffix(".mlmodelc") },
                      "Compiled models are kept for the next launch")
    }

    /// The meeting pipeline on the Neural Engine model: VAD, recognizer queue, one line.
    func testMeetingTranscriberRunsTheNeuralEngineModel() async throws {
        let vad = bench.appendingPathComponent("models/silero-vad/silero_vad.onnx")
        guard FileManager.default.fileExists(atPath: vad.path) else { throw XCTSkip("Run Experiments/ASRBench/asr_bench.py --fleurs 1 first") }
        let audio = [Float](repeating: 0, count: 16_000) + (try sample()) + [Float](repeating: 0, count: 16_000)
        final class Lines: @unchecked Sendable { var value: [MeetingTranscriber.Line] = [] }
        let box = Lines(), recognizer = LocalSpeechRecognizer()
        let configured = ListenRecognizerModel.coreMLGigaAM(try model(.cpuAndNeuralEngine, cache: temporaryFolder()))
        recognizer.prepare(configured)
        let transcriber = MeetingTranscriber(model: configured, vadModel: vad, recognizer: recognizer) { box.value.append($0) }
        for offset in stride(from: 0, to: audio.count, by: 160) {
            transcriber.feedForTesting(trackID: "TR_a", samples: Array(audio[offset..<min(audio.count, offset + 160)]))
        }
        transcriber.feedForTesting(trackID: "TR_a", samples: [], end: true)
        for _ in 0..<1500 where box.value.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let line = try XCTUnwrap(box.value.first)
        XCTAssertTrue(line.text.contains("Молдавии"), line.text)
        XCTAssertEqual(box.value.count, 1)
        transcriber.stop()
    }

    /// The Neural Engine model is the default, but someone already transcribing with the
    /// previous default (never chosen explicitly) keeps it until the new one is installed.
    func testNewDefaultDoesNotStopSomeoneUsingThePreviousOne() async throws {
        XCTAssertEqual(ListenModelStore.defaultModel, "gigaam-v4-coreml-int8")
        XCTAssertNotNil(ListenModelCatalog.bundled.model(ListenModelStore.previousDefaultModel))
        let source = temporaryFolder(), root = temporaryFolder()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        func file(_ name: String) throws -> ListenModelCatalog.File {
            let url = source.appendingPathComponent(UUID().uuidString); try Data(name.utf8).write(to: url)
            return .init(name: name, size: Int64(name.utf8.count), url: url, sha256: try ListenModelStore.sha256(of: url))
        }
        func model(_ id: String, kind: String) throws -> ListenModelCatalog.Model {
            if kind == ListenModelStore.coreMLGigaAMV4Kind {
                return .init(id: id, role: "listen", title: id, kind: kind, featureDim: 64, languages: ["ru", "en"], licence: "MIT", source: source,
                             files: [try file("runtime.json"), try file("window.f32"), try file("mel.f32"), try file("e2e.f32"),
                                     try file("encoder-1024/stage-00.mlpackage/Manifest.json")],
                             config: ["encoder": "encoder-1024/stage-00.mlpackage", "runtime": "runtime.json", "window": "window.f32", "mel": "mel.f32", "head": "e2e.f32"])
            }
            return .init(id: id, role: "listen", title: id, kind: kind, featureDim: 64, languages: ["ru"], licence: "MIT", source: source,
                         files: [try file("m.bin"), try file("tokens.txt")], config: ["model": "m.bin", "tokens": "tokens.txt"])
        }
        let catalog = ListenModelCatalog(schemaVersion: 1, runtime: "test", models: [
            try model(ListenModelStore.previousDefaultModel, kind: "nemo_ctc"),
            try model(ListenModelStore.defaultModel, kind: ListenModelStore.coreMLGigaAMV4Kind)])
        func store() -> ListenModelStore { .init(catalog: catalog, root: root, defaults: UserDefaults(suiteName: "listen-\(UUID())")!) }

        XCTAssertEqual(store().selectedID, ListenModelStore.defaultModel, "A new user gets the GigaAM v4 INT8 model")
        let first = store(), previous = catalog.models[0], current = catalog.models[1]
        first.download(previous)
        for _ in 0..<200 where !first.state(previous).installed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store().selectedID, ListenModelStore.previousDefaultModel, "An existing user keeps transcribing")
        first.download(current)
        for _ in 0..<200 where !first.state(current).installed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store().selectedID, ListenModelStore.defaultModel, "Once downloaded, the new default is used")
        let chosen = UserDefaults(suiteName: "listen-\(UUID())")!
        chosen.set(ListenModelStore.previousDefaultModel, forKey: ListenModelStore.modelKey)
        XCTAssertEqual(ListenModelStore(catalog: catalog, root: root, defaults: chosen).selectedID,
                       ListenModelStore.previousDefaultModel, "An explicit choice always wins")
    }

    /// Core ML packages download as nested files and configure the Core ML recognizer.
    func testStoreInstallsPackageFilesAndConfiguresCoreML() async throws {
        let source = temporaryFolder()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        func file(_ name: String, _ text: String) throws -> ListenModelCatalog.File {
            let url = source.appendingPathComponent(UUID().uuidString); try Data(text.utf8).write(to: url)
            return .init(name: name, size: Int64(text.utf8.count), url: url, sha256: try ListenModelStore.sha256(of: url))
        }
        let vad = ListenModelCatalog.Model(id: "vad", role: "vad", title: "VAD", kind: "silero_vad", featureDim: nil, languages: [],
            licence: "MIT", source: source, files: [try file("vad.onnx", "vad")], config: ["model": "vad.onnx"])
        let package = ListenModelCatalog.Model(id: "ane", role: "listen", title: "ANE", kind: ListenModelStore.coreMLGigaAMKind,
            featureDim: 64, languages: ["ru"], licence: "MIT", source: source,
            files: [try file("E.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "e"), try file("D.mlpackage/Manifest.json", "d"),
                    try file("J.mlpackage/Manifest.json", "j"), try file("tokens.json", "[]")],
            config: ["encoder": "E.mlpackage", "decoder": "D.mlpackage", "joint": "J.mlpackage", "tokens": "tokens.json"])
        let store = ListenModelStore(catalog: .init(schemaVersion: 1, runtime: "test", models: [vad, package]),
                                     root: temporaryFolder(), defaults: UserDefaults(suiteName: "listen-\(UUID())")!)
        store.selectedID = "ane"; store.enabled = true
        store.download(package)
        for _ in 0..<200 where !(store.state(package).installed && store.state(vad).installed) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.state(package), .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder(package)
            .appendingPathComponent("E.mlpackage/Data/com.apple.CoreML/weights/weight.bin").path))
        guard case .coreMLGigaAM(let configured) = try XCTUnwrap(store.recognizerModel()) else { return XCTFail("Core ML configuration") }
        XCTAssertEqual(configured.encoder.lastPathComponent, "E.mlpackage")
        XCTAssertEqual(configured.cache, store.folder(package).appendingPathComponent("compiled", isDirectory: true))
        XCTAssertEqual(configured.computeUnits, .cpuAndNeuralEngine)
        store.refresh()
        XCTAssertEqual(store.state(package), .installed, "Nested files count as present after a restart")
    }

    func testMultiArrayHelpersDoNotRetainPixelBufferBackedArraysOnBackgroundQueue() throws {
        // Verify strided CVPixelBuffer-backed float16 reads and float32 copy detachment.
        var stridedPixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            5,
            3,
            kCVPixelFormatType_OneComponent16Half,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &stridedPixelBuffer
        )
        XCTAssertEqual(createStatus, kCVReturnSuccess)
        let strided = MLMultiArray(pixelBuffer: try XCTUnwrap(stridedPixelBuffer), shape: [1, 3, 5])
        strided.withUnsafeMutableBytes { raw, strides in
            let ptr = raw.bindMemory(to: Float16.self)
            for row in 0..<3 {
                for col in 0..<5 {
                    ptr[row * strides[1] + col * strides[2]] = Float16(row * 10 + col)
                }
            }
        }
        let copied = try CoreMLGigaAMRecognizer.float32(strided)
        XCTAssertNil(copied.pixelBuffer)
        XCTAssertEqual(copied.dataType, .float32)
        for row in 0..<3 {
            for col in 0..<5 {
                let flat = row * 5 + col
                XCTAssertEqual(CoreMLGigaAMRecognizer.float(strided, flat), Float(row * 10 + col), accuracy: 1e-3)
                XCTAssertEqual(CoreMLGigaAMRecognizer.float(copied, flat), Float(row * 10 + col), accuracy: 1e-3)
            }
        }
        XCTAssertEqual(CoreMLGigaAMRecognizer.argmax(strided), 4)

        // On a default (.inherit) GCD queue without an outer autoreleasepool, reading
        // pixelBuffer-backed MLMultiArrays must not pin them until the block exits.
        final class WeakBox: @unchecked Sendable {
            weak var value: MLMultiArray?
            init(_ value: MLMultiArray) { self.value = value }
        }
        final class ResultBox: @unchecked Sendable {
            var aliveInBlock = -1
            var errorMessage: String?
        }
        let expectation = expectation(description: "background helper pass")
        let queue = DispatchQueue(label: "gigaam.retention.test", qos: .utility)
        let result = ResultBox()

        queue.async {
            do {
                let front = GigaAMMelFrontEnd()
                let silence = [Float](repeating: 0, count: 1600)
                var boxes: [WeakBox] = []
                for iter in 0..<60 {
                    var pb: CVPixelBuffer?
                    let status = CVPixelBufferCreate(
                        kCFAllocatorDefault,
                        320,
                        1,
                        kCVPixelFormatType_OneComponent16Half,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                        &pb
                    )
                    guard status == kCVReturnSuccess, let pb else {
                        result.errorMessage = "CVPixelBufferCreate failed: \(status)"
                        break
                    }
                    let arr = MLMultiArray(pixelBuffer: pb, shape: [1, 1, 320])
                    arr.withUnsafeMutableBytes { raw, _ in
                        let ptr = raw.bindMemory(to: Float16.self)
                        for idx in 0..<320 { ptr[idx] = 0 }
                        ptr[iter % 320] = 2.5
                    }
                    let floats = CoreMLGigaAMRecognizer.floats(arr)
                    let best = CoreMLGigaAMRecognizer.argmax(arr)
                    let first = CoreMLGigaAMRecognizer.float(arr, iter % 320)
                    let f32 = try CoreMLGigaAMRecognizer.float32(arr)
                    let mel = try front.features(silence, frames: 32, window: 32 * 160 + 160)
                    guard floats.count >= 320, best == iter % 320, abs(first - 2.5) < 0.01 else {
                        result.errorMessage = "Unexpected helper values"
                        break
                    }
                    boxes.append(WeakBox(arr))
                    boxes.append(WeakBox(f32))
                    boxes.append(WeakBox(mel))
                }
                result.aliveInBlock = boxes.filter { $0.value != nil }.count
            } catch {
                result.errorMessage = String(describing: error)
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(result.aliveInBlock, 0, "MLMultiArray helpers must not autorelease-pin arrays inside GCD blocks")
    }

    func testGigaAMV4PauseAwareSplittingPrefersSilentGap() {
        var samples = [Float](repeating: 0.4, count: 16_000 * 14)
        // Put a clear 400 ms silence valley at 7.5 s so splitter cuts inside it.
        for idx in (16_000 * 75 / 10)..<(16_000 * 79 / 10) {
            samples[idx] = 0
        }
        let chunks = CoreMLGigaAMV4Recognizer.splitChunksPauseAware(samples)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertGreaterThanOrEqual(chunks[0].count, 16_000 * 7)
        XCTAssertLessThanOrEqual(chunks[0].count, CoreMLGigaAMV4Recognizer.maxChunkSamples)
    }

    func testGigaAMV4Int8RecognizerTranscribesBenchmarkSample() throws {
        let v4Folder = bench.appendingPathComponent("models/gigaam-v4-coreml-int8")
        guard FileManager.default.fileExists(atPath: v4Folder.appendingPathComponent("runtime.json").path) else {
            throw XCTSkip("gigaam-v4-coreml-int8 not staged in .build/asr-bench/models")
        }
        let wavURL = bench.appendingPathComponent("fleurs-ru-50/000_12991791007873426296.wav")
        guard let file = try? AVAudioFile(forReading: wavURL),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XCTSkip("FLEURS wav sample missing")
        }
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        let v4Model = CoreMLGigaAMV4Model(
            encoder: v4Folder.appendingPathComponent("encoder-1024/stage-00.mlpackage"),
            runtime: v4Folder.appendingPathComponent("runtime.json"),
            window: v4Folder.appendingPathComponent("window.f32"),
            mel: v4Folder.appendingPathComponent("mel.f32"),
            head: v4Folder.appendingPathComponent("e2e.f32"),
            cache: temporaryFolder(),
            computeUnits: .cpuAndNeuralEngine
        )
        let recognizer = try CoreMLGigaAMV4Recognizer(v4Model)
        let transcript = try recognizer.transcribe(samples)
        XCTAssertTrue(transcript.contains("Молдавии") && transcript.contains("христианство"), transcript)
        XCTAssertEqual(try recognizer.transcribe([]), "")
    }
}
