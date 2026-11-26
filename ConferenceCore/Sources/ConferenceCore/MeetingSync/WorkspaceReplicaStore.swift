import CryptoKit
import Foundation

/// Deterministic SHA-256 digest helpers for sync records and replica persistence checks.
public enum SyncRecordDigest {
    private static let hexDigits: [Character] = Array("0123456789abcdef")

    public static func makeCanonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func sha256<T: Encodable>(_ value: T) -> String {
        guard let data = try? makeCanonicalEncoder().encode(value) else { return "" }
        return sha256(data)
    }

    public static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        var result = String()
        result.reserveCapacity(64)
        for byte in digest {
            result.append(hexDigits[Int(byte >> 4)])
            result.append(hexDigits[Int(byte & 0x0F)])
        }
        return result
    }
}

/// Incremental per-chunk JSON persistence so active transcript updates only touch the modified chunk file.
public enum WorkspaceTranscriptChunkSidecar {
    public static func fileURL(for chunkID: String, in directory: URL) -> URL {
        let name = SyncRecordDigest.sha256(Data(chunkID.utf8)) + ".json"
        return directory.appendingPathComponent(name)
    }

    public static func loadChunks(from directory: URL) -> [String: SyncedTranscriptChunk] {
        loadChunksWithDigests(from: directory).chunks
    }

    public static func loadChunksWithDigests(from directory: URL) -> (chunks: [String: SyncedTranscriptChunk], digests: [String: String]) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return ([:], [:])
        }
        let decoder = JSONDecoder()
        var chunks: [String: SyncedTranscriptChunk] = [:]
        var digests: [String: String] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let chunk = try? decoder.decode(SyncedTranscriptChunk.self, from: data) else {
                continue
            }
            let digest = SyncRecordDigest.sha256(chunk)
            if let existing = chunks[chunk.id] {
                let merged = existing.merging(chunk)
                chunks[chunk.id] = merged
                digests[chunk.id] = SyncRecordDigest.sha256(merged)
            } else {
                chunks[chunk.id] = chunk
                digests[chunk.id] = digest
            }
        }
        return (chunks, digests)
    }

    /// Incrementally writes changed chunks and deletes removed ones; performs zero disk I/O when unchanged.
    public static func sync(
        chunks: [String: SyncedTranscriptChunk],
        persistedDigests: inout [String: String],
        to directory: URL
    ) throws {
        var desiredDigests: [String: String] = [:]
        desiredDigests.reserveCapacity(chunks.count)
        var toWrite: [(id: String, chunk: SyncedTranscriptChunk, digest: String)] = []
        for (id, chunk) in chunks {
            let digest = SyncRecordDigest.sha256(chunk)
            desiredDigests[id] = digest
            if persistedDigests[id] != digest {
                toWrite.append((id, chunk, digest))
            }
        }
        let removedIDs = persistedDigests.keys.filter { desiredDigests[$0] == nil }
        guard !toWrite.isEmpty || !removedIDs.isEmpty else { return }

        let fileManager = FileManager.default
        if !toWrite.isEmpty {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = SyncRecordDigest.makeCanonicalEncoder()
            for item in toWrite {
                let data = try encoder.encode(item.chunk)
                try data.write(to: fileURL(for: item.id, in: directory), options: .atomic)
                persistedDigests[item.id] = item.digest
            }
        }
        for id in removedIDs {
            try? fileManager.removeItem(at: fileURL(for: id, in: directory))
            persistedDigests.removeValue(forKey: id)
        }
    }
}

/// High-churn CloudKit sync cursors and acknowledgement digests persisted separately from
/// full workspace metadata so 2-second sync polls never rewrite the full replica JSON.
public struct WorkspaceSyncCursorState: Codable, Equatable, Sendable {
    public var libraryToken: Data?
    public var transcriptToken: Data?
    public var scheduleToken: Data?
    public var zoneGenerations: [String: String]
    public var acknowledgedLibraryDigests: [String: String]
    public var acknowledgedTranscriptDigests: [String: String]
    public var acknowledgedScheduleDigests: [String: String]
    public var cloudTranscriptIndex: [String: Date]

    public init(
        libraryToken: Data? = nil,
        transcriptToken: Data? = nil,
        scheduleToken: Data? = nil,
        zoneGenerations: [String: String] = [:],
        acknowledgedLibraryDigests: [String: String] = [:],
        acknowledgedTranscriptDigests: [String: String] = [:],
        acknowledgedScheduleDigests: [String: String] = [:],
        cloudTranscriptIndex: [String: Date] = [:]
    ) {
        self.libraryToken = libraryToken
        self.transcriptToken = transcriptToken
        self.scheduleToken = scheduleToken
        self.zoneGenerations = zoneGenerations
        self.acknowledgedLibraryDigests = acknowledgedLibraryDigests
        self.acknowledgedTranscriptDigests = acknowledgedTranscriptDigests
        self.acknowledgedScheduleDigests = acknowledgedScheduleDigests
        self.cloudTranscriptIndex = cloudTranscriptIndex
    }
}

/// Incremental persistence for `WorkspaceSyncCursorState`; performs zero disk I/O when unchanged.
public enum WorkspaceSyncCursorSidecar {
    public static func loadWithDigest(from url: URL) -> (state: WorkspaceSyncCursorState?, digest: String?) {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(WorkspaceSyncCursorState.self, from: data) else {
            return (nil, nil)
        }
        return (state, SyncRecordDigest.sha256(state))
    }

    public static func sync(
        _ cursors: WorkspaceSyncCursorState,
        persistedDigest: inout String?,
        to url: URL
    ) throws {
        let data = try SyncRecordDigest.makeCanonicalEncoder().encode(cursors)
        let digest = SyncRecordDigest.sha256(data)
        guard persistedDigest != digest else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        persistedDigest = digest
    }
}
