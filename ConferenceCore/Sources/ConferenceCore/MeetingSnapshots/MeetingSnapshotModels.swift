import Foundation

public enum MeetingSnapshotScope: String, Codable, CaseIterable, Sendable {
    case screenShare
    case participantCamera
    case fullStage

    public var title: String {
        switch self {
        case .screenShare: return L("Screen share")
        case .participantCamera: return L("Camera")
        case .fullStage: return L("Full stage")
        }
    }

    public var symbol: String {
        switch self {
        case .screenShare: return "rectangle.on.rectangle"
        case .participantCamera: return "video"
        case .fullStage: return "rectangle.grid.2x2"
        }
    }
}

public enum MeetingSnapshotImageFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case jpeg
    case png
    case mixedPNGAndHEIC

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .jpeg: return L("JPEG (Default)")
        case .png: return L("PNG (Lossless)")
        case .mixedPNGAndHEIC: return L("Mixed: PNG + HEIC")
        }
    }

    public var detail: String {
        switch self {
        case .jpeg:
            return L("Fast, compact, and universally compatible with Markdown and Obsidian.")
        case .png:
            return L("Lossless text and diagram clarity for all meeting captures.")
        case .mixedPNGAndHEIC:
            return L("Lossless PNG for screen shares; compact HEIC for cameras and full stage.")
        }
    }

    public func fileExtension(for scope: MeetingSnapshotScope) -> String {
        switch self {
        case .jpeg:
            return "jpg"
        case .png:
            return "png"
        case .mixedPNGAndHEIC:
            return scope == .screenShare ? "png" : "heic"
        }
    }
}

public struct MeetingSnapshotRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let capturedAt: Date
    public var scope: MeetingSnapshotScope
    public var sourceID: String
    public var sourceName: String
    public var relativeFileName: String
    public var fileExtension: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var caption: String
    public var ocrText: String
    public var transcriptExcerpt: String
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        capturedAt: Date = Date(),
        scope: MeetingSnapshotScope,
        sourceID: String,
        sourceName: String,
        relativeFileName: String,
        fileExtension: String,
        pixelWidth: Int,
        pixelHeight: Int,
        caption: String = "",
        ocrText: String = "",
        transcriptExcerpt: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.capturedAt = capturedAt
        self.scope = scope
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.relativeFileName = relativeFileName
        self.fileExtension = fileExtension
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.caption = caption
        self.ocrText = ocrText
        self.transcriptExcerpt = transcriptExcerpt
        self.updatedAt = updatedAt
    }

    public var displayTitle: String {
        let trimmedSource = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSource.isEmpty { return scope.title }
        if scope == .fullStage { return scope.title }
        return "\(scope.title) · \(trimmedSource)"
    }

    public var exportFileName: String {
        let ext = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "jpg" : fileExtension
        let sPrefix = String(sessionID.uuidString.prefix(8))
        let idPrefix = String(id.uuidString.prefix(8))
        return "snap-\(sPrefix)-\(idPrefix).\(ext)"
    }
}

public enum MeetingSnapshotPreferences {
    public static let imageFormatKey = "meetingSnapshots.imageFormat.v1"
    public static let iosHardwareBridgeKey = "meetingSnapshots.iosHardwareScreenshotBridge.v1"
    public static let didChangeNotification = Notification.Name("ConferenceCore.MeetingSnapshotPreferences.didChange")

    public static func imageFormat(defaults: UserDefaults = .standard) -> MeetingSnapshotImageFormat {
        guard let raw = defaults.string(forKey: imageFormatKey),
              let format = MeetingSnapshotImageFormat(rawValue: raw) else {
            return .jpeg
        }
        return format
    }

    public static func setImageFormat(_ format: MeetingSnapshotImageFormat, defaults: UserDefaults = .standard) {
        defaults.set(format.rawValue, forKey: imageFormatKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// ON by default; users can opt out in Settings.
    public static func isIOSHardwareScreenshotBridgeEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: iosHardwareBridgeKey) == nil {
            return true
        }
        return defaults.bool(forKey: iosHardwareBridgeKey)
    }

    public static func setIOSHardwareScreenshotBridgeEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: iosHardwareBridgeKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

public enum MeetingSnapshotMarkdown {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    public static func obsidianSection(
        snapshots: [MeetingSnapshotRecord],
        attachmentsFolder: String = "Attachments",
        headingLevel: Int = 2,
        useWikiLinks: Bool = true
    ) -> String {
        guard !snapshots.isEmpty else { return "" }
        let heading = String(repeating: "#", count: max(1, headingLevel))
        let cleanFolder = attachmentsFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let ordered = snapshots.sorted { ($0.capturedAt, $0.id.uuidString) < ($1.capturedAt, $1.id.uuidString) }
        var lines: [String] = ["\(heading) Visual Snapshots"]
        for snap in ordered {
            let timestamp = timeFormatter.string(from: snap.capturedAt)
            let caption = snap.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = caption.isEmpty ? "" : " — \(caption)"
            lines.append("- **\(timestamp) · \(snap.displayTitle)**\(suffix)")
            let relPath = cleanFolder.isEmpty ? snap.exportFileName : "\(cleanFolder)/\(snap.exportFileName)"
            if useWikiLinks {
                lines.append("  ![[\(snap.exportFileName)]]")
            } else {
                let encoded = relPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relPath
                lines.append("  ![\(snap.displayTitle)](\(encoded))")
            }
            let ocr = snap.ocrText.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !ocr.isEmpty {
                lines.append("  > OCR: \(String(ocr.prefix(240)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func summaryPromptContext(snapshots: [MeetingSnapshotRecord], maxCharacters: Int = 2500) -> String? {
        guard !snapshots.isEmpty else { return nil }
        let ordered = snapshots.sorted { ($0.capturedAt, $0.id.uuidString) < ($1.capturedAt, $1.id.uuidString) }
        var blocks: [String] = []
        var total = 0
        for snap in ordered {
            let time = timeFormatter.string(from: snap.capturedAt)
            var parts = ["[\(time) · \(snap.displayTitle)]"]
            let caption = snap.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            if !caption.isEmpty { parts.append("User note: \(caption)") }
            let ocr = snap.ocrText.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !ocr.isEmpty { parts.append("Visible text: \(String(ocr.prefix(400)))") }
            let excerpt = snap.transcriptExcerpt.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !excerpt.isEmpty { parts.append("Transcript moment: \(String(excerpt.prefix(200)))") }
            if parts.count == 1 {
                parts.append("Captured visual frame")
            }
            let line = parts.joined(separator: " | ")
            if total + line.count > maxCharacters { break }
            blocks.append(line)
            total += line.count + 1
        }
        return blocks.isEmpty ? nil : "Captured visual snapshots:\n" + blocks.joined(separator: "\n")
    }
}
