import Foundation

/// Server invitations have a formal path; engine identity still requires a
/// structured capability response. Any HTTPS origin can host this server.
public struct TrueConfTarget: Equatable, Sendable {
    public let invitationURL: URL
    public let originURL: URL
    public let roomID: String
    public static func parse(_ text: String) throws -> Self {
        let target = try JoinTarget.parse(text)
        let parts = target.invitationURL.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "c", !parts[1].isEmpty,
              parts[1] != ".", parts[1] != "..",
              parts[1].utf8.count <= 256, !parts[1].contains("/"), !parts[1].contains("%"), !parts[1].contains("#"),
              !parts[1].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw JoinDestinationError.invalidLink
        }
        return .init(invitationURL: target.invitationURL, originURL: target.originURL, roomID: parts[1])
    }
    public var descriptionURL: URL {
        var url = URLComponents(url: originURL, resolvingAgainstBaseURL: false)!
        url.path = "/api/v4/conferences/" + roomID
        url.queryItems = [.init(name: "url_type", value: "fixed")]
        return url.url!
    }
    public var invitationPassword: String? {
        guard let items = URLComponents(url: invitationURL, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        for name in ["password", "psw"] {
            if let value = items.first(where: { $0.name == name })?.value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    public func supportsBrowser(in data: Data, allowAuthenticated: Bool = false) -> Bool {
        struct Envelope: Decodable {
            struct Conference: Decodable {
                let id: String
                let web_client_url: String?
                let url: String?
                let allow_guests: Bool
            }
            let conference: Conference
        }
        guard let value = try? JSONDecoder().decode(Envelope.self, from: data),
              value.conference.id == roomID,
              value.conference.allow_guests || allowAuthenticated else { return false }

        func isSameOrigin(_ candidate: URL, expectedPath: String) -> Bool {
            candidate.scheme?.lowercased() == "https" &&
            candidate.host?.lowercased() == originURL.host?.lowercased() &&
            (candidate.port ?? 443) == (originURL.port ?? 443) &&
            candidate.user == nil &&
            candidate.password == nil &&
            candidate.path == expectedPath
        }

        if let rawBrowser = value.conference.web_client_url {
            guard let browser = URL(string: rawBrowser, relativeTo: originURL)?.absoluteURL else { return false }
            return isSameOrigin(browser, expectedPath: "/webrtc/" + roomID)
        }
        // TrueConf Server 5.5+ omits `web_client_url` on `/api/v4/conferences/<id>` when idle/stopped.
        if let rawURL = value.conference.url,
           let conferenceURL = URL(string: rawURL, relativeTo: originURL)?.absoluteURL {
            return isSameOrigin(conferenceURL, expectedPath: "/c/" + roomID)
        }
        return false
    }
}
