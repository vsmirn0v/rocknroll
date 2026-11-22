import ConferenceCore
import Foundation
import Security

public protocol SiteClientIdentityLookup: Sendable {
    func clientIdentity(
        for host: String,
        port: Int?,
        distinguishedNames: [Data]?,
        preferredOrigin: URL?
    ) -> UnlockedClientIdentity?

    func noteClientCertificateChallenge(host: String, port: Int?, rejected: Bool)
    func clearClientCertificateChallenge(host: String)
}

public extension SiteClientIdentityLookup {
    func clearClientCertificateChallenge(host: String) {}
}

/// Unified TLS delegate handling both the bundled AdditionalRootCA server trust
/// and per-site / subdomain mTLS client certificate (`SecIdentity`) challenges.
public final class SiteTLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    public static let shared = SiteTLSDelegate(preferredOrigin: nil, lookup: SiteClientIdentityRegistry.shared)

    private static let fallbackTrustSession = URLSession(configuration: .ephemeral)
    private let serverTrust = AdditionalRootTrust()
    private let preferredOrigin: URL?
    private let lookup: any SiteClientIdentityLookup

    public init(preferredOrigin: URL? = nil, lookup: any SiteClientIdentityLookup = SiteClientIdentityRegistry.shared) {
        self.preferredOrigin = preferredOrigin.flatMap { SiteOrigin.canonicalOrigin(for: $0) } ?? preferredOrigin
        self.lookup = lookup
        super.init()
    }

    public static func makeEphemeralSession(
        preferredOrigin: URL? = nil,
        lookup: (any SiteClientIdentityLookup)? = nil,
        timeout: TimeInterval = 20,
        allowsCookies: Bool = false
    ) -> URLSession {
        let resolvedLookup = lookup ?? SiteClientIdentityRegistry.shared
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = allowsCookies
        if !allowsCookies {
            config.httpCookieStorage = nil
        }
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout, 30)
        let delegate = preferredOrigin == nil && (resolvedLookup as AnyObject) === SiteClientIdentityRegistry.shared
            ? shared
            : SiteTLSDelegate(preferredOrigin: preferredOrigin, lookup: resolvedLookup)
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    public func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        session: URLSession? = nil,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust {
            serverTrust.urlSession(session ?? Self.fallbackTrustSession, didReceive: challenge, completionHandler: completionHandler)
            return
        }
        guard method == NSURLAuthenticationMethodClientCertificate else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port > 0 ? challenge.protectionSpace.port : nil
        if challenge.previousFailureCount > 0 {
            lookup.noteClientCertificateChallenge(host: host, port: port, rejected: true)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if let unlocked = lookup.clientIdentity(
            for: host,
            port: port,
            distinguishedNames: challenge.protectionSpace.distinguishedNames,
            preferredOrigin: preferredOrigin
        ) {
            lookup.clearClientCertificateChallenge(host: host)
            let credential = URLCredential(
                identity: unlocked.identity,
                certificates: unlocked.certificateChain,
                persistence: .forSession
            )
            completionHandler(.useCredential, credential)
            return
        }
        lookup.noteClientCertificateChallenge(host: host, port: port, rejected: false)
        completionHandler(.performDefaultHandling, nil)
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, session: session, completionHandler: completionHandler)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, session: session, completionHandler: completionHandler)
    }
}
