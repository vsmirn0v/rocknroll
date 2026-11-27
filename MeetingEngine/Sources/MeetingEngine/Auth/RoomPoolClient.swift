import ConferenceCore
import Foundation

public struct RoomPoolRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { poolKey }
    public var poolKey: String
    public var serviceOrigin: String
    public var poolID: String
    public var label: String?
    public var lastKnownAvailable: Int?
    public var lastKnownUsed: Int?
    public var lastKnownOrigins: [String: Int]
    public var addedAt: Date
    public var updatedAt: Date

    public init(
        poolKey: String,
        serviceOrigin: String,
        poolID: String,
        label: String? = nil,
        lastKnownAvailable: Int? = nil,
        lastKnownUsed: Int? = nil,
        lastKnownOrigins: [String: Int] = [:],
        addedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.poolKey = poolKey
        self.serviceOrigin = serviceOrigin
        self.poolID = poolID
        self.label = label
        self.lastKnownAvailable = lastKnownAvailable
        self.lastKnownUsed = lastKnownUsed
        self.lastKnownOrigins = lastKnownOrigins
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }

    public var serviceOriginURL: URL? { URL(string: serviceOrigin) }

    public var displayTitle: String {
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return "\(poolID) · \(label)"
        }
        return poolID
    }
}

public struct RoomPoolStatus: Equatable, Sendable {
    public let poolID: String
    public let label: String
    public let availableCount: Int
    public let usedCount: Int
    public let origins: [String: Int]

    public init(poolID: String, label: String, availableCount: Int, usedCount: Int, origins: [String: Int]) {
        self.poolID = poolID
        self.label = label
        self.availableCount = availableCount
        self.usedCount = usedCount
        self.origins = origins
    }
}

public struct ClaimedPoolRoom: Equatable, Sendable {
    public let poolID: String
    public let roomURL: URL
    public let origin: URL
    public let remainingCount: Int
    public let replayed: Bool

    public init(poolID: String, roomURL: URL, origin: URL, remainingCount: Int, replayed: Bool) {
        self.poolID = poolID
        self.roomURL = roomURL
        self.origin = origin
        self.remainingCount = remainingCount
        self.replayed = replayed
    }
}

public struct QueuedPoolLink: Equatable, Identifiable, Sendable {
    public let id: Int
    public let url: URL
    public let origin: URL
    public let addedAt: Date
}

public struct AddPoolLinksResult: Equatable, Sendable {
    public let added: Int
    public let skippedDuplicates: Int
    public let invalid: Int
    public let availableCount: Int
}

public struct RemovePoolLinksResult: Equatable, Sendable {
    public let removed: Int
    public let availableCount: Int
}

public enum RoomPoolError: LocalizedError, Equatable {
    case invalidCoordinationLink
    case invalidAuthToken(poolID: String)
    case writeTokenRequired
    case invalidWriteToken
    case poolEmpty(poolID: String)
    case poolFull(limit: Int)
    case poolAlreadyExists(poolID: String)
    case rateLimited
    case serverError(Int, String?)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidCoordinationLink:
            return L("Enter a valid room coordination link.")
        case .invalidAuthToken(let poolID):
            return L("Pool %@ rejected the coordination link token.", poolID)
        case .writeTokenRequired:
            return L("Enter the pool write password to modify links.")
        case .invalidWriteToken:
            return L("The pool write password was rejected.")
        case .poolEmpty(let poolID):
            return L("Pool %@ has no unused rooms left.", poolID)
        case .poolFull(let limit):
            return L("This pool already has the maximum of %ld unused links.", limit)
        case .poolAlreadyExists(let poolID):
            return L("Pool %@ already exists.", poolID)
        case .rateLimited:
            return L("Too many pool requests. Try again in a minute.")
        case .serverError(let status, let message):
            if let message, !message.isEmpty { return message }
            return L("Pool service failed (HTTP %ld).", status)
        case .invalidResponse:
            return L("The pool service returned an unexpected response.")
        }
    }
}

@MainActor
public final class RoomPoolStore: ObservableObject {
    public static let shared = RoomPoolStore()

    @Published public private(set) var pools: [RoomPoolRecord] = []
    @Published public private(set) var activePoolKey: String?
    @Published public private(set) var anonymousDisabledOrigins: [String: Date] = [:]

    private static let poolsDefaultsKey = "roomPools.records.v1"
    private static let activePoolKeyDefaultsKey = "roomPools.activePoolKey.v1"
    private static let disabledOriginsDefaultsKey = "roomPools.anonymousDisabledOrigins.v1"
    private static let disabledOriginTTL: TimeInterval = 24 * 60 * 60

    public let secretStore: any SiteSecretStoring
    private let preferences: UserDefaults

    public init(
        preferences: UserDefaults = .standard,
        secretStore: (any SiteSecretStoring)? = nil
    ) {
        self.preferences = preferences
        self.secretStore = secretStore ?? SiteAccountStore.shared.secretStore
        load()
    }

    public var activePool: RoomPoolRecord? {
        if let activePoolKey, let match = pools.first(where: { $0.poolKey == activePoolKey }) {
            return match
        }
        return pools.first
    }

    public func link(for record: RoomPoolRecord) -> RoomPoolLink? {
        guard let originURL = record.serviceOriginURL,
              let secret = secretStore.readPoolSecret(poolKey: record.poolKey),
              !secret.authToken.isEmpty else {
            return nil
        }
        return try? RoomPoolLink(serviceOrigin: originURL, poolID: record.poolID, authToken: secret.authToken)
    }

    public func activePoolLink() -> RoomPoolLink? {
        guard let activePool else { return nil }
        return link(for: activePool)
    }

    public func writeToken(for poolKey: String) -> String? {
        secretStore.readPoolSecret(poolKey: poolKey)?.writeToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public func saveWriteToken(_ rawToken: String?, for poolKey: String) {
        let cleaned = rawToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard var existing = secretStore.readPoolSecret(poolKey: poolKey) else { return }
        existing.writeToken = cleaned
        _ = secretStore.writePoolSecret(existing, poolKey: poolKey)
    }

    @discardableResult
    public func upsertPool(
        _ link: RoomPoolLink,
        status: RoomPoolStatus? = nil,
        writeToken: String? = nil,
        makeActive: Bool = true
    ) -> RoomPoolRecord {
        let key = link.poolKey
        let existingSecret = secretStore.readPoolSecret(poolKey: key)
        let resolvedWriteToken = writeToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? existingSecret?.writeToken
        _ = secretStore.writePoolSecret(
            StoredRoomPoolSecret(authToken: link.authToken, writeToken: resolvedWriteToken),
            poolKey: key
        )

        let now = Date()
        let existing = pools.first(where: { $0.poolKey == key })
        let updated = RoomPoolRecord(
            poolKey: key,
            serviceOrigin: link.serviceOrigin.absoluteString,
            poolID: link.poolID,
            label: status?.label.nilIfEmpty ?? existing?.label,
            lastKnownAvailable: status?.availableCount ?? existing?.lastKnownAvailable,
            lastKnownUsed: status?.usedCount ?? existing?.lastKnownUsed,
            lastKnownOrigins: status?.origins ?? existing?.lastKnownOrigins ?? [:],
            addedAt: existing?.addedAt ?? now,
            updatedAt: now
        )
        if let idx = pools.firstIndex(where: { $0.poolKey == key }) {
            pools[idx] = updated
        } else {
            pools.insert(updated, at: 0)
        }
        if makeActive || activePoolKey == nil {
            activePoolKey = key
        }
        persist()
        return updated
    }

    public func updateCounts(poolKey: String, availableCount: Int, usedCount: Int? = nil, origins: [String: Int]? = nil) {
        guard let idx = pools.firstIndex(where: { $0.poolKey == poolKey }) else { return }
        pools[idx].lastKnownAvailable = availableCount
        if let usedCount { pools[idx].lastKnownUsed = usedCount }
        if let origins { pools[idx].lastKnownOrigins = origins }
        pools[idx].updatedAt = Date()
        persist()
    }

    public func setActivePool(poolKey: String?) {
        guard let poolKey else {
            activePoolKey = nil
            persist()
            return
        }
        guard pools.contains(where: { $0.poolKey == poolKey }) else { return }
        activePoolKey = poolKey
        persist()
    }

    public func removePool(poolKey: String) {
        _ = secretStore.writePoolSecret(nil, poolKey: poolKey)
        pools.removeAll { $0.poolKey == poolKey }
        if activePoolKey == poolKey {
            activePoolKey = pools.first?.poolKey
        }
        persist()
    }

    public func isAnonymousCreationDisabled(for origin: URL, now: Date = Date()) -> Bool {
        guard let key = SiteOrigin.canonicalKey(for: origin),
              let recorded = anonymousDisabledOrigins[key] else {
            return false
        }
        if now.timeIntervalSince(recorded) >= Self.disabledOriginTTL {
            anonymousDisabledOrigins.removeValue(forKey: key)
            persistDisabledOrigins()
            return false
        }
        return true
    }

    public func markAnonymousCreationDisabled(for origin: URL, now: Date = Date()) {
        guard let key = SiteOrigin.canonicalKey(for: origin) else { return }
        anonymousDisabledOrigins[key] = now
        persistDisabledOrigins()
    }

    public func clearAnonymousCreationDisabled(for origin: URL) {
        guard let key = SiteOrigin.canonicalKey(for: origin) else { return }
        if anonymousDisabledOrigins.removeValue(forKey: key) != nil {
            persistDisabledOrigins()
        }
    }

    private func load() {
        if let data = preferences.data(forKey: Self.poolsDefaultsKey),
           let decoded = try? JSONDecoder().decode([RoomPoolRecord].self, from: data) {
            pools = decoded
        }
        activePoolKey = preferences.string(forKey: Self.activePoolKeyDefaultsKey)
        if let activePoolKey, !pools.contains(where: { $0.poolKey == activePoolKey }) {
            self.activePoolKey = pools.first?.poolKey
        }
        if let rawMap = preferences.dictionary(forKey: Self.disabledOriginsDefaultsKey) as? [String: TimeInterval] {
            let now = Date()
            var loaded: [String: Date] = [:]
            for (key, ts) in rawMap {
                let date = Date(timeIntervalSince1970: ts)
                if now.timeIntervalSince(date) < Self.disabledOriginTTL {
                    loaded[key] = date
                }
            }
            anonymousDisabledOrigins = loaded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pools) {
            preferences.set(data, forKey: Self.poolsDefaultsKey)
        }
        if let activePoolKey {
            preferences.set(activePoolKey, forKey: Self.activePoolKeyDefaultsKey)
        } else {
            preferences.removeObject(forKey: Self.activePoolKeyDefaultsKey)
        }
    }

    private func persistDisabledOrigins() {
        let encoded = anonymousDisabledOrigins.mapValues(\.timeIntervalSince1970)
        preferences.set(encoded, forKey: Self.disabledOriginsDefaultsKey)
    }
}

public final class RoomPoolClient: @unchecked Sendable {
    private let makeSession: @Sendable (URL) -> URLSession
    private let fallbackLock = NSLock()
    private var getActionFallbackOrigins = Set<String>()

    public init(makeSession: (@Sendable (URL) -> URLSession)? = nil) {
        self.makeSession = makeSession ?? { origin in
            SiteTLSDelegate.makeEphemeralSession(preferredOrigin: origin, lookup: SiteClientIdentityRegistry.shared, timeout: 15, allowsCookies: false)
        }
    }

    public func createPool(
        serviceOrigin: URL = RoomPoolLink.defaultServiceOrigin,
        poolID: String? = nil,
        label: String? = nil,
        writeToken: String
    ) async throws -> RoomPoolLink {
        let cleanWrite = writeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanWrite.isEmpty else { throw RoomPoolError.writeTokenRequired }
        var body: [String: Any] = [:]
        if let cleanID = poolID?.trimmingCharacters(in: .whitespacesAndNewlines), !cleanID.isEmpty {
            body["poolId"] = cleanID
        }
        if let cleanLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines), !cleanLabel.isEmpty {
            body["label"] = cleanLabel
        }
        let json = try await requestJSON(
            origin: serviceOrigin,
            path: "/api/pools",
            method: "POST",
            authToken: nil,
            writeToken: cleanWrite,
            body: body
        )
        guard let createdID = json["poolId"] as? String,
              let auth = json["auth"] as? String else {
            throw RoomPoolError.invalidResponse
        }
        return try RoomPoolLink(serviceOrigin: serviceOrigin, poolID: createdID, authToken: auth)
    }

    public func fetchStatus(link: RoomPoolLink) async throws -> RoomPoolStatus {
        let json = try await requestJSON(
            origin: link.serviceOrigin,
            path: "/api/pools/\(link.poolID)",
            method: "GET",
            authToken: link.authToken,
            writeToken: nil
        )
        guard let poolID = json["poolId"] as? String,
              let available = json["availableCount"] as? Int,
              let used = json["usedCount"] as? Int else {
            throw RoomPoolError.invalidResponse
        }
        let label = (json["label"] as? String) ?? ""
        let origins = (json["origins"] as? [String: Int]) ?? [:]
        return RoomPoolStatus(
            poolID: poolID,
            label: label,
            availableCount: available,
            usedCount: used,
            origins: origins
        )
    }

    public func claimRoom(
        link: RoomPoolLink,
        preferredOrigin: URL? = nil,
        requestID: String = UUID().uuidString
    ) async throws -> ClaimedPoolRoom {
        var body: [String: Any] = ["requestId": requestID]
        if let preferredOrigin, let canonical = SiteOrigin.canonicalOrigin(for: preferredOrigin) {
            body["preferredOrigin"] = canonical.absoluteString
        }
        let json = try await requestJSON(
            origin: link.serviceOrigin,
            path: "/api/pools/\(link.poolID)/claim",
            method: "POST",
            authToken: link.authToken,
            writeToken: nil,
            body: body,
            poolIDForErrors: link.poolID
        )
        guard let poolID = json["poolId"] as? String,
              let rawURL = json["roomUrl"] as? String,
              let roomURL = URL(string: rawURL),
              let originString = json["origin"] as? String,
              let originURL = URL(string: originString),
              let remaining = json["remainingCount"] as? Int else {
            throw RoomPoolError.invalidResponse
        }
        let replayed = (json["replayed"] as? Bool) ?? false
        return ClaimedPoolRoom(
            poolID: poolID,
            roomURL: roomURL,
            origin: originURL,
            remainingCount: remaining,
            replayed: replayed
        )
    }

    public func listLinks(link: RoomPoolLink, writeToken: String) async throws -> [QueuedPoolLink] {
        let cleanWrite = writeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanWrite.isEmpty else { throw RoomPoolError.writeTokenRequired }
        let json = try await requestJSON(
            origin: link.serviceOrigin,
            path: "/api/pools/\(link.poolID)/links",
            method: "GET",
            authToken: link.authToken,
            writeToken: cleanWrite,
            poolIDForErrors: link.poolID
        )
        guard let items = json["links"] as? [[String: Any]] else {
            throw RoomPoolError.invalidResponse
        }
        return items.compactMap { item in
            guard let id = item["id"] as? Int,
                  let rawURL = item["url"] as? String,
                  let url = URL(string: rawURL),
                  let rawOrigin = item["origin"] as? String,
                  let origin = URL(string: rawOrigin) else {
                return nil
            }
            let addedTS = (item["addedAt"] as? Int) ?? (item["addedAt"] as? Double).map(Int.init) ?? 0
            return QueuedPoolLink(
                id: id,
                url: url,
                origin: origin,
                addedAt: Date(timeIntervalSince1970: TimeInterval(addedTS))
            )
        }
    }

    public func addLinks(
        link: RoomPoolLink,
        urls: [URL],
        writeToken: String
    ) async throws -> AddPoolLinksResult {
        let cleanWrite = writeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanWrite.isEmpty else { throw RoomPoolError.writeTokenRequired }
        let batches: [[URL]] = urls.isEmpty
            ? [[]]
            : stride(from: 0, to: urls.count, by: 20).map { Array(urls[$0..<min($0 + 20, urls.count)]) }

        var totalAdded = 0
        var totalSkipped = 0
        var totalInvalid = 0
        var finalAvailable = 0

        for batch in batches {
            let json = try await requestJSON(
                origin: link.serviceOrigin,
                path: "/api/pools/\(link.poolID)/links",
                method: "POST",
                authToken: link.authToken,
                writeToken: cleanWrite,
                body: ["links": batch.map(\.absoluteString)],
                poolIDForErrors: link.poolID
            )
            guard let added = json["added"] as? Int,
                  let skipped = json["skippedDuplicates"] as? Int,
                  let invalid = json["invalid"] as? Int,
                  let available = json["availableCount"] as? Int else {
                throw RoomPoolError.invalidResponse
            }
            totalAdded += added
            totalSkipped += skipped
            totalInvalid += invalid
            finalAvailable = available
        }
        return AddPoolLinksResult(
            added: totalAdded,
            skippedDuplicates: totalSkipped,
            invalid: totalInvalid,
            availableCount: finalAvailable
        )
    }

    public func removeLinks(
        link: RoomPoolLink,
        ids: [Int]? = nil,
        urls: [URL]? = nil,
        clearAvailable: Bool = false,
        writeToken: String
    ) async throws -> RemovePoolLinksResult {
        let cleanWrite = writeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanWrite.isEmpty else { throw RoomPoolError.writeTokenRequired }
        var body: [String: Any] = ["clearAvailable": clearAvailable]
        if let ids { body["ids"] = ids }
        if let urls { body["links"] = urls.map(\.absoluteString) }
        let json = try await requestJSON(
            origin: link.serviceOrigin,
            path: "/api/pools/\(link.poolID)/links/remove",
            method: "POST",
            authToken: link.authToken,
            writeToken: cleanWrite,
            body: body,
            poolIDForErrors: link.poolID
        )
        guard let removed = json["removed"] as? Int,
              let available = json["availableCount"] as? Int else {
            throw RoomPoolError.invalidResponse
        }
        return RemovePoolLinksResult(removed: removed, availableCount: available)
    }

    private func actionName(forPostPath path: String) -> String? {
        if path == "/api/pools" { return "create" }
        if path.hasSuffix("/claim") { return "claim" }
        if path.hasSuffix("/links") { return "add_links" }
        if path.hasSuffix("/links/remove") { return "remove_links" }
        return nil
    }

    private func prefersGetAction(for origin: URL) -> Bool {
        fallbackLock.lock()
        defer { fallbackLock.unlock() }
        return getActionFallbackOrigins.contains(origin.absoluteString)
    }

    private func markPrefersGetAction(for origin: URL) {
        fallbackLock.lock()
        getActionFallbackOrigins.insert(origin.absoluteString)
        fallbackLock.unlock()
    }

    private func requestJSON(
        origin: URL,
        path: String,
        method: String,
        authToken: String?,
        writeToken: String?,
        body: [String: Any]? = nil,
        poolIDForErrors: String = ""
    ) async throws -> [String: Any] {
        let action = (method == "POST") ? actionName(forPostPath: path) : nil
        let session = makeSession(origin)
        defer { session.finishTasksAndInvalidate() }

        let useGetFirst = (action != nil) && prefersGetAction(for: origin)
        let firstAttempt = try await performRequest(
            session: session,
            origin: origin,
            path: path,
            method: useGetFirst ? "GET" : method,
            getAction: useGetFirst ? action : nil,
            authToken: authToken,
            writeToken: writeToken,
            body: body
        )

        let data: Data
        let response: HTTPURLResponse
        if !useGetFirst, firstAttempt.response.statusCode == 405, let action {
            markPrefersGetAction(for: origin)
            let retryAttempt = try await performRequest(
                session: session,
                origin: origin,
                path: path,
                method: "GET",
                getAction: action,
                authToken: authToken,
                writeToken: writeToken,
                body: body
            )
            data = retryAttempt.data
            response = retryAttempt.response
        } else {
            data = firstAttempt.data
            response = firstAttempt.response
        }

        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if (200..<300).contains(response.statusCode) {
            return json
        }
        let errorCode = (json["error"] as? String) ?? ""
        let message = json["message"] as? String
        switch (response.statusCode, errorCode) {
        case (401, "write_token_required"):
            throw RoomPoolError.writeTokenRequired
        case (403, "invalid_write_token"):
            throw RoomPoolError.invalidWriteToken
        case (401, _):
            throw RoomPoolError.invalidAuthToken(poolID: poolIDForErrors)
        case (409, "pool_empty"):
            throw RoomPoolError.poolEmpty(poolID: poolIDForErrors)
        case (409, "pool_full"):
            throw RoomPoolError.poolFull(limit: 500)
        case (409, "pool_exists"):
            throw RoomPoolError.poolAlreadyExists(poolID: poolIDForErrors)
        case (429, _):
            throw RoomPoolError.rateLimited
        default:
            throw RoomPoolError.serverError(response.statusCode, message)
        }
    }

    private func performRequest(
        session: URLSession,
        origin: URL,
        path: String,
        method: String,
        getAction: String?,
        authToken: String?,
        writeToken: String?,
        body: [String: Any]?
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        comps?.path = path
        comps?.fragment = nil
        if getAction != nil {
            comps?.queryItems = [URLQueryItem(name: "rid", value: UUID().uuidString)]
        } else {
            comps?.query = nil
        }
        guard let url = comps?.url else {
            throw RoomPoolError.invalidCoordinationLink
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        if let writeToken, !writeToken.isEmpty {
            request.setValue(writeToken, forHTTPHeaderField: "X-Pool-Write-Token")
        }
        if let getAction {
            request.setValue(getAction, forHTTPHeaderField: "X-Pool-Action")
            if let body {
                let encoded = try JSONSerialization.data(withJSONObject: body)
                    .base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
                request.setValue(encoded, forHTTPHeaderField: "X-Pool-Payload")
            }
        } else if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        return try await BoundedHTTP.load(request, session: session, maximumBytes: 524_288)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
