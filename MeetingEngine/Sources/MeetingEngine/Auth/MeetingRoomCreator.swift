import ConferenceCore
import Foundation

public struct RoomCreationOptions: Equatable, Sendable {
    public var title: String
    public var allowGuests: Bool
    public var enableLobby: Bool

    public init(title: String = "", allowGuests: Bool = true, enableLobby: Bool = false) {
        self.title = title
        self.allowGuests = allowGuests
        self.enableLobby = enableLobby
    }
}

public struct CreatedMeetingRoom: Equatable, Sendable {
    public let origin: URL
    public let engine: MeetingEngineKind
    public let roomID: String
    public let title: String
    public let invitationURL: URL
    public let destination: JoinDestination

    public init(
        origin: URL,
        engine: MeetingEngineKind,
        roomID: String,
        title: String,
        invitationURL: URL,
        destination: JoinDestination
    ) {
        self.origin = origin
        self.engine = engine
        self.roomID = roomID
        self.title = title
        self.invitationURL = invitationURL
        self.destination = destination
    }
}

public enum RoomCreationError: LocalizedError, Equatable {
    case invalidSiteURL
    case signInRequired(origin: URL, engine: MeetingEngineKind)
    case unsupportedEngine(MeetingEngineKind)
    case requestFailed(Int, String?)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidSiteURL:
            return L("Enter a valid HTTPS meeting website address.")
        case .signInRequired(let origin, _):
            return L("Sign in to %@ to create a new room.", origin.host ?? origin.absoluteString)
        case .unsupportedEngine:
            return L("This meeting service does not support creating rooms from the app.")
        case .requestFailed(let code, let detail):
            if let detail, !detail.isEmpty {
                return detail
            }
            return L("Could not create the room (HTTP %ld).", code)
        case .invalidResponse:
            return L("The server returned an unexpected response when creating the room.")
        }
    }
}

@MainActor
public final class MeetingRoomCreator {
    private let auth: SiteAuthCoordinator
    private let makeSession: @Sendable (URL) -> URLSession

    public init(
        auth: SiteAuthCoordinator? = nil,
        makeSession: (@Sendable (URL) -> URLSession)? = nil
    ) {
        let resolvedAuth = auth ?? .shared
        self.auth = resolvedAuth
        let registry = resolvedAuth.store.registry
        self.makeSession = makeSession ?? { origin in
            SiteTLSDelegate.makeEphemeralSession(preferredOrigin: origin, lookup: registry, timeout: 15, allowsCookies: false)
        }
    }

    public func createRoom(
        on rawOrigin: URL,
        engine explicitEngine: MeetingEngineKind? = nil,
        options: RoomCreationOptions
    ) async throws -> CreatedMeetingRoom {
        guard let origin = SiteOrigin.canonicalOrigin(for: rawOrigin) else {
            throw RoomCreationError.invalidSiteURL
        }
        let cleanTitle = options.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = cleanTitle.isEmpty ? L("New meeting") : String(cleanTitle.prefix(120))

        let resolvedEngine: MeetingEngineKind
        if let explicitEngine {
            resolvedEngine = explicitEngine
        } else if let saved = auth.store.account(for: origin)?.engine {
            resolvedEngine = saved
        } else if let host = origin.host?.lowercased(), TelemostTarget.hosts.contains(host) {
            resolvedEngine = .telemost
        } else {
            resolvedEngine = try await auth.detectEngine(for: origin).engine
        }

        switch resolvedEngine {
        case .guest:
            return try await createGuestRoom(origin: origin, title: effectiveTitle, options: options)
        case .trueconf:
            return try await createTrueConfRoom(origin: origin, title: effectiveTitle, options: options)
        case .telemost:
            return try await createTelemostRoom(origin: origin, title: effectiveTitle, options: options)
        case .community:
            throw RoomCreationError.unsupportedEngine(.community)
        }
    }

    // MARK: - Guest (SaluteJazz / SberJazz)

    private func createGuestRoom(
        origin: URL,
        title: String,
        options: RoomCreationOptions
    ) async throws -> CreatedMeetingRoom {
        let session = makeSession(origin)
        defer { session.finishTasksAndInvalidate() }
        let bootstrap = GuestBootstrap(session: session, useBoundedHTTP: true)

        var creds = await auth.validCredentials(for: origin, engine: .guest)
        var didRefresh = false

        while true {
            let headers = creds?.httpHeaders(for: origin, engine: .guest) ?? ["X-Jazz-Token": ""]
            let roomType = creds != nil ? "MEETING" : "ANONYMOUS"
            do {
                let invitation = try await bootstrap.createRoom(
                    origin: origin,
                    title: title,
                    roomType: roomType,
                    guestEnabled: options.allowGuests,
                    lobbyEnabled: options.enableLobby,
                    headers: headers
                )
                return try makeGuestCreatedRoom(origin: origin, title: title, invitation: invitation)
            } catch GuestBootstrapError.httpStatus(400) where roomType == "MEETING" {
                do {
                    let invitation = try await bootstrap.createRoom(
                        origin: origin,
                        title: title,
                        roomType: "ANONYMOUS",
                        guestEnabled: options.allowGuests,
                        lobbyEnabled: options.enableLobby,
                        headers: headers
                    )
                    return try makeGuestCreatedRoom(origin: origin, title: title, invitation: invitation)
                } catch GuestBootstrapError.httpStatus(let code) where code == 401 || code == 403 {
                    if creds != nil && !didRefresh {
                        didRefresh = true
                        creds = await auth.validCredentials(for: origin, engine: .guest, forceRefresh: true)
                        if creds != nil { continue }
                    }
                    throw RoomCreationError.signInRequired(origin: origin, engine: .guest)
                }
            } catch GuestBootstrapError.httpStatus(let code) where code == 401 || code == 403 {
                if creds != nil && !didRefresh {
                    didRefresh = true
                    creds = await auth.validCredentials(for: origin, engine: .guest, forceRefresh: true)
                    if creds != nil { continue }
                }
                throw RoomCreationError.signInRequired(origin: origin, engine: .guest)
            } catch GuestBootstrapError.httpStatus(let code) {
                throw RoomCreationError.requestFailed(code, nil)
            }
        }
    }

    private func makeGuestCreatedRoom(origin: URL, title: String, invitation: GuestInvitation) throws -> CreatedMeetingRoom {
        let target = try JoinTarget.parse(invitation.invitationURL.absoluteString)
        return CreatedMeetingRoom(
            origin: origin,
            engine: .guest,
            roomID: target.roomID,
            title: title,
            invitationURL: target.invitationURL,
            destination: .guest(target)
        )
    }

    // MARK: - TrueConf Server

    private func createTrueConfRoom(
        origin: URL,
        title: String,
        options: RoomCreationOptions
    ) async throws -> CreatedMeetingRoom {
        guard var creds = await auth.validCredentials(for: origin, engine: .trueconf) else {
            throw RoomCreationError.signInRequired(origin: origin, engine: .trueconf)
        }
        let session = makeSession(origin)
        defer { session.finishTasksAndInvalidate() }

        for attempt in 0..<2 {
            var payload: [String: Any] = [
                "topic": title,
                "type": 0,
                "auto_invite": 0,
                "max_participants": 32,
                "allow_guests": options.allowGuests,
                "schedule": ["type": -1]
            ]
            if let owner = creds.account.username?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
                payload["owner"] = owner
            }
            let bodyData = try JSONSerialization.data(withJSONObject: payload)

            var sawUnauthorized = false
            for path in ["/api/v3.8/conferences", "/api/v4/conferences"] {
                var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
                comps.path = path
                let headers = creds.httpHeaders(for: comps.url!, engine: .trueconf)

                let candidates: [(url: URL, includeBearer: Bool)] = {
                    var list: [(URL, Bool)] = [(comps.url!, true)]
                    if path == "/api/v3.8/conferences", let token = creds.accessToken, !token.isEmpty {
                        var queryComps = comps
                        queryComps.queryItems = [URLQueryItem(name: "access_token", value: token)]
                        if let qURL = queryComps.url {
                            list.append((qURL, false))
                        }
                    }
                    return list
                }()

                for candidate in candidates {
                    var req = URLRequest(url: candidate.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                    for (name, value) in headers {
                        if !candidate.includeBearer && name == "Authorization" { continue }
                        req.setValue(value, forHTTPHeaderField: name)
                    }
                    req.httpBody = bodyData

                    let (data, response) = try await BoundedHTTP.load(req, session: session, maximumBytes: 262_144)
                    if (200..<300).contains(response.statusCode) {
                        return try parseTrueConfCreatedRoom(origin: origin, title: title, data: data)
                    }
                    if response.statusCode == 401 || response.statusCode == 403 {
                        sawUnauthorized = true
                        continue
                    }
                    if response.statusCode == 404 {
                        break
                    }
                    let msg = Self.extractErrorMessage(from: data)
                    throw RoomCreationError.requestFailed(response.statusCode, msg)
                }
            }

            if sawUnauthorized && attempt == 0,
               let refreshed = await auth.validCredentials(for: origin, engine: .trueconf, forceRefresh: true) {
                creds = refreshed
                continue
            }
            if sawUnauthorized {
                throw RoomCreationError.signInRequired(origin: origin, engine: .trueconf)
            }
            throw RoomCreationError.invalidResponse
        }
        throw RoomCreationError.signInRequired(origin: origin, engine: .trueconf)
    }

    private func parseTrueConfCreatedRoom(origin: URL, title: String, data: Data) throws -> CreatedMeetingRoom {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RoomCreationError.invalidResponse
        }
        let conf = (root["conference"] as? [String: Any]) ?? root
        guard let roomID = (conf["id"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
            throw RoomCreationError.invalidResponse
        }
        let candidateURL: URL? = {
            if let raw = (conf["url"] as? String) ?? (conf["join_url"] as? String),
               let parsed = URL(string: raw),
               let target = try? TrueConfTarget.parse(parsed.absoluteString) {
                return target.invitationURL
            }
            var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
            comps.path = "/c/\(roomID)"
            return comps.url
        }()
        guard let url = candidateURL, let target = try? TrueConfTarget.parse(url.absoluteString) else {
            throw RoomCreationError.invalidResponse
        }
        let serverTitle = (conf["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CreatedMeetingRoom(
            origin: origin,
            engine: .trueconf,
            roomID: target.roomID,
            title: (serverTitle?.isEmpty == false) ? serverTitle! : title,
            invitationURL: target.invitationURL,
            destination: .trueconf(target)
        )
    }

    // MARK: - Yandex Telemost

    private func createTelemostRoom(
        origin: URL,
        title: String,
        options: RoomCreationOptions
    ) async throws -> CreatedMeetingRoom {
        let canonical = SiteOrigin.telemostCanonicalOrigin
        guard var creds = await auth.validCredentials(for: canonical, engine: .telemost) else {
            throw RoomCreationError.signInRequired(origin: canonical, engine: .telemost)
        }
        let session = makeSession(canonical)
        defer { session.finishTasksAndInvalidate() }

        for attempt in 0..<2 {
            let hasOAuthToken = creds.accessToken?.isEmpty == false
            let endpoint = hasOAuthToken
                ? URL(string: "https://cloud-api.yandex.net/v1/telemost-api/conferences")!
                : URL(string: "https://cloud-api.yandex.ru/telemost_front/v2/telemost/conferences")!

            var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            for (name, value) in creds.httpHeaders(for: endpoint, engine: .telemost) {
                req.setValue(value, forHTTPHeaderField: name)
            }

            if hasOAuthToken {
                let payload: [String: Any] = [
                    "access_level": options.allowGuests ? "PUBLIC" : "ORGANIZATION"
                ]
                req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            } else {
                req.setValue("https://telemost.yandex.ru", forHTTPHeaderField: "Origin")
                req.setValue("https://telemost.yandex.ru/", forHTTPHeaderField: "Referer")
                req.setValue("212.6.0", forHTTPHeaderField: "X-Telemost-Client-Version")
                req.setValue(UUID().uuidString, forHTTPHeaderField: "Client-Instance-Id")
                req.setValue(UUID().uuidString, forHTTPHeaderField: "idempotency-key")
                let payload: [String: Any] = [
                    "staff_only": !options.allowGuests
                ]
                req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            }

            let (data, response) = try await BoundedHTTP.load(req, session: session, maximumBytes: 262_144)
            if (200..<300).contains(response.statusCode) {
                return try parseTelemostCreatedRoom(origin: origin, title: title, data: data)
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                if attempt == 0,
                   let refreshed = await auth.validCredentials(for: canonical, engine: .telemost, forceRefresh: true) {
                    creds = refreshed
                    continue
                }
                throw RoomCreationError.signInRequired(origin: canonical, engine: .telemost)
            }
            throw RoomCreationError.requestFailed(response.statusCode, Self.extractErrorMessage(from: data))
        }
        throw RoomCreationError.signInRequired(origin: canonical, engine: .telemost)
    }

    private func parseTelemostCreatedRoom(origin: URL, title: String, data: Data) throws -> CreatedMeetingRoom {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RoomCreationError.invalidResponse
        }
        let nested = root["conference"] as? [String: Any]
        let rawURL = (root["join_url"] as? String)
            ?? (root["uri"] as? String)
            ?? (root["url"] as? String)
            ?? (nested?["join_url"] as? String)
            ?? (nested?["uri"] as? String)
        guard let rawURL, let target = try? TelemostTarget.parse(rawURL) else {
            throw RoomCreationError.invalidResponse
        }
        return CreatedMeetingRoom(
            origin: origin,
            engine: .telemost,
            roomID: target.roomID,
            title: title,
            invitationURL: target.invitationURL,
            destination: .telemost(target)
        )
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let msg = json["message"] as? String, !msg.isEmpty { return msg }
        if let desc = json["error_description"] as? String, !desc.isEmpty { return desc }
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String, !msg.isEmpty { return msg }
        return nil
    }
}
