import CloudKit
import Compression
import CryptoKit
import Foundation

public struct CloudZoneSession: Equatable, Sendable {
    public let account: String
    public let generation: String

    public init(account: String, generation: String) {
        self.account = account
        self.generation = generation
    }
}

public struct CloudZoneChanges<Record: SyncZoneRecord>: Sendable {
    public let records: [Record]
    public let deletedCloudRecordNames: [String]
    public let token: Data?

    public init(records: [Record], deletedCloudRecordNames: [String] = [], token: Data?) {
        self.records = records
        self.deletedCloudRecordNames = deletedCloudRecordNames
        self.token = token
    }
}

public enum CloudZoneError: Error, Equatable, Sendable {
    case noAccount
    case restricted
    case incompatibleData
    case payloadTooLarge
    case conflict
    case generationChanged
}

public enum CloudKitRateLimit {
    /// Extracts a backoff duration in seconds for transient CloudKit throttling/availability errors.
    /// Returns `nil` when `error` is not a rate-limit or transient server-busy failure.
    public static func retryAfter(for error: Error, consecutiveFailures: Int = 1) -> TimeInterval? {
        guard let info = inspect(error), info.matched else { return nil }
        let exponent = max(0, min(4, consecutiveFailures - 1))
        let exponential = min(120.0, 15.0 * pow(2.0, Double(exponent)))
        return max(info.explicitRetryAfter ?? 0, exponential)
    }

    private static func inspect(_ error: Error) -> (matched: Bool, explicitRetryAfter: TimeInterval?)? {
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else { return nil }
        let code = CKError.Code(rawValue: nsError.code)
        let retryAfter = (nsError.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
        if code == .requestRateLimited || code == .serviceUnavailable || code == .zoneBusy {
            return (true, retryAfter.flatMap { $0 > 0 ? $0 : nil })
        }
        if let partial = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            var bestRetry: TimeInterval?
            var matchedAny = false
            for child in partial.values {
                if let info = inspect(child), info.matched {
                    matchedAny = true
                    if let r = info.explicitRetryAfter {
                        bestRetry = max(bestRetry ?? 0, r)
                    }
                }
            }
            if matchedAny { return (true, bestRetry) }
        }
        return nil
    }

    public static func isTransientSyncError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else { return false }
        let code = CKError.Code(rawValue: nsError.code)
        switch code {
        case .requestRateLimited, .serviceUnavailable, .zoneBusy,
             .networkUnavailable, .networkFailure, .serverResponseLost:
            return true
        default:
            break
        }
        if let partial = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error], !partial.isEmpty {
            return partial.values.allSatisfy { isTransientSyncError($0) }
        }
        return false
    }
}

/// Shared container-wide CloudKit backoff coordinator so workspace, room, schedule,
/// and continuation transports honor throttling together.
public final class CloudKitBackoffGate: @unchecked Sendable {
    private let lock = NSLock()
    private var backoffUntilDate: Date = .distantPast
    private var consecutiveThrottles = 0

    public init() {}

    public func backoffUntil(now: Date = Date()) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return backoffUntilDate > now ? backoffUntilDate : nil
    }

    @discardableResult
    public func recordRateLimit(for error: Error, now: Date = Date()) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let delay = CloudKitRateLimit.retryAfter(for: error, consecutiveFailures: consecutiveThrottles + 1) else {
            return nil
        }
        consecutiveThrottles += 1
        backoffUntilDate = max(backoffUntilDate, now.addingTimeInterval(delay))
        return delay
    }

    public func recordSuccess() {
        lock.lock()
        consecutiveThrottles = 0
        backoffUntilDate = .distantPast
        lock.unlock()
    }
}

@MainActor
public protocol CloudZoneTransporting: AnyObject {
    associatedtype Record: SyncZoneRecord
    func connect() async throws -> CloudZoneSession
    func fetch(session: CloudZoneSession, after token: Data?) async throws -> CloudZoneChanges<Record>
    func save(_ records: [Record], session: CloudZoneSession) async throws -> [Record]
    func delete(syncRecordIDs: [String], session: CloudZoneSession) async throws
    func clear(session: CloudZoneSession) async throws
}

@MainActor
public final class AnyCloudZoneTransport<Record: SyncZoneRecord> {
    private let _connect: () async throws -> CloudZoneSession
    private let _fetch: (CloudZoneSession, Data?) async throws -> CloudZoneChanges<Record>
    private let _save: ([Record], CloudZoneSession) async throws -> [Record]
    private let _delete: ([String], CloudZoneSession) async throws -> Void
    private let _clear: (CloudZoneSession) async throws -> Void

    public init<T: CloudZoneTransporting>(_ transport: T) where T.Record == Record {
        _connect = { try await transport.connect() }
        _fetch = { try await transport.fetch(session: $0, after: $1) }
        _save = { try await transport.save($0, session: $1) }
        _delete = { try await transport.delete(syncRecordIDs: $0, session: $1) }
        _clear = { try await transport.clear(session: $0) }
    }

    public func connect() async throws -> CloudZoneSession { try await _connect() }
    public func fetch(session: CloudZoneSession, after token: Data?) async throws -> CloudZoneChanges<Record> {
        try await _fetch(session, token)
    }
    public func save(_ records: [Record], session: CloudZoneSession) async throws -> [Record] {
        try await _save(records, session)
    }
    public func delete(syncRecordIDs: [String], session: CloudZoneSession) async throws {
        try await _delete(syncRecordIDs, session)
    }
    public func clear(session: CloudZoneSession) async throws {
        try await _clear(session)
    }
}

private final class CloudCodecPool: @unchecked Sendable {
    static let shared = CloudCodecPool()
    private let lock = NSLock()
    private var encoders: [JSONEncoder] = []
    private var decoders: [JSONDecoder] = []

    func withEncoder<T>(_ body: (JSONEncoder) throws -> T) rethrows -> T {
        lock.lock()
        let encoder = encoders.popLast() ?? JSONEncoder()
        lock.unlock()
        defer {
            lock.lock()
            if encoders.count < 8 { encoders.append(encoder) }
            lock.unlock()
        }
        return try body(encoder)
    }

    func withDecoder<T>(_ body: (JSONDecoder) throws -> T) rethrows -> T {
        lock.lock()
        let decoder = decoders.popLast() ?? JSONDecoder()
        lock.unlock()
        defer {
            lock.lock()
            if decoders.count < 8 { decoders.append(decoder) }
            lock.unlock()
        }
        return try body(decoder)
    }
}

public enum CloudPayloadCodec {
    private static let lzfseMagic = Data("RNRLZF1".utf8)
    public static let maxRecordBytes = 512 * 1024
    private static let maxUncompressedBytes = 16 * 1024 * 1024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let raw = try CloudCodecPool.shared.withEncoder { try $0.encode(value) }
        let compressed = compressLZFSE(raw)
        let candidate = (compressed != nil && compressed!.count < raw.count) ? compressed! : raw
        guard candidate.count <= maxRecordBytes else {
            throw CloudZoneError.payloadTooLarge
        }
        return candidate
    }

    public static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let jsonData: Data
        if data.starts(with: lzfseMagic) {
            guard let restored = decompressLZFSE(data) else {
                throw CloudZoneError.incompatibleData
            }
            jsonData = restored
        } else {
            jsonData = data
        }
        return try CloudCodecPool.shared.withDecoder { try $0.decode(T.self, from: jsonData) }
    }

    private static func compressLZFSE(_ raw: Data) -> Data? {
        guard !raw.isEmpty, raw.count <= maxUncompressedBytes else { return nil }
        let capacity = raw.count + 64
        var dst = Data(count: capacity)
        let written: Int = raw.withUnsafeBytes { srcBytes in
            guard let srcPtr = srcBytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return dst.withUnsafeMutableBytes { dstBytes in
                guard let dstPtr = dstBytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dstPtr, capacity, srcPtr, raw.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written > 0 else { return nil }
        var out = Data()
        out.reserveCapacity(lzfseMagic.count + 4 + written)
        out.append(lzfseMagic)
        var lengthLE = UInt32(raw.count).littleEndian
        withUnsafeBytes(of: &lengthLE) { out.append(contentsOf: $0) }
        out.append(dst.prefix(written))
        return out
    }

    private static func decompressLZFSE(_ payload: Data) -> Data? {
        let headerSize = lzfseMagic.count + 4
        guard payload.count > headerSize else { return nil }
        let base = payload.startIndex
        var lengthLE: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &lengthLE) {
            payload.copyBytes(to: $0, from: (base + lzfseMagic.count)..<(base + headerSize))
        }
        let expectedSize = Int(UInt32(littleEndian: lengthLE))
        guard expectedSize > 0, expectedSize <= maxUncompressedBytes else { return nil }
        let compressed = payload.subdata(in: (base + headerSize)..<payload.endIndex)
        var dst = Data(count: expectedSize)
        let decoded: Int = compressed.withUnsafeBytes { srcBytes in
            guard let srcPtr = srcBytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return dst.withUnsafeMutableBytes { dstBytes in
                guard let dstPtr = dstBytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstPtr, expectedSize, srcPtr, compressed.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard decoded == expectedSize else { return nil }
        return dst
    }
}

private extension JSONEncoder {
    static var syncCodec: JSONEncoder {
        let encoder = JSONEncoder()
        return encoder
    }
}

private extension JSONDecoder {
    static var syncCodec: JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }
}

/// Encrypted private-database zone transport for high-frequency workspace, transcript, and calendar zones.
/// Unlike `SavedJams`, routine writes do not contend on `SyncControl`'s change tag; `generation` is
/// verified via `SyncControl` on connect/fetch and embedded inside each encrypted record envelope.
@MainActor
public final class CloudEnvelopeTransport<Record: SyncZoneRecord>: CloudZoneTransporting {
    public static var defaultContainerIdentifier: String { "iCloud.dev.vsmirn0v.conferenceguest" }
    public static var maxBatchRecords: Int { 100 }
    public static var maxBatchBytes: Int { 1_200_000 }

    private struct Envelope: Codable, Sendable {
        var schema = 2
        let generation: String
        let record: Record
    }

    private lazy var container = CKContainer(identifier: containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let containerIdentifier: String
    private let zone: CKRecordZone.ID
    private let subscriptionID: String
    private let notifications: Bool
    private var cachedSession: CloudZoneSession?
    private var cachedSessionAt: Date?
    private var lastControlVerifiedAt: Date?
    private var subscriptionRegistered = false
    private var systemFieldsByRecordID: [CKRecord.ID: Data] = [:]
    private var controlID: CKRecord.ID { .init(recordName: "SyncGeneration", zoneID: zone) }

    public init(
        zoneName: String,
        subscriptionID: String? = nil,
        containerIdentifier: String = "iCloud.dev.vsmirn0v.conferenceguest",
        notifications: Bool = true
    ) {
        self.containerIdentifier = containerIdentifier
        self.zone = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        self.subscriptionID = subscriptionID ?? (zoneName + "Changes")
        self.notifications = notifications
    }

    nonisolated private static func encodeSystemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    nonisolated private static func makeRecordFromSystemFields(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }

    nonisolated private static func encodeEnvelopePayload(_ record: Record, generation: String) throws -> Data {
        try CloudPayloadCodec.encode(Envelope(generation: generation, record: record))
    }

    nonisolated public static func cloudRecordName(for syncRecordID: String) -> String {
        let digest = SHA256.hash(data: Data(syncRecordID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "item-" + digest
    }

    private func recordID(for syncRecordID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: Self.cloudRecordName(for: syncRecordID), zoneID: zone)
    }

    private func invalidateCachedZoneState() {
        cachedSession = nil
        cachedSessionAt = nil
        lastControlVerifiedAt = nil
        subscriptionRegistered = false
        systemFieldsByRecordID.removeAll()
    }

    public func connect() async throws -> CloudZoneSession {
        if let cached = cachedSession, let at = cachedSessionAt, Date().timeIntervalSince(at) < 900 {
            return cached
        }
        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                invalidateCachedZoneState()
                throw status == .restricted ? CloudZoneError.restricted : CloudZoneError.noAccount
            }
            let account = try await container.userRecordID().recordName
            do {
                _ = try await database.recordZone(for: zone)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                _ = try await database.save(CKRecordZone(zoneID: zone))
            }
            let control: CKRecord
            do {
                control = try await database.record(for: controlID)
            } catch let error as CKError where error.code == .unknownItem {
                let new = CKRecord(recordType: "SyncControl", recordID: controlID)
                new.encryptedValues["generation"] = UUID().uuidString as CKRecordValue
                do {
                    control = try await database.save(new)
                } catch let conflict as CKError where conflict.code == .serverRecordChanged {
                    control = try await database.record(for: controlID)
                }
            }
            guard let generation = control.encryptedValues["generation"] as? String else {
                throw CloudZoneError.incompatibleData
            }
            if notifications && !subscriptionRegistered {
                let subscription = CKRecordZoneSubscription(zoneID: zone, subscriptionID: subscriptionID)
                let info = CKSubscription.NotificationInfo()
                info.shouldSendContentAvailable = true
                subscription.notificationInfo = info
                if (try? await database.save(subscription)) != nil {
                    subscriptionRegistered = true
                }
            }
            let session = CloudZoneSession(account: account, generation: generation)
            let now = Date()
            cachedSession = session
            cachedSessionAt = now
            lastControlVerifiedAt = now
            return session
        } catch {
            if let ck = error as? CKError, [.zoneNotFound, .userDeletedZone].contains(ck.code) {
                invalidateCachedZoneState()
            }
            throw error
        }
    }

    public func fetch(session: CloudZoneSession, after data: Data?) async throws -> CloudZoneChanges<Record> {
        let token = try data.map {
            try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        } ?? nil
        do {
            return try await fetchChanges(session: session, token: token)
        } catch let error as CKError where error.code == .changeTokenExpired {
            systemFieldsByRecordID.removeAll()
            return try await fetchChanges(session: session, token: nil)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            invalidateCachedZoneState()
            throw CloudZoneError.generationChanged
        } catch CloudZoneError.generationChanged {
            invalidateCachedZoneState()
            throw CloudZoneError.generationChanged
        }
    }

    private func fetchChanges(session: CloudZoneSession, token: CKServerChangeToken?) async throws -> CloudZoneChanges<Record> {
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = token
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zone],
            configurationsByRecordZoneID: [zone: config]
        )
        operation.fetchAllChanges = true
        operation.qualityOfService = .utility
        operation.configuration.qualityOfService = .utility
        let expectedControlID = controlID
        let targetZone = zone
        let resultTuple: (changes: CloudZoneChanges<Record>, fetchedSystemFields: [CKRecord.ID: Data]) = try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var records: [Record] = []
            var deletedNames: [String] = []
            var fetchedSystemFields: [CKRecord.ID: Data] = [:]
            var nextToken: CKServerChangeToken?
            var failure: Error?
            operation.recordWasChangedBlock = { id, result in
                do {
                    let record = try result.get()
                    if id == expectedControlID {
                        if record.encryptedValues["generation"] as? String != session.generation {
                            throw CloudZoneError.generationChanged
                        }
                    } else if let decoded = try Self.decodeChangedItemRecord(
                        record,
                        generation: session.generation,
                        zone: targetZone
                    ) {
                        let systemFields = Self.encodeSystemFields(of: record)
                        lock.lock()
                        records.append(decoded)
                        fetchedSystemFields[id] = systemFields
                        lock.unlock()
                    }
                } catch {
                    lock.lock()
                    failure = error
                    lock.unlock()
                }
            }
            operation.recordWithIDWasDeletedBlock = { id, _ in
                lock.lock()
                if id == expectedControlID {
                    failure = CloudZoneError.generationChanged
                } else {
                    deletedNames.append(id.recordName)
                }
                lock.unlock()
            }
            operation.recordZoneFetchResultBlock = { _, result in
                lock.lock()
                switch result {
                case .success(let value): nextToken = value.serverChangeToken
                case .failure(let error): failure = error
                }
                lock.unlock()
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                lock.lock()
                let capturedRecords = records
                let capturedDeleted = deletedNames
                let capturedFields = fetchedSystemFields
                let capturedToken = nextToken
                let capturedFailure = failure
                lock.unlock()
                do {
                    try result.get()
                    if let capturedFailure { throw capturedFailure }
                    let encoded = try capturedToken.map {
                        try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
                    }
                    continuation.resume(returning: (
                        CloudZoneChanges(
                            records: capturedRecords,
                            deletedCloudRecordNames: capturedDeleted,
                            token: encoded
                        ),
                        capturedFields
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
        for (id, fields) in resultTuple.fetchedSystemFields {
            systemFieldsByRecordID[id] = fields
        }
        for name in resultTuple.changes.deletedCloudRecordNames {
            systemFieldsByRecordID.removeValue(forKey: CKRecord.ID(recordName: name, zoneID: zone))
        }
        return resultTuple.changes
    }

    public func save(_ records: [Record], session: CloudZoneSession) async throws -> [Record] {
        guard !records.isEmpty else { return [] }
        let needsControlCheck = cachedSession != session
            || lastControlVerifiedAt.map { Date().timeIntervalSince($0) >= 300 } ?? true
        if needsControlCheck {
            guard try await container.userRecordID().recordName == session.account else {
                throw CloudZoneError.noAccount
            }
            _ = try await verifyControl(expectedGeneration: session.generation)
        }

        let generation = session.generation
        let maxBatchRecords = Self.maxBatchRecords
        let maxBatchBytes = Self.maxBatchBytes
        let encodedBatches: [[(record: Record, payload: Data)]] = try await Task.detached(priority: .utility) {
            var batches: [[(record: Record, payload: Data)]] = []
            var currentBatch: [(record: Record, payload: Data)] = []
            var currentBytes = 0
            for item in records {
                let data = try Self.encodeEnvelopePayload(item, generation: generation)
                if !currentBatch.isEmpty &&
                    (currentBatch.count >= maxBatchRecords || currentBytes + data.count > maxBatchBytes) {
                    batches.append(currentBatch)
                    currentBatch = []
                    currentBytes = 0
                }
                currentBatch.append((item, data))
                currentBytes += data.count
            }
            if !currentBatch.isEmpty {
                batches.append(currentBatch)
            }
            return batches
        }.value

        var saved: [Record] = []
        for batch in encodedBatches {
            let batchSaved = try await saveBatch(batch, session: session, attempt: 0)
            saved.append(contentsOf: batchSaved)
        }
        return saved
    }

    private func saveBatch(_ items: [(record: Record, payload: Data)], session: CloudZoneSession, attempt: Int) async throws -> [Record] {
        guard !items.isEmpty else { return [] }

        var ckRecords: [CKRecord] = []
        var itemsByCKID: [CKRecord.ID: (record: Record, payload: Data)] = [:]
        for item in items {
            let id = recordID(for: item.record.syncRecordID)
            let ckRecord: CKRecord
            if let fields = systemFieldsByRecordID[id], let restored = Self.makeRecordFromSystemFields(fields) {
                ckRecord = restored
            } else {
                ckRecord = CKRecord(recordType: "RoomPreference", recordID: id)
            }
            ckRecord.encryptedValues["payload"] = item.payload as CKRecordValue
            ckRecords.append(ckRecord)
            itemsByCKID[id] = item
        }

        do {
            let outcomes = try await modifyRecordsUtility(saving: ckRecords, deleting: [])
            var saved: [Record] = []
            var conflictedIDs: [CKRecord.ID] = []
            var serverRecordsByID: [CKRecord.ID: CKRecord] = [:]

            for (ckID, result) in outcomes {
                switch result {
                case .success(let savedRecord):
                    systemFieldsByRecordID[ckID] = Self.encodeSystemFields(of: savedRecord)
                    if let item = itemsByCKID[ckID] {
                        saved.append(item.record)
                    }
                case .failure(let error as CKError) where Self.isConflict(error):
                    conflictedIDs.append(ckID)
                    if let serverRecord = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                        serverRecordsByID[ckID] = serverRecord
                    }
                case .failure(let error as CKError) where error.code == .unknownItem:
                    systemFieldsByRecordID.removeValue(forKey: ckID)
                    conflictedIDs.append(ckID)
                case .failure(let error as CKError) where error.code == .zoneNotFound || error.code == .userDeletedZone:
                    invalidateCachedZoneState()
                    throw CloudZoneError.generationChanged
                case .failure(let error):
                    throw error
                }
            }
            if !conflictedIDs.isEmpty {
                guard attempt < 3 else { throw CloudZoneError.conflict }
                let mergedItems = try await resolveConflicts(
                    conflictedIDs: conflictedIDs,
                    itemsByCKID: itemsByCKID,
                    serverRecordsByID: serverRecordsByID,
                    generation: session.generation
                )
                let retried = try await saveBatch(mergedItems, session: session, attempt: attempt + 1)
                saved.append(contentsOf: retried)
            }
            return saved
        } catch let error as CKError where error.code == .limitExceeded && items.count > 1 {
            let mid = items.count / 2
            let left = try await saveBatch(Array(items[..<mid]), session: session, attempt: attempt)
            let right = try await saveBatch(Array(items[mid...]), session: session, attempt: attempt)
            return left + right
        } catch let error as CKError where Self.isConflict(error) {
            guard attempt < 3 else { throw CloudZoneError.conflict }
            let mergedItems = try await resolveConflicts(
                conflictedIDs: Array(itemsByCKID.keys),
                itemsByCKID: itemsByCKID,
                serverRecordsByID: [:],
                generation: session.generation
            )
            return try await saveBatch(mergedItems, session: session, attempt: attempt + 1)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            invalidateCachedZoneState()
            throw CloudZoneError.generationChanged
        }
    }

    private func resolveConflicts(
        conflictedIDs: [CKRecord.ID],
        itemsByCKID: [CKRecord.ID: (record: Record, payload: Data)],
        serverRecordsByID: [CKRecord.ID: CKRecord],
        generation: String
    ) async throws -> [(record: Record, payload: Data)] {
        var resolvedRecords = serverRecordsByID
        let missingIDs = conflictedIDs.filter { resolvedRecords[$0] == nil }
        if !missingIDs.isEmpty {
            let fetched = try await fetchRecordsUtility(ids: missingIDs)
            for (id, result) in fetched {
                switch result {
                case .success(let serverRecord):
                    resolvedRecords[id] = serverRecord
                case .failure(let error as CKError) where error.code == .unknownItem:
                    systemFieldsByRecordID.removeValue(forKey: id)
                case .failure(let error as CKError) where error.code == .zoneNotFound || error.code == .userDeletedZone:
                    invalidateCachedZoneState()
                    throw CloudZoneError.generationChanged
                case .failure(let error):
                    throw error
                }
            }
        }
        var pairsToEncode: [(item: (record: Record, payload: Data), serverDecoded: Record?)] = []
        for id in conflictedIDs {
            guard let item = itemsByCKID[id] else { continue }
            if let serverRecord = resolvedRecords[id] {
                systemFieldsByRecordID[id] = Self.encodeSystemFields(of: serverRecord)
                let serverDecoded = try decode(serverRecord, generation: generation)
                pairsToEncode.append((item, serverDecoded))
            } else {
                systemFieldsByRecordID.removeValue(forKey: id)
                pairsToEncode.append((item, nil))
            }
        }
        return try await Task.detached(priority: .utility) {
            try pairsToEncode.map { pair in
                let merged = pair.serverDecoded.map { pair.item.record.merging($0) } ?? pair.item.record
                if merged == pair.item.record {
                    return pair.item
                }
                let data = try Self.encodeEnvelopePayload(merged, generation: generation)
                return (merged, data)
            }
        }.value
    }

    private func modifyRecordsUtility(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        let operation = CKModifyRecordsOperation(recordsToSave: saving.isEmpty ? nil : saving, recordIDsToDelete: deleting.isEmpty ? nil : deleting)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = false
        operation.qualityOfService = .utility
        operation.configuration.qualityOfService = .utility
        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var saveOutcomes: [CKRecord.ID: Result<CKRecord, Error>] = [:]
            var deleteError: Error?
            operation.perRecordSaveBlock = { recordID, result in
                lock.lock()
                saveOutcomes[recordID] = result
                lock.unlock()
            }
            operation.perRecordDeleteBlock = { _, result in
                if case .failure(let error) = result {
                    if let ck = error as? CKError,
                       ck.code == .unknownItem || ck.code == .zoneNotFound || ck.code == .userDeletedZone {
                        return
                    }
                    lock.lock()
                    if deleteError == nil { deleteError = error }
                    lock.unlock()
                }
            }
            operation.modifyRecordsResultBlock = { result in
                lock.lock()
                let captured = saveOutcomes
                let capturedDeleteError = deleteError
                lock.unlock()
                if let capturedDeleteError {
                    continuation.resume(throwing: capturedDeleteError)
                    return
                }
                switch result {
                case .success:
                    continuation.resume(returning: captured)
                case .failure(let error):
                    if Self.isConflict(error as? CKError ?? CKError(.internalError)), !captured.isEmpty {
                        continuation.resume(returning: captured)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
            database.add(operation)
        }
    }

    private func fetchRecordsUtility(ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        let operation = CKFetchRecordsOperation(recordIDs: ids)
        operation.qualityOfService = .utility
        operation.configuration.qualityOfService = .utility
        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var fetched: [CKRecord.ID: Result<CKRecord, Error>] = [:]
            operation.perRecordResultBlock = { recordID, result in
                lock.lock()
                fetched[recordID] = result
                lock.unlock()
            }
            operation.fetchRecordsResultBlock = { result in
                lock.lock()
                let captured = fetched
                lock.unlock()
                switch result {
                case .success:
                    continuation.resume(returning: captured)
                case .failure(let error):
                    if !captured.isEmpty {
                        continuation.resume(returning: captured)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
            database.add(operation)
        }
    }

    public func delete(syncRecordIDs: [String], session: CloudZoneSession) async throws {
        guard !syncRecordIDs.isEmpty else { return }
        let needsControlCheck = cachedSession != session
            || lastControlVerifiedAt.map { Date().timeIntervalSince($0) >= 300 } ?? true
        if needsControlCheck {
            guard try await container.userRecordID().recordName == session.account else {
                throw CloudZoneError.noAccount
            }
            _ = try await verifyControl(expectedGeneration: session.generation)
        }
        let ckIDs = syncRecordIDs.map { recordID(for: $0) }
        for offset in stride(from: 0, to: ckIDs.count, by: Self.maxBatchRecords) {
            let slice = Array(ckIDs[offset..<min(offset + Self.maxBatchRecords, ckIDs.count)])
            try await deleteBatch(slice)
            for id in slice { systemFieldsByRecordID.removeValue(forKey: id) }
        }
    }

    private func deleteBatch(_ ids: [CKRecord.ID]) async throws {
        guard !ids.isEmpty else { return }
        do {
            _ = try await modifyRecordsUtility(saving: [], deleting: ids)
        } catch let error as CKError where error.code == .limitExceeded && ids.count > 1 {
            let mid = ids.count / 2
            try await deleteBatch(Array(ids[..<mid]))
            try await deleteBatch(Array(ids[mid...]))
        }
    }

    public func clear(session: CloudZoneSession) async throws {
        let previousAccount = cachedSession?.account
        invalidateCachedZoneState()
        if previousAccount != session.account {
            guard try await container.userRecordID().recordName == session.account else {
                throw CloudZoneError.noAccount
            }
        }
        do {
            _ = try await verifyControl(expectedGeneration: session.generation)
            _ = try await database.deleteRecordZone(withID: zone)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // Already deleted.
        }
        _ = try await connect()
    }

    private func verifyControl(expectedGeneration: String) async throws -> CKRecord {
        let control: CKRecord
        do {
            control = try await database.record(for: controlID)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone || error.code == .unknownItem {
            invalidateCachedZoneState()
            throw CloudZoneError.generationChanged
        }
        guard control.encryptedValues["generation"] as? String == expectedGeneration else {
            invalidateCachedZoneState()
            throw CloudZoneError.generationChanged
        }
        lastControlVerifiedAt = Date()
        return control
    }

    nonisolated internal static func decodeChangedItemRecord(
        _ record: CKRecord,
        generation: String,
        zone: CKRecordZone.ID
    ) throws -> Record? {
        try decodeChangedItemPayload(
            record.encryptedValues["payload"] as? Data,
            hasChangeTag: record.recordChangeTag != nil,
            recordID: record.recordID,
            generation: generation,
            zone: zone
        )
    }

    nonisolated internal static func decodeChangedItemPayload(
        _ data: Data?,
        hasChangeTag: Bool,
        recordID: CKRecord.ID,
        generation: String,
        zone: CKRecordZone.ID
    ) throws -> Record? {
        do {
            return try decodePayload(
                data,
                hasChangeTag: hasChangeTag,
                recordID: recordID,
                generation: generation,
                zone: zone
            )
        } catch CloudZoneError.incompatibleData, is DecodingError {
            // Skip individual corrupted or future-schema item records so one poisoned item cannot block the zone.
            return nil
        }
    }

    nonisolated private static func decodeRecord(
        _ record: CKRecord,
        generation: String,
        zone: CKRecordZone.ID
    ) throws -> Record? {
        try decodePayload(
            record.encryptedValues["payload"] as? Data,
            hasChangeTag: record.recordChangeTag != nil,
            recordID: record.recordID,
            generation: generation,
            zone: zone
        )
    }

    nonisolated private static func decodePayload(
        _ data: Data?,
        hasChangeTag: Bool,
        recordID: CKRecord.ID,
        generation: String,
        zone: CKRecordZone.ID
    ) throws -> Record? {
        guard let data else {
            if !hasChangeTag { return nil }
            throw CloudZoneError.incompatibleData
        }
        let envelope = try CloudPayloadCodec.decode(data, as: Envelope.self)
        guard envelope.schema == 2,
              envelope.record.maximumSyncCounter >= 0,
              envelope.record.maximumSyncCounter < Int64.max - 1_000_000 else {
            throw CloudZoneError.incompatibleData
        }
        guard envelope.generation == generation else {
            throw CloudZoneError.generationChanged
        }
        let expectedID = CKRecord.ID(recordName: Self.cloudRecordName(for: envelope.record.syncRecordID), zoneID: zone)
        guard expectedID == recordID else {
            throw CloudZoneError.incompatibleData
        }
        return envelope.record
    }

    private func decode(_ record: CKRecord, generation: String) throws -> Record? {
        try Self.decodeRecord(record, generation: generation, zone: zone)
    }

    private static func isConflict(_ error: CKError) -> Bool {
        if error.code == .serverRecordChanged { return true }
        if let partial = error.partialErrorsByItemID {
            return partial.values.contains { ($0 as? CKError).map(isConflict) ?? false }
        }
        return false
    }
}
