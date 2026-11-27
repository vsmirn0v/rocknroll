import Combine
import CryptoKit
import Foundation
import Speech

enum IOSListenModel: String, CaseIterable, Identifiable, Codable {
    case gigaamV4CoreMLInt8
    case appleSpeech
    case gigaamV3CoreML

    var id: String { rawValue }

    var isOutdatedV3: Bool {
        self == .gigaamV3CoreML
    }

    var title: String {
        switch self {
        case .gigaamV4CoreMLInt8:
            return L("GigaAM v4 INT8 (Recommended)")
        case .appleSpeech:
            return L("Apple On-Device Speech")
        case .gigaamV3CoreML:
            return L("GigaAM v3 (Outdated)")
        }
    }

    var subtitle: String {
        switch self {
        case .gigaamV4CoreMLInt8:
            return L("Downloaded once (~246 MB). Runs ~4× faster offline on Neural Engine for Russian & English.")
        case .appleSpeech:
            return L("Uses Apple Speech when on-device recognition is available for the selected language.")
        case .gigaamV3CoreML:
            return L("Previous-generation model (~446 MB). Russian only — upgrade to GigaAM v4 INT8 for faster offline transcription.")
        }
    }
}

enum IOSTranscriptionLanguage: String, CaseIterable, Identifiable, Codable {
    case russian = "ru-RU"
    case english = "en-US"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .russian: return L("Russian")
        case .english: return L("English")
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

enum IOSModelInstallState: Equatable {
    case notInstalled
    case downloading(progress: Double)
    case installed
    case failed(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

struct PinnedModelFile: Equatable {
    let relativePath: String
    let byteCount: Int64
    let sha256Hex: String
    let url: URL
}

@MainActor
final class IOSListenModelStore: ObservableObject {
    static let shared = IOSListenModelStore()
    static let defaultModel: IOSListenModel = .gigaamV4CoreMLInt8

    private enum Keys {
        static let selectedModel = "ios.transcription.model"
        static let language = "ios.transcription.language"
        static let autoStart = "ios.transcription.auto-start"
        static let v4PromptDismissed = "ios.transcription.v4-prompt-dismissed"
    }

    static let gigaamV4BaseURL = URL(string: "https://github.com/vsmirn0v/rocknroll/releases/download/models-gigaam-v4-coreml-int8-v1/")!

    static let gigaamV4Files: [PinnedModelFile] = [
        PinnedModelFile(
            relativePath: "runtime.json",
            byteCount: 19_454,
            sha256Hex: "0e7458a589178d2514f847eb7418fc70104e218dd2b81ff28e3c8822f3e0dead",
            url: gigaamV4BaseURL.appendingPathComponent("runtime.json")
        ),
        PinnedModelFile(
            relativePath: "window.f32",
            byteCount: 1_280,
            sha256Hex: "42e25fcba0bf1e83f24f71368f6ccedef245e6faeac6ec2b9ebabb6cf6e66705",
            url: gigaamV4BaseURL.appendingPathComponent("window.f32")
        ),
        PinnedModelFile(
            relativePath: "mel.f32",
            byteCount: 41_216,
            sha256Hex: "03f0c05dba900b44f54d816789838e498908cd4ee492ef231f8459c61a5158ac",
            url: gigaamV4BaseURL.appendingPathComponent("mel.f32")
        ),
        PinnedModelFile(
            relativePath: "e2e.f32",
            byteCount: 7_310_340,
            sha256Hex: "11106fa8d3d6e23ea4db4500bee7f0178e6cfa4b9cab01287f963e98c559d507",
            url: gigaamV4BaseURL.appendingPathComponent("e2e.f32")
        ),
        PinnedModelFile(
            relativePath: "encoder-1024/stage-00.mlpackage/Manifest.json",
            byteCount: 617,
            sha256Hex: "5d6f53200259ba966839d08ee4a8b62410f06026087e39a0a33ba82f7b4bff32",
            url: gigaamV4BaseURL.appendingPathComponent("stage-00-Manifest.json")
        ),
        PinnedModelFile(
            relativePath: "encoder-1024/stage-00.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            byteCount: 521_464,
            sha256Hex: "7fccc583d7baf1c466f8e94a1dd6cfd081579cb6c2216de908b0fa17c6f6252b",
            url: gigaamV4BaseURL.appendingPathComponent("stage-00-model.mlmodel")
        ),
        PinnedModelFile(
            relativePath: "encoder-1024/stage-00.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            byteCount: 237_974_144,
            sha256Hex: "869757bf6c939e5c31984c2ddd93730ff19151ace89a71f5c1bbdb04ad950173",
            url: gigaamV4BaseURL.appendingPathComponent("stage-00-weight.bin")
        )
    ]

    static let gigaamBaseURL = URL(string: "https://huggingface.co/smkrv/gigaam-v3-e2e-rnnt-coreml/resolve/846833ef075fde2a8e50521d093ddb9ed7b7fd45/")!

    static let gigaamFiles: [PinnedModelFile] = [
        PinnedModelFile(
            relativePath: "GigaAMv3Encoder.mlpackage/Manifest.json",
            byteCount: 617,
            sha256Hex: "6589ff6d3d3f814561449073ee12160bafb9f467c89159dc6a7240ef68235b04",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3Encoder.mlpackage/Manifest.json")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            byteCount: 419_364,
            sha256Hex: "f66bd914e5379bcddbbe7ef9d485c7e712443e5f5a880ce98a0cc0aafe3aeeeb",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            byteCount: 441_545_792,
            sha256Hex: "cacb9c2b41a62b3fcdb3522c0571a3196648dfe39dfb1df9a31969239c8e3877",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3DecoderStep.mlpackage/Manifest.json",
            byteCount: 617,
            sha256Hex: "392239871ff24dbc7d1091dbe11982f202d8ce53e3ce9fb2f11cd671881ebbf9",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3DecoderStep.mlpackage/Manifest.json")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            byteCount: 7_367,
            sha256Hex: "71194a592055ad6a24ae4c980edcd52a25ea51c079b79f736033d07e00d6dfa5",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/model.mlmodel")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            byteCount: 2_297_280,
            sha256Hex: "5b23897e619a78cea140dbf3677efc92a58ed7935542047df7d452f03cf98edd",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3JointStep.mlpackage/Manifest.json",
            byteCount: 617,
            sha256Hex: "378654b204d17a89750d807c95aa3bc4e3893bb808ca4c0e2f22259e3b210c42",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3JointStep.mlpackage/Manifest.json")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            byteCount: 2_916,
            sha256Hex: "9fa81aeaf320573eca794c17ad825d4c3ea7219f35414387732994df43a7bec3",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/model.mlmodel")
        ),
        PinnedModelFile(
            relativePath: "GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            byteCount: 1_356_098,
            sha256Hex: "bbd11afc9f9954dea7ddf860e13e57a24ae908e061c80ac3e8b0b9693fb4886d",
            url: gigaamBaseURL.appendingPathComponent("GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
        ),
        PinnedModelFile(
            relativePath: "tokens.json",
            byteCount: 12_406,
            sha256Hex: "260c932355adc98a7440d49887f72a2fca42256971ad07a4e91265e93859ff69",
            url: gigaamBaseURL.appendingPathComponent("tokens.json")
        )
    ]

    static let gigaamV4TotalByteCount: Int64 = gigaamV4Files.reduce(0) { $0 + $1.byteCount }

    static var defaultModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("RockNRoll/Models", isDirectory: true)
    }

    typealias FileDownloader = @Sendable (_ url: URL, _ destination: URL, _ progress: @escaping @Sendable (Int64) -> Void) async throws -> Void

    @Published var selectedModel: IOSListenModel {
        didSet { preferences.set(selectedModel.rawValue, forKey: Keys.selectedModel) }
    }
    @Published var language: IOSTranscriptionLanguage {
        didSet { preferences.set(language.rawValue, forKey: Keys.language) }
    }
    @Published var autoStartLocalTranscription: Bool {
        didSet { preferences.set(autoStartLocalTranscription, forKey: Keys.autoStart) }
    }
    @Published private(set) var gigaamV4State: IOSModelInstallState = .notInstalled
    @Published private(set) var gigaamState: IOSModelInstallState = .notInstalled
    @Published private(set) var isV4UpgradePromptDismissed: Bool

    private let modelsDirectory: URL
    private let preferences: UserDefaults
    private let downloader: FileDownloader
    private var downloadTask: Task<Void, Never>?
    private var downloadV4Task: Task<Void, Never>?

    var gigaamDirectory: URL {
        modelsDirectory.appendingPathComponent("gigaam-v3-e2e-rnnt-coreml", isDirectory: true)
    }

    var gigaamV4Directory: URL {
        modelsDirectory.appendingPathComponent("gigaam-v4-coreml-int8", isDirectory: true)
    }

    var isUsingOutdatedV3Model: Bool {
        if selectedModel == .gigaamV3CoreML { return true }
        if selectedModel == .gigaamV4CoreMLInt8 && !gigaamV4State.isInstalled && gigaamState.isInstalled {
            return true
        }
        return false
    }

    var shouldPresentUpgradePromptOnBoot: Bool {
        guard !isV4UpgradePromptDismissed else { return false }
        if selectedModel == .gigaamV4CoreMLInt8 && gigaamV4State.isInstalled {
            return false
        }
        if case .downloading = gigaamV4State {
            return false
        }
        return isUsingOutdatedV3Model || (autoStartLocalTranscription && selectedModel == .gigaamV4CoreMLInt8)
    }

    var activeModelReadinessSummary: String {
        if selectedModel == .gigaamV4CoreMLInt8, !gigaamV4State.isInstalled {
            switch gigaamV4State {
            case .downloading(let progress):
                return L("Downloading… %ld%%", Int((progress * 100).rounded()))
            case .failed:
                return L("Download failed · %@", activeModelStatusTitle)
            case .installed:
                break
            case .notInstalled:
                if gigaamState.isInstalled {
                    return L("Ready · %@", activeModelStatusTitle)
                }
                return L("Not downloaded · Fallback: %@", activeModelStatusTitle)
            }
        } else if selectedModel == .gigaamV3CoreML, !gigaamState.isInstalled {
            if case .downloading(let progress) = gigaamState {
                return L("Downloading… %ld%%", Int((progress * 100).rounded()))
            }
            return L("Not downloaded · Fallback: %@", activeModelStatusTitle)
        }
        return L("Ready · %@", activeModelStatusTitle)
    }

    var activeModelStatusTitle: String {
        switch effectiveBackend() {
        case .gigaamV4CoreMLInt8:
            return L("GigaAM v4 INT8")
        case .gigaamV3CoreML:
            return L("GigaAM v3")
        case .appleSpeech:
            return L("Apple On-Device Speech")
        }
    }

    init(modelsDirectory: URL? = nil,
         preferences: UserDefaults = .standard,
         downloader: FileDownloader? = nil) {
        self.modelsDirectory = modelsDirectory ?? Self.defaultModelsDirectory
        self.preferences = preferences
        self.downloader = downloader ?? Self.streamDownload
        self.isV4UpgradePromptDismissed = preferences.bool(forKey: Keys.v4PromptDismissed)

        let v4Installed = Self.hasAllFilesInstalled(Self.gigaamV4Files, in: self.modelsDirectory.appendingPathComponent("gigaam-v4-coreml-int8", isDirectory: true))
        let v3Installed = Self.hasAllFilesInstalled(Self.gigaamFiles, in: self.modelsDirectory.appendingPathComponent("gigaam-v3-e2e-rnnt-coreml", isDirectory: true))
        self.gigaamV4State = v4Installed ? .installed : .notInstalled
        self.gigaamState = v3Installed ? .installed : .notInstalled

        let storedModel = preferences.string(forKey: Keys.selectedModel).flatMap(IOSListenModel.init(rawValue:))
        if let storedModel {
            self.selectedModel = storedModel
        } else if v4Installed {
            self.selectedModel = .gigaamV4CoreMLInt8
        } else if v3Installed {
            // Preserve installed GigaAM v3 until user downloads v4 INT8 so meetings continue offline.
            self.selectedModel = .gigaamV3CoreML
        } else {
            self.selectedModel = Self.defaultModel
        }

        let storedLang = preferences.string(forKey: Keys.language).flatMap(IOSTranscriptionLanguage.init(rawValue:))
        let defaultLang: IOSTranscriptionLanguage = Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") == true
            ? .russian : .english
        self.language = storedLang ?? defaultLang

        if preferences.object(forKey: Keys.autoStart) != nil {
            self.autoStartLocalTranscription = preferences.bool(forKey: Keys.autoStart)
        } else {
            self.autoStartLocalTranscription = false
        }
    }

    func refreshInstallState() {
        if case .downloading = gigaamV4State {
        } else {
            gigaamV4State = Self.hasAllFilesInstalled(Self.gigaamV4Files, in: gigaamV4Directory) ? .installed : .notInstalled
        }
        if case .downloading = gigaamState {
        } else {
            gigaamState = Self.hasAllFilesInstalled(Self.gigaamFiles, in: gigaamDirectory) ? .installed : .notInstalled
        }
    }
    #if DEBUG
    func setGigaAMV4StateForTesting(_ state: IOSModelInstallState) {
        gigaamV4State = state
    }
    #endif

    static func hasAllFilesInstalled(_ specs: [PinnedModelFile] = gigaamFiles, in directory: URL) -> Bool {
        for spec in specs {
            let fileURL = directory.appendingPathComponent(spec.relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return false
            }
        }
        return true
    }

    func installedGigaAMDirectoryIfReady() -> URL? {
        gigaamState.isInstalled ? gigaamDirectory : nil
    }

    func installedGigaAMV4DirectoryIfReady() -> URL? {
        gigaamV4State.isInstalled ? gigaamV4Directory : nil
    }

    func effectiveBackend(for preferred: IOSListenModel? = nil) -> IOSListenModel {
        switch preferred ?? selectedModel {
        case .gigaamV4CoreMLInt8:
            if gigaamV4State.isInstalled { return .gigaamV4CoreMLInt8 }
            if gigaamState.isInstalled { return .gigaamV3CoreML }
            return .appleSpeech
        case .gigaamV3CoreML:
            return gigaamState.isInstalled ? .gigaamV3CoreML : .appleSpeech
        case .appleSpeech:
            return .appleSpeech
        }
    }

    func appleSpeechAvailableOnDevice() -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: language.locale) else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    func dismissUpgradePrompt() {
        isV4UpgradePromptDismissed = true
        preferences.set(true, forKey: Keys.v4PromptDismissed)
    }

    func downloadAndSwitchToV4() {
        if gigaamV4State.isInstalled {
            selectedModel = .gigaamV4CoreMLInt8
            isV4UpgradePromptDismissed = true
            preferences.set(true, forKey: Keys.v4PromptDismissed)
        } else {
            downloadGigaAMV4()
        }
    }

    func downloadGigaAMV4() {
        guard downloadV4Task == nil else { return }
        gigaamV4State = .downloading(progress: 0)
        downloadV4Task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.downloadV4Task = nil }
            do {
                try await self.performDownload(
                    specs: Self.gigaamV4Files,
                    targetDirectory: self.gigaamV4Directory
                ) { [weak self] progress in
                    self?.gigaamV4State = .downloading(progress: progress)
                }
                self.gigaamV4State = .installed
                self.selectedModel = .gigaamV4CoreMLInt8
                self.isV4UpgradePromptDismissed = true
                self.preferences.set(true, forKey: Keys.v4PromptDismissed)
            } catch is CancellationError {
                self.refreshInstallState()
            } catch {
                self.gigaamV4State = .failed(error.localizedDescription)
            }
        }
    }

    func cancelV4Download() {
        downloadV4Task?.cancel()
        downloadV4Task = nil
        refreshInstallState()
    }

    func deleteGigaAMV4() {
        downloadV4Task?.cancel()
        downloadV4Task = nil
        CoreMLGigaAMV4Recognizer.invalidateCache(directory: gigaamV4Directory)
        try? FileManager.default.removeItem(at: gigaamV4Directory)
        gigaamV4State = .notInstalled
        if selectedModel == .gigaamV4CoreMLInt8 {
            selectedModel = gigaamState.isInstalled ? .gigaamV3CoreML : .appleSpeech
        }
    }

    func downloadGigaAM() {
        guard downloadTask == nil else { return }
        gigaamState = .downloading(progress: 0)
        downloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.downloadTask = nil }
            do {
                try await self.performDownload(
                    specs: Self.gigaamFiles,
                    targetDirectory: self.gigaamDirectory
                ) { [weak self] progress in
                    self?.gigaamState = .downloading(progress: progress)
                }
                self.gigaamState = .installed
                self.selectedModel = .gigaamV3CoreML
            } catch is CancellationError {
                self.refreshInstallState()
            } catch {
                self.gigaamState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        refreshInstallState()
    }

    func deleteGigaAM() {
        downloadTask?.cancel()
        downloadTask = nil
        CoreMLGigaAMRecognizer.invalidateCache(directory: gigaamDirectory)
        try? FileManager.default.removeItem(at: gigaamDirectory)
        gigaamState = .notInstalled
        if selectedModel == .gigaamV3CoreML {
            selectedModel = gigaamV4State.isInstalled ? .gigaamV4CoreMLInt8 : .appleSpeech
        }
    }

    private func performDownload(
        specs: [PinnedModelFile],
        targetDirectory target: URL,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        Self.excludeFromBackup(modelsDirectory)

        let staging = modelsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let totalBytes = Double(specs.reduce(Int64(0)) { $0 + $1.byteCount })
        var completedBytes: Int64 = 0

        for spec in specs {
            try Task.checkCancellation()
            let dest = staging.appendingPathComponent(spec.relativePath)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

            let baseDone = completedBytes
            try await downloader(spec.url, dest) { written in
                let fraction = min(0.99, Double(baseDone + written) / max(1, totalBytes))
                Task { @MainActor in
                    onProgress(fraction)
                }
            }
            try Task.checkCancellation()
            try await Self.verifyFileAsync(at: dest, expectedBytes: spec.byteCount, expectedSHA256: spec.sha256Hex)
            completedBytes += spec.byteCount
            onProgress(min(0.99, Double(completedBytes) / max(1, totalBytes)))
        }

        let backup = modelsDirectory.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            try fm.moveItem(at: target, to: backup)
        }
        do {
            try fm.moveItem(at: staging, to: target)
            Self.excludeFromBackup(target)
            try? fm.removeItem(at: backup)
        } catch {
            if fm.fileExists(atPath: backup.path) && !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: backup, to: target)
            }
            throw error
        }
    }

    nonisolated static func verifyFileAsync(at url: URL, expectedBytes: Int64, expectedSHA256: String) async throws {
        try await Task.detached(priority: .utility) {
            try verifyFile(at: url, expectedBytes: expectedBytes, expectedSHA256: expectedSHA256)
        }.value
    }

    nonisolated static func verifyFile(at url: URL, expectedBytes: Int64, expectedSHA256: String) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        guard size == expectedBytes else {
            throw NSError(
                domain: "IOSListenModelStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("Downloaded file size mismatch (%@).", url.lastPathComponent)]
            )
        }
        let digest = try sha256Hex(of: url)
        guard digest == expectedSHA256.lowercased() else {
            throw NSError(
                domain: "IOSListenModelStore",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: L("Downloaded model verification failed (%@).", url.lastPathComponent)]
            )
        }
    }

    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    static func streamDownload(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let delegate = DownloadProgressDelegate(onBytesWritten: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await delegate.download(url: url, destination: destination, session: session)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onBytesWritten: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private weak var task: URLSessionDownloadTask?
    private let lock = NSLock()

    init(onBytesWritten: @escaping @Sendable (Int64) -> Void) {
        self.onBytesWritten = onBytesWritten
    }

    func download(url: URL, destination: URL, session: URLSession) async throws {
        self.destination = destination
        let downloadTask = session.downloadTask(with: url)
        self.task = downloadTask
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                self.continuation = cont
                lock.unlock()
                downloadTask.resume()
            }
        } onCancel: { [weak downloadTask] in
            downloadTask?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onBytesWritten(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            finish(with: .failure(URLError(.badServerResponse)))
            return
        }
        guard let destination else {
            finish(with: .failure(URLError(.cannotCreateFile)))
            return
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            finish(with: .success(()))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(with: .failure(error))
        }
    }

    private func finish(with result: Result<Void, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }
}
