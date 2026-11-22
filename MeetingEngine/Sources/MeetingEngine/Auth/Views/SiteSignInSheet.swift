import ConferenceCore
import Foundation
import SwiftUI
#if canImport(WebKit) && (os(iOS) || os(macOS))
import WebKit
#endif

public struct SiteSignInSheet: View {
    private enum AuthMode: String, CaseIterable, Identifiable {
        case webSSO = "SSO / Web"
        case credentials = "Password"
        case token = "Token"
        var id: String { rawValue }
    }

    private enum CertSelection: Hashable {
        case none
        case imported(UUID)
        case system(String)
    }

    public let initialOrigin: URL?
    public let suggestedOrigins: [URL]
    public let onSignedIn: (@MainActor (SiteAccountRecord) -> Void)?

    @Environment(\.dismiss) private var dismiss
    private let coordinator: SiteAuthCoordinator
    @ObservedObject private var store: SiteAccountStore

    @State private var siteInput: String
    @State private var resolvedOrigin: URL?
    @State private var selectedEngine: MeetingEngineKind = .guest
    @State private var engineAutoDetected = false
    @State private var authMode: AuthMode = .webSSO
    @State private var certSelection: CertSelection = .none
    @State private var showCertificateOptions = false

    @State private var username = ""
    @State private var password = ""
    @State private var showTrueConfOAuth = false
    @State private var oauthClientID = ""
    @State private var oauthClientSecret = ""
    @State private var manualToken = ""

    @State private var statusMessage: String?
    @State private var isError = false
    @State private var isBusy = false
    @State private var isDetecting = false

    @State private var webViewNonce = UUID()
    @State private var capturedAccessToken: String?
    @State private var capturedRefreshToken: String?
    @State private var capturedTokenEndpoint: String?
    @State private var lastAutoVerifyURL: String?
    @State private var detectTask: Task<Void, Never>?
    @FocusState private var urlFieldFocused: Bool
    @StateObject private var certImport = PKCS12ImportFlow()

    #if canImport(WebKit) && (os(iOS) || os(macOS))
    @State private var activeWebView: WKWebView?
    #endif

    public init(
        initialOrigin: URL? = nil,
        suggestedOrigins: [URL] = [],
        coordinator: SiteAuthCoordinator? = nil,
        onSignedIn: (@MainActor (SiteAccountRecord) -> Void)? = nil
    ) {
        let resolvedCoordinator = coordinator ?? .shared
        self.initialOrigin = initialOrigin
        self.suggestedOrigins = suggestedOrigins
        self.coordinator = resolvedCoordinator
        self._store = ObservedObject(wrappedValue: resolvedCoordinator.store)
        self.onSignedIn = onSignedIn

        let canonical = initialOrigin.flatMap { SiteOrigin.canonicalOrigin(for: $0) }
        _siteInput = State(initialValue: canonical?.absoluteString ?? "")
        _resolvedOrigin = State(initialValue: canonical)
    }

    private var quickOrigins: [URL] {
        var list: [URL] = []
        var seen = Set<String>()
        let defaults = store.accounts.compactMap(\.originURL) + suggestedOrigins
        for url in defaults {
            guard let canonical = SiteOrigin.canonicalOrigin(for: url) else { continue }
            if seen.insert(canonical.absoluteString).inserted {
                list.append(canonical)
            }
        }
        return Array(list.prefix(8))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerControls
                Divider()
                if authMode == .webSSO {
                    webSSOContent
                } else {
                    formAuthContent
                }
            }
            .navigationTitle(resolvedOrigin?.host ?? L("Sign in to website"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 740, minHeight: 600)
        #endif
        .fileImporter(
            isPresented: $certImport.showingFileImporter,
            allowedContentTypes: PKCS12ImportFlow.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            certImport.handleFileResult(result, store: store) { record in
                applyImportedCertificate(record)
            }
        }
        .onAppear {
            loadInitialAccountState()
        }
        .onDisappear {
            detectTask?.cancel()
            detectTask = nil
        }
        .onChange(of: certSelection) { newSelection in
            if applyCertificateSelectionToSite(newSelection) {
                webViewNonce = UUID()
            }
        }
    }

    private var headerControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("https://meetings.example.com", text: $siteInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($urlFieldFocused)
                    .accessibilityIdentifier("siteAuth.url")
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
                    .onSubmit { commitSiteInput() }

                Button(isDetecting ? L("Checking…") : L("Open")) {
                    commitSiteInput()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDetecting || SiteOrigin.normalize(siteInput) == nil)
            }

            if !quickOrigins.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickOrigins, id: \.absoluteString) { origin in
                            Button {
                                urlFieldFocused = false
                                siteInput = origin.absoluteString
                                commitSiteInput()
                            } label: {
                                Text(origin.host ?? origin.absoluteString)
                                    .font(.caption.weight(.medium))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(resolvedOrigin == origin ? .accentColor : .secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack(spacing: 10) {
                Picker(L("Service"), selection: $selectedEngine) {
                    Text(SiteAuthEngineLabel.title(for: .guest)).tag(MeetingEngineKind.guest)
                    Text(SiteAuthEngineLabel.title(for: .trueconf)).tag(MeetingEngineKind.trueconf)
                    Text(SiteAuthEngineLabel.title(for: .telemost)).tag(MeetingEngineKind.telemost)
                }
                .labelsHidden()
                .frame(maxWidth: 210)

                Picker(L("Method"), selection: $authMode) {
                    ForEach(AuthMode.allCases) { mode in
                        if !(selectedEngine == .telemost && mode == .credentials) {
                            Text(L(mode.rawValue)).tag(mode)
                        }
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    withAnimation { showCertificateOptions.toggle() }
                } label: {
                    Label(certificateButtonLabel, systemImage: certSelection == .none ? "lock.doc" : "checkmark.seal.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(certSelection == .none ? .secondary : .accentColor)
                .accessibilityIdentifier("siteAuth.mtlsToggle")
            }

            if showCertificateOptions || certImport.isAwaitingPassphrase {
                certificateSection
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25))
    }

    private var certificateButtonLabel: String {
        switch certSelection {
        case .none: return L("mTLS")
        case .imported(let id):
            return store.certificate(for: id)?.label ?? L("mTLS")
        case .system(let fp):
            #if os(macOS)
            return store.systemCertificate(fingerprint: fp)?.label ?? L("mTLS")
            #else
            _ = fp
            return L("mTLS")
            #endif
        }
    }

    private var certificateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker(L("Client certificate"), selection: $certSelection) {
                    Text(L("None")).tag(CertSelection.none)
                    ForEach(store.certificates) { cert in
                        Text(cert.isExpired ? L("%@ (Expired)", cert.label) : cert.label)
                            .tag(CertSelection.imported(cert.id))
                    }
                    #if os(macOS)
                    if !store.systemCertificates.isEmpty {
                        Divider()
                        ForEach(store.systemCertificates) { cert in
                            Text(L("%@ (Keychain)", cert.label))
                                .tag(CertSelection.system(cert.sha256Fingerprint))
                        }
                    }
                    #endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(L("Import .p12 / .pfx…")) {
                    certImport.showingFileImporter = true
                }
                .accessibilityIdentifier("siteAuth.importCert")
            }

            if let error = certImport.errorMessage, !certImport.isAwaitingPassphrase {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if certImport.isAwaitingPassphrase {
                PKCS12PassphraseInlineCard(flow: certImport, store: store) { record in
                    applyImportedCertificate(record)
                }
            }

            if certSelection != .none, let origin = resolvedOrigin {
                HStack {
                    Text(L("This certificate is saved for %@ and its subdomains.", origin.host ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Use Certificate Only")) {
                        Task { await saveMTLSOnly(origin: origin) }
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(isBusy)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var webSSOContent: some View {
        #if canImport(WebKit) && (os(iOS) || os(macOS))
        if let origin = resolvedOrigin {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if isBusy { ProgressView().controlSize(.small) }
                    Text(L("Sign in below. Your session and tokens will be saved automatically."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        webViewNonce = UUID()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(L("Reload"))
                    Button(L("Verify Session")) {
                        Task { await verifyWebSession(origin: origin, interactive: true) }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                    .accessibilityIdentifier("siteAuth.verifyWeb")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.35))

                Divider()

                SiteAuthWebViewContainer(
                    startURL: origin,
                    origin: origin,
                    nonce: webViewNonce,
                    lookup: store.registry,
                    onWebViewReady: { activeWebView = $0 },
                    onCapturedToken: { token, refresh, endpoint in
                        capturedAccessToken = token
                        if !refresh.isEmpty { capturedRefreshToken = refresh }
                        if !endpoint.isEmpty { capturedTokenEndpoint = endpoint }
                        Task { await verifyWebSession(origin: origin, interactive: false) }
                    },
                    onNavigationFinished: { url, webView in
                        activeWebView = webView
                        guard let url,
                              let targetHost = origin.host,
                              let currentHost = url.host,
                              SiteOrigin.hostMatches(currentHost, siteHost: targetHost) else {
                            return
                        }
                        let lowerPath = url.path.lowercased()
                        let looksLikeLoginPage = lowerPath.contains("login") || lowerPath.contains("signin") || lowerPath.contains("sso")
                        if !looksLikeLoginPage && lastAutoVerifyURL != url.absoluteString {
                            lastAutoVerifyURL = url.absoluteString
                            await verifyWebSession(origin: origin, interactive: false)
                        }
                    },
                    onNavigationFailed: { error in
                        if let certOrigin = SiteAuthError.challengeOrigin(from: error, attemptedURL: origin, store: store) {
                            _ = certOrigin
                            let challenge = store.wasChallengedForClientCertificate(host: origin.host ?? "")
                            if challenge.challenged {
                                showCertificateOptions = true
                                isError = true
                                statusMessage = challenge.rejected
                                    ? SiteAuthError.clientCertificateRejected(host: origin.host ?? "").localizedDescription
                                    : SiteAuthError.clientCertificateRequired(host: origin.host ?? "").localizedDescription
                                return
                            }
                        }
                        isError = true
                        statusMessage = error.localizedDescription
                    }
                )
                .id("\(origin.absoluteString)-\(webViewNonce.uuidString)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            emptyOriginPrompt
        }
        #else
        emptyOriginPrompt
        #endif
    }

    private var formAuthContent: some View {
        Form {
            if let origin = resolvedOrigin {
                if authMode == .credentials {
                    Section {
                        TextField(L("Username or email"), text: $username)
                            .accessibilityIdentifier("siteAuth.username")
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                        SecureField(L("Password"), text: $password)
                            .accessibilityIdentifier("siteAuth.password")
                            .onSubmit {
                                Task { await signInWithPassword(origin: origin) }
                            }
                        if selectedEngine == .trueconf {
                            DisclosureGroup(L("OAuth2 app credentials (optional)"), isExpanded: $showTrueConfOAuth) {
                                TextField(L("Client ID"), text: $oauthClientID)
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    #endif
                                SecureField(L("Client Secret"), text: $oauthClientSecret)
                            }
                        }
                        Button {
                            Task { await signInWithPassword(origin: origin) }
                        } label: {
                            HStack {
                                if isBusy { ProgressView().controlSize(.small) }
                                Text(L("Sign In & Save"))
                            }
                        }
                        .disabled(isBusy || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                        .accessibilityIdentifier("siteAuth.submitCredentials")
                    } header: {
                        Text(L("Account credentials"))
                    } footer: {
                        Text(L("Saved in the device Keychain for automatic relogin and token renewal."))
                    }
                } else {
                    Section(L("Access token")) {
                        SecureField(L("Bearer, X-Jazz-Token, or OAuth token"), text: $manualToken)
                            .accessibilityIdentifier("siteAuth.token")
                            .onSubmit {
                                Task { await signInWithToken(origin: origin) }
                            }
                        Button {
                            Task { await signInWithToken(origin: origin) }
                        } label: {
                            HStack {
                                if isBusy { ProgressView().controlSize(.small) }
                                Text(L("Verify & Save Token"))
                            }
                        }
                        .disabled(isBusy || manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("siteAuth.submitToken")
                    }
                }
            } else {
                Section {
                    Text(L("Enter a website address above to sign in."))
                        .foregroundStyle(.secondary)
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    private var emptyOriginPrompt: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "globe")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(L("Enter a meeting website address above to begin signing in."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func loadInitialAccountState() {
        guard let origin = resolvedOrigin else { return }
        if let existing = store.account(for: origin) {
            selectedEngine = existing.engine
            username = existing.username ?? ""
            if let certID = existing.clientCertificateID, store.certificate(for: certID) != nil {
                certSelection = .imported(certID)
                showCertificateOptions = true
            } else if let fp = existing.systemCertificateFingerprint, !fp.isEmpty {
                #if os(macOS)
                certSelection = store.systemCertificate(fingerprint: fp) != nil ? .system(fp) : .none
                showCertificateOptions = certSelection != .none
                #else
                certSelection = .none
                #endif
            } else {
                certSelection = .none
            }
            if existing.engine == .telemost && authMode == .credentials {
                authMode = .webSSO
            }
        } else {
            detectTask?.cancel()
            detectTask = Task { await detectEngine(for: origin) }
        }
    }

    private func commitSiteInput() {
        urlFieldFocused = false
        guard let normalized = SiteOrigin.normalize(siteInput) else {
            isError = true
            statusMessage = SiteAuthError.invalidSiteURL.localizedDescription
            return
        }
        siteInput = normalized.absoluteString
        resolvedOrigin = normalized
        capturedAccessToken = nil
        capturedRefreshToken = nil
        capturedTokenEndpoint = nil
        lastAutoVerifyURL = nil
        isError = false
        statusMessage = nil

        if let existing = store.account(for: normalized) {
            selectedEngine = existing.engine
            username = existing.username ?? ""
            if let id = existing.clientCertificateID, store.certificate(for: id) != nil {
                certSelection = .imported(id)
                showCertificateOptions = true
            } else if let fp = existing.systemCertificateFingerprint, !fp.isEmpty {
                #if os(macOS)
                certSelection = store.systemCertificate(fingerprint: fp) != nil ? .system(fp) : .none
                showCertificateOptions = certSelection != .none
                #else
                certSelection = .none
                #endif
            } else {
                certSelection = .none
            }
        } else {
            certSelection = .none
        }
        webViewNonce = UUID()
        detectTask?.cancel()
        detectTask = Task { await detectEngine(for: normalized) }
    }

    private func detectEngine(for origin: URL) async {
        isDetecting = true
        defer {
            if !Task.isCancelled { isDetecting = false }
        }
        do {
            let detected = try await coordinator.detectEngine(for: origin)
            guard !Task.isCancelled else { return }
            selectedEngine = detected.engine
            engineAutoDetected = true
            if detected.engine == .telemost && authMode == .credentials {
                authMode = .webSSO
            }
            if isError {
                isError = false
                statusMessage = nil
            }
        } catch SiteAuthError.clientCertificateRequired(let host) {
            guard !Task.isCancelled else { return }
            showCertificateOptions = true
            isError = true
            statusMessage = SiteAuthError.clientCertificateRequired(host: host).localizedDescription
        } catch SiteAuthError.clientCertificateRejected(let host) {
            guard !Task.isCancelled else { return }
            showCertificateOptions = true
            isError = true
            statusMessage = SiteAuthError.clientCertificateRejected(host: host).localizedDescription
        } catch {
            guard !Task.isCancelled else { return }
            // Keep manual engine picker selectable if discovery endpoint is behind SSO/WAF.
            engineAutoDetected = false
        }
    }

    private func applyImportedCertificate(_ record: ClientCertificateRecord) {
        certSelection = .imported(record.id)
        showCertificateOptions = true
        isError = false
        statusMessage = L("Imported certificate %@.", record.label)
        _ = applyCertificateSelectionToSite(.imported(record.id))
        webViewNonce = UUID()
    }

    @discardableResult
    private func applyCertificateSelectionToSite(_ selection: CertSelection) -> Bool {
        guard let origin = resolvedOrigin else { return false }
        let existing = store.account(for: origin)
        switch selection {
        case .none:
            guard let existing, existing.hasClientCertificate else { return false }
            store.clearClientCertificate(forOriginKey: existing.originKey)
            return true
        case .imported(let id):
            if existing?.clientCertificateID == id && existing?.systemCertificateFingerprint == nil {
                return false
            }
            store.setClientCertificate(importedID: id, systemFingerprint: nil, forOrigin: origin, defaultEngine: selectedEngine)
            return true
        case .system(let fp):
            if existing?.clientCertificateID == nil && existing?.systemCertificateFingerprint == fp {
                return false
            }
            store.setClientCertificate(importedID: nil, systemFingerprint: fp, forOrigin: origin, defaultEngine: selectedEngine)
            return true
        }
    }

    private func signInWithPassword(origin: URL) async {
        isBusy = true
        isError = false
        statusMessage = L("Signing in…")
        defer { isBusy = false }
        do {
            let account = try await coordinator.signInWithCredentials(
                origin: origin,
                engine: selectedEngine,
                username: username,
                password: password,
                oauthClientID: oauthClientID.isEmpty ? nil : oauthClientID,
                oauthClientSecret: oauthClientSecret.isEmpty ? nil : oauthClientSecret
            )
            onSignedIn?(account)
            dismiss()
        } catch {
            if let challenge = SiteAuthError.challengeOrigin(from: error, attemptedURL: origin, store: store) {
                _ = challenge
                if store.wasChallengedForClientCertificate(host: origin.host ?? "").challenged {
                    showCertificateOptions = true
                }
            }
            isError = true
            statusMessage = error.localizedDescription
        }
    }

    private func signInWithToken(origin: URL) async {
        isBusy = true
        isError = false
        statusMessage = L("Verifying token…")
        defer { isBusy = false }
        do {
            let account = try await coordinator.signInWithToken(origin: origin, engine: selectedEngine, token: manualToken)
            onSignedIn?(account)
            dismiss()
        } catch {
            isError = true
            statusMessage = error.localizedDescription
        }
    }

    private func saveMTLSOnly(origin: URL) async {
        isBusy = true
        isError = false
        statusMessage = L("Verifying client certificate…")
        defer { isBusy = false }
        do {
            let account = try await coordinator.saveMTLSOnlySite(origin: origin, engine: selectedEngine)
            onSignedIn?(account)
            dismiss()
        } catch {
            isError = true
            statusMessage = error.localizedDescription
        }
    }

    #if canImport(WebKit) && (os(iOS) || os(macOS))
    private func verifyWebSession(origin: URL, interactive: Bool) async {
        guard !isBusy, let webView = activeWebView else { return }
        isBusy = true
        defer { isBusy = false }

        let cookies = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { list in
                continuation.resume(returning: list)
            }
        }
        let hasToken = capturedAccessToken?.isEmpty == false
        if !interactive && !hasToken && cookies.isEmpty {
            return
        }
        do {
            let account = try await coordinator.completeWebSignIn(
                origin: origin,
                engine: selectedEngine,
                capturedAccessToken: capturedAccessToken,
                capturedRefreshToken: capturedRefreshToken,
                tokenEndpoint: capturedTokenEndpoint,
                cookies: cookies,
                requireVerifiedProof: !interactive
            )
            onSignedIn?(account)
            dismiss()
        } catch {
            if interactive {
                isError = true
                statusMessage = error.localizedDescription
            }
        }
    }
    #endif
}

#if canImport(WebKit) && (os(iOS) || os(macOS))
private final class SiteAuthWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var lastNonce: UUID?
    let tlsDelegate: SiteTLSDelegate
    let onCapturedToken: @MainActor (String, String, String) -> Void
    let onNavigationFinished: @MainActor (URL?, WKWebView) async -> Void
    let onNavigationFailed: @MainActor (Error) -> Void

    init(
        origin: URL,
        lookup: any SiteClientIdentityLookup,
        onCapturedToken: @escaping @MainActor (String, String, String) -> Void,
        onNavigationFinished: @escaping @MainActor (URL?, WKWebView) async -> Void,
        onNavigationFailed: @escaping @MainActor (Error) -> Void
    ) {
        self.tlsDelegate = SiteTLSDelegate(preferredOrigin: origin, lookup: lookup)
        self.onCapturedToken = onCapturedToken
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let token = body["token"] as? String, !token.isEmpty else { return }
        let refresh = body["refreshToken"] as? String ?? ""
        let endpoint = body["tokenEndpoint"] as? String ?? ""
        Task { @MainActor [onCapturedToken] in
            onCapturedToken(token, refresh, endpoint)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url
        Task { @MainActor [onNavigationFinished] in
            await onNavigationFinished(url, webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportFailureIfNeeded(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportFailureIfNeeded(error)
    }

    private func reportFailureIfNeeded(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        Task { @MainActor [onNavigationFailed] in
            onNavigationFailed(error)
        }
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        tlsDelegate.handleChallenge(challenge, completionHandler: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame?.isMainFrame != true {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

private func makeSiteAuthWebView(
    startURL: URL,
    coordinator: SiteAuthWebCoordinator
) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let script = WKUserScript(source: SiteAuthWebScript.captureSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    config.userContentController.addUserScript(script)
    config.userContentController.add(coordinator, name: "siteAuthBridge")
    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = coordinator
    webView.uiDelegate = coordinator
    webView.load(URLRequest(url: startURL))
    return webView
}

#if os(iOS)
private struct SiteAuthWebViewContainer: UIViewRepresentable {
    let startURL: URL
    let origin: URL
    let nonce: UUID
    let lookup: any SiteClientIdentityLookup
    let onWebViewReady: @MainActor (WKWebView) -> Void
    let onCapturedToken: @MainActor (String, String, String) -> Void
    let onNavigationFinished: @MainActor (URL?, WKWebView) async -> Void
    let onNavigationFailed: @MainActor (Error) -> Void

    func makeCoordinator() -> SiteAuthWebCoordinator {
        SiteAuthWebCoordinator(
            origin: origin,
            lookup: lookup,
            onCapturedToken: onCapturedToken,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.lastNonce = nonce
        let webView = makeSiteAuthWebView(startURL: startURL, coordinator: context.coordinator)
        Task { @MainActor in onWebViewReady(webView) }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastNonce != nonce {
            context.coordinator.lastNonce = nonce
            webView.load(URLRequest(url: startURL))
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: SiteAuthWebCoordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "siteAuthBridge")
    }
}
#else
private struct SiteAuthWebViewContainer: NSViewRepresentable {
    let startURL: URL
    let origin: URL
    let nonce: UUID
    let lookup: any SiteClientIdentityLookup
    let onWebViewReady: @MainActor (WKWebView) -> Void
    let onCapturedToken: @MainActor (String, String, String) -> Void
    let onNavigationFinished: @MainActor (URL?, WKWebView) async -> Void
    let onNavigationFailed: @MainActor (Error) -> Void

    func makeCoordinator() -> SiteAuthWebCoordinator {
        SiteAuthWebCoordinator(
            origin: origin,
            lookup: lookup,
            onCapturedToken: onCapturedToken,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.lastNonce = nonce
        let webView = makeSiteAuthWebView(startURL: startURL, coordinator: context.coordinator)
        Task { @MainActor in onWebViewReady(webView) }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastNonce != nonce {
            context.coordinator.lastNonce = nonce
            webView.load(URLRequest(url: startURL))
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: SiteAuthWebCoordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "siteAuthBridge")
    }
}
#endif
#endif
