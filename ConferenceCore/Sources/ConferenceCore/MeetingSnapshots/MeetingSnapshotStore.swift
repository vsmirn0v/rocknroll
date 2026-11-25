import Foundation

public actor MeetingSnapshotStore {
    public static let shared = MeetingSnapshotStore()
    public static let didChangeNotification = Notification.Name("ConferenceCore.MeetingSnapshotStore.didChange")

    private let root: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.root = support.appendingPathComponent("RockNRoll/MeetingSnapshots", isDirectory: true)
        }
    }

    public func snapshots(for sessionID: UUID) -> [MeetingSnapshotRecord] {
        readIndex(sessionID: sessionID).sorted { ($0.capturedAt, $0.id.uuidString) > ($1.capturedAt, $1.id.uuidString) }
    }

    public func snapshots(for sessionIDs: [UUID]) -> [MeetingSnapshotRecord] {
        var unique: [UUID: MeetingSnapshotRecord] = [:]
        for id in sessionIDs {
            for record in readIndex(sessionID: id) {
                unique[record.id] = record
            }
        }
        return unique.values.sorted { ($0.capturedAt, $0.id.uuidString) > ($1.capturedAt, $1.id.uuidString) }
    }

    public func imageURL(for record: MeetingSnapshotRecord) -> URL {
        sessionDirectory(record.sessionID).appendingPathComponent(record.relativeFileName)
    }

    @discardableResult
    public func save(
        sessionID: UUID,
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        scope: MeetingSnapshotScope,
        sourceID: String,
        sourceName: String,
        encoded: MeetingSnapshotEncoder.EncodedImage,
        caption: String = "",
        ocrText: String = "",
        transcriptExcerpt: String = ""
    ) throws -> MeetingSnapshotRecord {
        let dir = sessionDirectory(sessionID)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileName = "\(id.uuidString).\(encoded.fileExtension)"
        let fileURL = dir.appendingPathComponent(fileName)
        try encoded.data.write(to: fileURL, options: .atomic)

        let record = MeetingSnapshotRecord(
            id: id,
            sessionID: sessionID,
            capturedAt: capturedAt,
            scope: scope,
            sourceID: sourceID,
            sourceName: sourceName,
            relativeFileName: fileName,
            fileExtension: encoded.fileExtension,
            pixelWidth: encoded.width,
            pixelHeight: encoded.height,
            caption: caption,
            ocrText: ocrText,
            transcriptExcerpt: transcriptExcerpt,
            updatedAt: capturedAt
        )

        var records = readIndex(sessionID: sessionID)
        records.removeAll { $0.id == record.id }
        records.append(record)
        try writeIndex(records, sessionID: sessionID)
        postDidChange(sessionID: sessionID)
        return record
    }

    @discardableResult
    public func replaceImage(
        snapshotID: UUID,
        sessionID: UUID,
        scope: MeetingSnapshotScope,
        sourceID: String,
        sourceName: String,
        encoded: MeetingSnapshotEncoder.EncodedImage
    ) throws -> MeetingSnapshotRecord? {
        var records = readIndex(sessionID: sessionID)
        guard let index = records.firstIndex(where: { $0.id == snapshotID }) else { return nil }
        let oldRecord = records[index]
        let dir = sessionDirectory(sessionID)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let newFileName = "\(snapshotID.uuidString)-\(UUID().uuidString.prefix(6)).\(encoded.fileExtension)"
        let newFileURL = dir.appendingPathComponent(newFileName)
        try encoded.data.write(to: newFileURL, options: .atomic)

        var updated = oldRecord
        updated.scope = scope
        updated.sourceID = sourceID
        updated.sourceName = sourceName
        updated.relativeFileName = newFileName
        updated.fileExtension = encoded.fileExtension
        updated.pixelWidth = encoded.width
        updated.pixelHeight = encoded.height
        updated.ocrText = ""
        updated.updatedAt = Date()
        records[index] = updated
        try writeIndex(records, sessionID: sessionID)

        if oldRecord.relativeFileName != newFileName {
            try? fileManager.removeItem(at: dir.appendingPathComponent(oldRecord.relativeFileName))
        }
        postDidChange(sessionID: sessionID)
        return updated
    }

    @discardableResult
    public func updateCaption(_ caption: String, snapshotID: UUID, sessionID: UUID) throws -> MeetingSnapshotRecord? {
        var records = readIndex(sessionID: sessionID)
        guard let index = records.firstIndex(where: { $0.id == snapshotID }) else { return nil }
        records[index].caption = caption
        records[index].updatedAt = Date()
        let updated = records[index]
        try writeIndex(records, sessionID: sessionID)
        postDidChange(sessionID: sessionID)
        return updated
    }

    @discardableResult
    public func updateOCRText(_ ocrText: String, snapshotID: UUID, sessionID: UUID) throws -> MeetingSnapshotRecord? {
        var records = readIndex(sessionID: sessionID)
        guard let index = records.firstIndex(where: { $0.id == snapshotID }) else { return nil }
        records[index].ocrText = ocrText
        records[index].updatedAt = Date()
        let updated = records[index]
        try writeIndex(records, sessionID: sessionID)
        postDidChange(sessionID: sessionID)
        return updated
    }

    public func delete(snapshotID: UUID, sessionID: UUID) throws {
        var records = readIndex(sessionID: sessionID)
        guard let index = records.firstIndex(where: { $0.id == snapshotID }) else { return }
        let removed = records.remove(at: index)
        try writeIndex(records, sessionID: sessionID)
        try? fileManager.removeItem(at: sessionDirectory(sessionID).appendingPathComponent(removed.relativeFileName))
        postDidChange(sessionID: sessionID)
    }

    public func deleteAll(for sessionID: UUID) throws {
        let dir = sessionDirectory(sessionID)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
        postDidChange(sessionID: sessionID)
    }

    private func sessionDirectory(_ sessionID: UUID) -> URL {
        root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    private func indexURL(sessionID: UUID) -> URL {
        sessionDirectory(sessionID).appendingPathComponent("index.json")
    }

    private func readIndex(sessionID: UUID) -> [MeetingSnapshotRecord] {
        let url = indexURL(sessionID: sessionID)
        guard let data = try? Data(contentsOf: url),
              let records = try? decoder.decode([MeetingSnapshotRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func writeIndex(_ records: [MeetingSnapshotRecord], sessionID: UUID) throws {
        let dir = sessionDirectory(sessionID)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(records)
        try data.write(to: indexURL(sessionID: sessionID), options: .atomic)
    }

    private func postDidChange(sessionID: UUID) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: nil,
                userInfo: ["sessionID": sessionID]
            )
        }
    }
}
