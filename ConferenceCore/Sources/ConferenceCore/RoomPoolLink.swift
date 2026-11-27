import Foundation

public enum RoomPoolLinkError: LocalizedError, Equatable {
    case invalidLink

    public var errorDescription: String? {
        CoreL("Enter a valid room coordination link.")
    }
}

/// Parses and formats room coordination links such as:
/// - `https://rock.glowsoft.ru/pools/363636#auth=dhdbdhBvVv75b`
/// - `https://rock.glowsoft.ru/pools/363636?auth=dhdbdhBvVv75b`
/// - `https://rock.glowsoft.ru/pools/363636&auth=dhdbdhBvVv75b`
public struct RoomPoolLink: Equatable, Hashable, Sendable {
    public static let defaultServiceOrigin = URL(string: "https://rock.glowsoft.ru")!

    public let serviceOrigin: URL
    public let poolID: String
    public let authToken: String

    public init(serviceOrigin: URL = RoomPoolLink.defaultServiceOrigin, poolID: String, authToken: String) throws {
        let normalizedOrigin = Self.normalizeServiceOrigin(serviceOrigin)
        let cleanID = poolID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanAuth = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedOrigin,
              Self.isValidPoolID(cleanID),
              Self.isValidAuthToken(cleanAuth) else {
            throw RoomPoolLinkError.invalidLink
        }
        self.serviceOrigin = normalizedOrigin
        self.poolID = cleanID
        self.authToken = cleanAuth
    }

    public var poolKey: String {
        "\(serviceOrigin.absoluteString)#\(poolID)"
    }

    public var canonicalURL: URL {
        var comps = URLComponents(url: serviceOrigin, resolvingAgainstBaseURL: false)!
        comps.path = "/pools/\(poolID)"
        comps.query = nil
        comps.fragment = "auth=\(authToken)"
        return comps.url!
    }

    public static func parse(_ text: String, joinLinkHost: String? = nil) throws -> RoomPoolLink {
        try parse(text, joinLinkHost: joinLinkHost, depth: 0)
    }

    public static func parseOptional(_ text: String, joinLinkHost: String? = nil) -> RoomPoolLink? {
        try? parse(text, joinLinkHost: joinLinkHost)
    }

    private static func parse(_ text: String, joinLinkHost: String?, depth: Int) throws -> RoomPoolLink {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.utf8.count <= 4096,
              let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased() else {
            throw RoomPoolLinkError.invalidLink
        }

        if scheme == "conferenceguest" {
            guard depth == 0,
                  components.host?.lowercased() == "join",
                  components.user == nil, components.password == nil,
                  components.queryItems?.filter({ $0.name == "url" }).count == 1,
                  let nested = components.queryItems?.first(where: { $0.name == "url" })?.value else {
                throw RoomPoolLinkError.invalidLink
            }
            return try parse(nested, joinLinkHost: joinLinkHost, depth: depth + 1)
        }

        if let joinLinkHost,
           depth <= 1,
           scheme == "https",
           components.host?.lowercased() == joinLinkHost.lowercased(),
           components.path == "/join" {
            guard components.user == nil, components.password == nil,
                  components.queryItems?.filter({ $0.name == "url" }).count == 1,
                  let nested = components.queryItems?.first(where: { $0.name == "url" })?.value else {
                throw RoomPoolLinkError.invalidLink
            }
            return try parse(nested, joinLinkHost: nil, depth: depth + 1)
        }

        guard let originURL = normalizeServiceOrigin(components: components) else {
            throw RoomPoolLinkError.invalidLink
        }

        let pathSegments = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard pathSegments.count == 2, pathSegments[0] == "pools" else {
            throw RoomPoolLinkError.invalidLink
        }

        let secondSegment = String(pathSegments[1])
        let rawPoolID: String
        var inlineAuth: String?
        if let amp = secondSegment.firstIndex(of: "&") {
            rawPoolID = String(secondSegment[..<amp])
            let suffix = String(secondSegment[secondSegment.index(after: amp)...])
            inlineAuth = parseKeyValuePairs(suffix)["auth"]
        } else {
            rawPoolID = secondSegment
        }

        let queryAuth = components.queryItems?.first(where: { $0.name == "auth" })?.value
        let fragmentAuth = components.fragment.flatMap { parseKeyValuePairs($0)["auth"] }
        let candidates = [fragmentAuth, queryAuth, inlineAuth].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        guard let authToken = candidates.first,
              candidates.allSatisfy({ $0 == authToken }) else {
            throw RoomPoolLinkError.invalidLink
        }

        return try RoomPoolLink(serviceOrigin: originURL, poolID: rawPoolID, authToken: authToken)
    }

    /// Extracts valid HTTPS guest/meeting invitation URLs from pasted multi-line text,
    /// ignoring coordination links and `rock.glowsoft.ru`.
    public static func extractCandidateInvitationURLs(from text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"https://[^\s<>"'`]+"#, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        let trailingPunctuation = CharacterSet(charactersIn: ".,;!?)]>'\"")
        var result: [URL] = []
        var seen = Set<String>()

        for match in matches {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            var raw = String(text[swiftRange])
            while let last = raw.unicodeScalars.last, trailingPunctuation.contains(last) {
                raw.removeLast()
            }
            guard !raw.isEmpty,
                  parseOptional(raw) == nil,
                  let target = try? JoinTarget.parse(raw),
                  let host = target.originURL.host?.lowercased(),
                  host != "rock.glowsoft.ru",
                  host != "localhost",
                  !host.hasSuffix(".invalid") else {
                continue
            }
            let key = target.invitationURL.absoluteString
            if seen.insert(key).inserted {
                result.append(target.invitationURL)
            }
        }
        return result
    }

    private static func normalizeServiceOrigin(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return normalizeServiceOrigin(components: components)
    }

    private static func normalizeServiceOrigin(components: URLComponents) -> URL? {
        guard let scheme = components.scheme?.lowercased(),
              let rawHost = components.host?.lowercased(), !rawHost.isEmpty,
              components.user == nil, components.password == nil else {
            return nil
        }
        let isLocalLoopback = (rawHost == "127.0.0.1" || rawHost == "localhost")
        guard scheme == "https" || (scheme == "http" && isLocalLoopback) else {
            return nil
        }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = rawHost
        if let port = components.port,
           !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            origin.port = port
        }
        return origin.url
    }

    private static func parseKeyValuePairs(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let rawKey = String(pair[..<eq])
            let rawValue = String(pair[pair.index(after: eq)...])
            let key = rawKey.removingPercentEncoding ?? rawKey
            let value = rawValue.removingPercentEncoding ?? rawValue
            if !key.isEmpty && !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    public static func isValidPoolID(_ value: String) -> Bool {
        let utf8 = Array(value.utf8)
        guard (4...24).contains(utf8.count) else { return false }
        return utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    public static func isValidAuthToken(_ value: String) -> Bool {
        let utf8 = Array(value.utf8)
        guard (4...256).contains(utf8.count) else { return false }
        return utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
