import AVFoundation
import Foundation
import LiveKitWebRTC

/// Paces a synthesized PCM reply into an active synthetic WebRTC audio source
/// (`isSynthetic == true`) without touching `AudioState` or the hardware microphone.
enum SyntheticVoiceReplyPlayer {
    static let targetSampleRate: Double = 48_000
    static let targetChannels: AVAudioChannelCount = 1
    static let frameSamples = 480

    private final class MonitorBox: @unchecked Sendable {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        init?(buffer: AVAudioPCMBuffer, gain: Float) {
            guard gain > 0 else { return nil }
            let clampedGain = min(1, max(0, gain))
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            player.volume = clampedGain
            do {
                try engine.start()
            } catch {
                return nil
            }
            player.scheduleBuffer(buffer)
            player.play()
        }

        func stop() {
            player.stop()
            engine.stop()
            engine.detach(player)
        }
    }

    #if !os(macOS)
    private final class IOSMonitorBox: @unchecked Sendable {
        let player: AVAudioPlayer

        init?(samples: [Int16], gain: Float) {
            guard gain > 0, !samples.isEmpty else { return nil }
            var wav = Data()
            let pcmByteCount = samples.count * MemoryLayout<Int16>.size
            wav.reserveCapacity(44 + pcmByteCount)
            func appendLE<T: FixedWidthInteger>(_ value: T) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
            }
            wav.append(contentsOf: "RIFF".utf8)
            appendLE(UInt32(clamping: 36 + pcmByteCount))
            wav.append(contentsOf: "WAVEfmt ".utf8)
            appendLE(UInt32(16))
            appendLE(UInt16(1))
            appendLE(UInt16(targetChannels))
            appendLE(UInt32(targetSampleRate))
            appendLE(UInt32(targetSampleRate) * UInt32(targetChannels) * 2)
            appendLE(UInt16(targetChannels) * 2)
            appendLE(UInt16(16))
            wav.append(contentsOf: "data".utf8)
            appendLE(UInt32(clamping: pcmByteCount))
            samples.withUnsafeBytes { wav.append(contentsOf: $0) }

            guard let audioPlayer = try? AVAudioPlayer(data: wav) else { return nil }
            audioPlayer.volume = min(1, max(0, gain))
            audioPlayer.prepareToPlay()
            guard audioPlayer.play() else { return nil }
            self.player = audioPlayer
        }

        var isPlaying: Bool { player.isPlaying }

        func stop() {
            player.stop()
        }
    }

    private final class IOSStreamingMonitorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var players: [AVAudioPlayer] = []
        private var nextStartTime: TimeInterval?
        private var stopped = false
        private let gain: Float

        init?(gain: Float) {
            guard gain > 0 else { return nil }
            self.gain = min(1, max(0, gain))
        }

        func enqueue(samples: [Int16]) {
            guard !samples.isEmpty else { return }
            var wav = Data()
            let pcmByteCount = samples.count * MemoryLayout<Int16>.size
            wav.reserveCapacity(44 + pcmByteCount)
            func appendLE<T: FixedWidthInteger>(_ value: T) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
            }
            wav.append(contentsOf: "RIFF".utf8)
            appendLE(UInt32(clamping: 36 + pcmByteCount))
            wav.append(contentsOf: "WAVEfmt ".utf8)
            appendLE(UInt32(16))
            appendLE(UInt16(1))
            appendLE(UInt16(targetChannels))
            appendLE(UInt32(targetSampleRate))
            appendLE(UInt32(targetSampleRate) * UInt32(targetChannels) * 2)
            appendLE(UInt16(targetChannels) * 2)
            appendLE(UInt16(16))
            wav.append(contentsOf: "data".utf8)
            appendLE(UInt32(clamping: pcmByteCount))
            samples.withUnsafeBytes { wav.append(contentsOf: $0) }

            guard let audioPlayer = try? AVAudioPlayer(data: wav) else { return }
            audioPlayer.volume = gain
            audioPlayer.prepareToPlay()
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return }
            players.removeAll { !$0.isPlaying }
            let now = audioPlayer.deviceCurrentTime
            let startAt = max(now + 0.005, nextStartTime ?? (now + 0.005))
            audioPlayer.play(atTime: startAt)
            nextStartTime = startAt + audioPlayer.duration
            players.append(audioPlayer)
        }

        var isPlaying: Bool {
            lock.lock()
            defer { lock.unlock() }
            return players.contains { $0.isPlaying }
        }

        func stop() {
            lock.lock()
            stopped = true
            let active = players
            players.removeAll()
            lock.unlock()
            for p in active { p.stop() }
        }
    }
    #endif

    #if os(macOS)
    private final class StreamingMonitorBox: @unchecked Sendable {
        private let lock = NSLock()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format: AVAudioFormat
        private var stopped = false

        init?(format: AVAudioFormat, gain: Float) {
            guard gain > 0 else { return nil }
            self.format = format
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            player.volume = min(1, max(0, gain))
            do {
                try engine.start()
            } catch {
                return nil
            }
            player.play()
        }

        func schedule(_ buffer: AVAudioPCMBuffer) {
            guard let converted = GuestVoiceReplyGraph.convert(buffer, to: format) else { return }
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return }
            player.scheduleBuffer(converted, completionHandler: nil)
            if !player.isPlaying { player.play() }
        }

        func stop() {
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            stopped = true
            player.stop()
            engine.stop()
            engine.detach(player)
            lock.unlock()
        }
    }
    #endif

    private final class StreamSampleQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: [Int16] = []
        private var finished = false
        private var failed = false

        func append(_ samples: [Int16]) {
            lock.lock()
            buffer.append(contentsOf: samples)
            lock.unlock()
        }

        func finish() {
            lock.lock()
            finished = true
            lock.unlock()
        }

        func fail() {
            lock.lock()
            failed = true
            finished = true
            lock.unlock()
        }

        enum Step {
            case frame([Int16])
            case wait
            case done(success: Bool)
        }

        func popFrame(frameSamples: Int) -> Step {
            lock.lock()
            defer { lock.unlock() }
            if failed { return .done(success: false) }
            if buffer.count >= frameSamples {
                let frame = Array(buffer.prefix(frameSamples))
                buffer.removeFirst(frameSamples)
                return .frame(frame)
            }
            if finished {
                if buffer.isEmpty {
                    return .done(success: true)
                }
                let padCount = frameSamples - buffer.count
                let frame = buffer + [Int16](repeating: 0, count: padCount)
                buffer.removeAll(keepingCapacity: false)
                return .frame(frame)
            }
            return .wait
        }
    }

    static func play(_ buffer: AVAudioPCMBuffer,
                     localGain: Float?,
                     deliverFrame: @escaping @Sendable (UnsafePointer<Int16>, Int) -> Void,
                     canContinue: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        guard let speechSamples = convertTo48kMonoInt16(buffer), !speechSamples.isEmpty else {
            return false
        }
        guard !Task.isCancelled else { return false }
        guard await MainActor.run(body: canContinue) else {
            return false
        }

        #if os(macOS)
        let monitor = localGain.flatMap { MonitorBox(buffer: buffer, gain: $0) }
        defer { monitor?.stop() }
        #else
        let monitor = localGain.flatMap { IOSMonitorBox(samples: speechSamples, gain: $0) }
        defer { monitor?.stop() }
        #endif

        // Pad remainder of final 10ms chunk plus two silent 10ms frames so Opus flushes the tail cleanly.
        let totalSpeech = speechSamples.count
        let remainder = totalSpeech % frameSamples
        let alignmentPad = remainder == 0 ? 0 : (frameSamples - remainder)
        let padded = speechSamples + [Int16](repeating: 0, count: alignmentPad + frameSamples * 2)
        let clock = ContinuousClock()
        var nextDeadline = clock.now
        var offset = 0
        var frameCounter = 0

        while offset < padded.count {
            if Task.isCancelled { return false }
            if frameCounter % 10 == 0 {
                guard await MainActor.run(body: canContinue) else {
                    return false
                }
            }
            padded.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    deliverFrame(base + offset, frameSamples)
                }
            }
            offset += frameSamples
            frameCounter += 1
            if offset < padded.count {
                nextDeadline = nextDeadline.advanced(by: .milliseconds(10))
                if nextDeadline > clock.now {
                    do {
                        try await clock.sleep(until: nextDeadline, tolerance: .milliseconds(2))
                    } catch {
                        return false
                    }
                }
            }
        }
        #if !os(macOS)
        if !Task.isCancelled, let monitor {
            var drainTicks = 0
            while monitor.isPlaying && drainTicks < 12 && !Task.isCancelled {
                drainTicks += 1
                try? await clock.sleep(for: .milliseconds(20))
            }
        }
        #endif
        return offset >= totalSpeech && !Task.isCancelled
    }

    static func playStream(_ chunks: AsyncThrowingStream<AVAudioPCMBuffer, Error>,
                           localGain: Float?,
                           deliverFrame: @escaping @Sendable (UnsafePointer<Int16>, Int) -> Void,
                           canContinue: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        var iterator = chunks.makeAsyncIterator()
        var firstBuffer: AVAudioPCMBuffer?
        var firstSamples: [Int16]?
        do {
            while let next = try await iterator.next() {
                if next.frameLength == 0 { continue }
                if let converted = convertTo48kMonoInt16(next), !converted.isEmpty {
                    firstBuffer = next
                    firstSamples = converted
                    break
                }
            }
        } catch {
            return false
        }
        guard let firstBuffer, let firstSamples, !Task.isCancelled else { return false }
        guard await MainActor.run(body: canContinue) else { return false }

        let queue = StreamSampleQueue()
        queue.append(firstSamples)

        #if os(macOS)
        let monitor = localGain.flatMap { StreamingMonitorBox(format: firstBuffer.format, gain: $0) }
        monitor?.schedule(firstBuffer)
        defer { monitor?.stop() }
        #else
        let monitor = localGain.flatMap { IOSStreamingMonitorBox(gain: $0) }
        monitor?.enqueue(samples: firstSamples)
        defer { monitor?.stop() }
        #endif

        let producer = Task {
            do {
                while let next = try await iterator.next() {
                    guard !Task.isCancelled else { queue.fail(); return }
                    if next.frameLength == 0 { continue }
                    guard let samples = convertTo48kMonoInt16(next) else { queue.fail(); return }
                    queue.append(samples)
                    #if os(macOS)
                    monitor?.schedule(next)
                    #else
                    monitor?.enqueue(samples: samples)
                    #endif
                }
                queue.finish()
            } catch {
                queue.fail()
            }
        }
        defer { producer.cancel() }

        let clock = ContinuousClock()
        var nextDeadline = clock.now
        var frameCounter = 0
        var deliveredAny = false

        loop: while true {
            if Task.isCancelled { return false }
            if frameCounter % 10 == 0 {
                guard await MainActor.run(body: canContinue) else { return false }
            }
            switch queue.popFrame(frameSamples: frameSamples) {
            case .frame(let frame):
                deliveredAny = true
                frame.withUnsafeBufferPointer { ptr in
                    if let base = ptr.baseAddress {
                        deliverFrame(base, frameSamples)
                    }
                }
                frameCounter += 1
                nextDeadline = nextDeadline.advanced(by: .milliseconds(10))
                if nextDeadline > clock.now {
                    do {
                        try await clock.sleep(until: nextDeadline, tolerance: .milliseconds(2))
                    } catch {
                        return false
                    }
                }
            case .wait:
                do {
                    try await clock.sleep(for: .milliseconds(5))
                    nextDeadline = clock.now
                } catch {
                    return false
                }
            case .done(let success):
                guard success, deliveredAny else { return false }
                break loop
            }
        }

        // Two silent 10ms tail frames so Opus flushes cleanly.
        let tail = [Int16](repeating: 0, count: frameSamples)
        for _ in 0..<2 {
            if Task.isCancelled { return false }
            tail.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    deliverFrame(base, frameSamples)
                }
            }
            try? await clock.sleep(for: .milliseconds(10))
        }
        #if !os(macOS)
        if !Task.isCancelled, let monitor {
            var drainTicks = 0
            while monitor.isPlaying && drainTicks < 12 && !Task.isCancelled {
                drainTicks += 1
                try? await clock.sleep(for: .milliseconds(20))
            }
        }
        #endif
        return !Task.isCancelled
    }

    static func playStream(_ chunks: AsyncThrowingStream<AVAudioPCMBuffer, Error>,
                           into source: LKRTCAudioSource,
                           localGain: Float?,
                           canContinue: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        nonisolated(unsafe) let box = source
        return await playStream(
            chunks,
            localGain: localGain,
            deliverFrame: { samples, count in
                box.deliverPCMInt16(
                    samples,
                    frameCount: count,
                    sampleRate: Int32(targetSampleRate),
                    channels: Int(targetChannels)
                )
            },
            canContinue: canContinue
        )
    }

    static func play(_ buffer: AVAudioPCMBuffer,
                     into source: LKRTCAudioSource,
                     localGain: Float?,
                     canContinue: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        nonisolated(unsafe) let box = source
        return await play(
            buffer,
            localGain: localGain,
            deliverFrame: { samples, count in
                box.deliverPCMInt16(
                    samples,
                    frameCount: count,
                    sampleRate: Int32(targetSampleRate),
                    channels: Int(targetChannels)
                )
            },
            canContinue: canContinue
        )
    }

    static func convertTo48kMonoInt16(_ buffer: AVAudioPCMBuffer) -> [Int16]? {
        guard buffer.frameLength > 0,
              buffer.format.sampleRate > 0,
              buffer.format.channelCount > 0 else { return nil }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else { return nil }

        if buffer.format == targetFormat, let channelData = buffer.int16ChannelData {
            let count = Int(buffer.frameLength)
            return Array(UnsafeBufferPointer(start: channelData[0], count: count))
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return nil }
        converter.primeMethod = .none
        let ratio = targetSampleRate / buffer.format.sampleRate
        let estimatedFrames = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 128
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(256, estimatedFrames)) else {
            return nil
        }

        final class InputState: @unchecked Sendable {
            var fed = false
            let buffer: AVAudioPCMBuffer
            init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let inputState = InputState(buffer)
        var conversionError: NSError?
        var samples = [Int16]()
        samples.reserveCapacity(Int(estimatedFrames))

        while true {
            converted.frameLength = 0
            let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                if !inputState.fed {
                    inputState.fed = true
                    outStatus.pointee = .haveData
                    return inputState.buffer
                }
                outStatus.pointee = .endOfStream
                return nil
            }
            if converted.frameLength > 0, let channelData = converted.int16ChannelData {
                let count = Int(converted.frameLength)
                samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: count))
            }
            if status == .endOfStream || status == .error || status == .inputRanDry {
                break
            }
        }
        return samples.isEmpty ? nil : samples
    }
}

extension GuestAudioProfile {
    var rtcProcessingOptions: LKRTCAudioProcessingOptions {
        let speech = self == .speech
        return LKRTCAudioProcessingOptions(
            echoCancellationOptions: LKRTCAudioProcessingComponentOptions(
                enabled: true,
                mode: speech ? .automatic : .software
            ),
            noiseSuppressionOptions: LKRTCAudioProcessingComponentOptions(enabled: speech),
            autoGainControlOptions: LKRTCAudioProcessingComponentOptions(enabled: speech),
            highPassFilterOptions: LKRTCAudioProcessingComponentOptions(enabled: true)
        )
    }
}
