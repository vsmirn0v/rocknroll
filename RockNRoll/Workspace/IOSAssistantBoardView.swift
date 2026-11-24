import ConferenceCore
import CoreMedia
import CoreVideo
import MeetingEngine
import SwiftUI
import UIKit
import WebKit

@MainActor
protocol IOSBoardShareSession: AnyObject {
    var id: UUID { get }
    var title: String { get }
    var canShareBoard: Bool { get }
    var isBoardShareSessionAlive: Bool { get }
    var isSharingScreen: Bool { get }
    var onExternalBoardShareStopped: (() -> Void)? { get set }
    var onBoardShareInterrupted: (() -> Void)? { get set }
    func startBoardSharing(initialSample: CMSampleBuffer) async throws
    func pushBoardShareFrame(_ sample: CMSampleBuffer)
    func stopBoardSharing() async
}

extension IOSBoardShareSession {
    var isBoardShareSessionAlive: Bool { canShareBoard }
    var onBoardShareInterrupted: (() -> Void)? {
        get { nil }
        set {}
    }
}

private final class IOSBoardDirtyScriptHandlerProxy: NSObject, WKScriptMessageHandler {
    weak var owner: IOSAssistantBoardController?
    init(owner: IOSAssistantBoardController) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor [weak owner] in
            owner?.markBoardDirty()
        }
    }
}

/// Sandbox-safe in-app WebView controller for inspecting, filtering, clicking,
/// and streaming desktop-sized Jira or project boards directly into an active iOS meeting.
@MainActor
final class IOSAssistantBoardController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, JiraBoardWebEvaluating {
    static let desktopViewportSize = CGSize(width: 1280, height: 720)
    static let sharedOutputSize = CGSize(width: 1920, height: 1080)
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let dirtyObserverScript = """
    (function(){
      if (window.__rnrDirtyInstalled) return;
      window.__rnrDirtyInstalled = true;
      var scheduled = false;
      function notify() {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(function(){
          scheduled = false;
          try { window.webkit.messageHandlers.boardDirty.postMessage(1); } catch (_) {}
        });
      }
      window.addEventListener('scroll', notify, { passive: true, capture: true });
      window.addEventListener('input', notify, { passive: true, capture: true });
      window.addEventListener('resize', notify, { passive: true });
      window.addEventListener('transitionend', notify, { passive: true, capture: true });
      var mo = new MutationObserver(notify);
      if (document.documentElement) {
        mo.observe(document.documentElement, { childList: true, subtree: true, attributes: true, characterData: true });
      } else {
        document.addEventListener('DOMContentLoaded', function(){
          if (document.documentElement) mo.observe(document.documentElement, { childList: true, subtree: true, attributes: true, characterData: true });
        }, { once: true });
      }
    })();
    """

    private static let shareRenderQueue = DispatchQueue(label: "RockNRoll.ios-board-share-render", qos: .userInitiated)

    private final class PixelPoolState {
        var pool: CVPixelBufferPool?
        var width = 0
        var height = 0
    }

    private nonisolated(unsafe) static let poolState = PixelPoolState()

    @Published var urlDraft: String = ""
    @Published private(set) var currentURL: URL?
    @Published private(set) var pageTitle: String = L("Assistant Board")
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var loadError: String?
    @Published private(set) var lastActionSummary: String?
    @Published private(set) var sharingSessionID: UUID?
    @Published private(set) var sharingMeetingTitle: String?
    @Published private(set) var isStartingShare = false
    @Published private(set) var isRecoveringShare = false
    @Published var presentationModeEnabled = true
    @Published var isPresented = false
    var isInlineSheetActive = false

    var isSharing: Bool { sharingSessionID != nil }
    var canShareToActiveMeeting: Bool { resolveShareTarget?(nil)?.canShareBoard == true }
    var resolveShareTarget: ((UUID?) -> (any IOSBoardShareSession)?)?
    var defaultBoardURLProvider: (() -> String)?
    var defaultBoardURLForTarget: ((UUID?) -> String)?
    var snapshotOverrideForTesting: (() async -> CGImage?)?
    weak var taskSync: WorkspaceTaskSyncController?
    var onBoardURLChanged: ((String) -> Void)?

    private(set) lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        let userController = WKUserContentController()
        userController.addUserScript(
            WKUserScript(source: Self.dirtyObserverScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        userController.add(IOSBoardDirtyScriptHandlerProxy(owner: self), name: "boardDirty")
        config.userContentController = userController
        let view = WKWebView(frame: CGRect(origin: .zero, size: Self.desktopViewportSize), configuration: config)
        view.customUserAgent = Self.desktopUserAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isOpaque = true
        view.backgroundColor = .white
        return view
    }()

    private var navigationContinuation: CheckedContinuation<Void, Never>?
    private weak var activeSheetCanvas: UIView?
    private var parkingHostView: UIView?
    private weak var sharedTarget: (any IOSBoardShareSession)?
    private var frameTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var desiredShareTargetID: UUID?
    private var desiredShareURL: String?
    private var shareAttemptGeneration: UInt64 = 0
    private var lastDirtyUptime: TimeInterval = 0
    private var dirtyGeneration: UInt64 = 0
    private var lastCapturedGeneration: UInt64 = 0

    deinit {
        frameTask?.cancel()
        recoveryTask?.cancel()
    }

    func markBoardDirty() {
        lastDirtyUptime = ProcessInfo.processInfo.systemUptime
        dirtyGeneration &+= 1
    }

    func attachToSheetCanvas(_ canvas: UIView) {
        activeSheetCanvas = canvas
        parkingHostView?.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = []
        webView.frame = CGRect(origin: .zero, size: Self.desktopViewportSize)
        if webView.superview !== canvas {
            canvas.addSubview(webView)
        }
        canvas.layoutIfNeeded()
        markBoardDirty()
    }

    func detachFromSheetCanvas(_ canvas: UIView) {
        guard activeSheetCanvas === canvas else { return }
        activeSheetCanvas = nil
        if webView.superview === canvas {
            webView.removeFromSuperview()
        }
        ensureWebViewHostedForRendering()
    }

    func ensureWebViewHostedForRendering(force: Bool = false) {
        if let canvas = activeSheetCanvas {
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = []
            webView.frame = CGRect(origin: .zero, size: Self.desktopViewportSize)
            if webView.superview !== canvas {
                canvas.addSubview(webView)
            }
            parkingHostView?.removeFromSuperview()
            return
        }

        let shouldPark = force || isSharing || isLoading || isStartingShare
        guard shouldPark else {
            if let parkingHostView, webView.superview === parkingHostView {
                webView.removeFromSuperview()
            }
            parkingHostView?.removeFromSuperview()
            return
        }

        let host: UIView
        if let existing = parkingHostView {
            host = existing
        } else {
            let created = UIView(frame: CGRect(origin: .zero, size: Self.desktopViewportSize))
            created.isUserInteractionEnabled = false
            created.accessibilityElementsHidden = true
            created.alpha = 0.01
            parkingHostView = created
            host = created
        }

        host.transform = .identity
        host.bounds = CGRect(origin: .zero, size: Self.desktopViewportSize)
        host.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
        host.center = CGPoint(x: 80, y: 50)

        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = []
        webView.frame = CGRect(origin: .zero, size: Self.desktopViewportSize)
        if webView.superview !== host {
            host.addSubview(webView)
        }
        if let window = Self.activeApplicationWindow(), host.superview !== window {
            window.insertSubview(host, at: 0)
        }
        host.layoutIfNeeded()
    }

    @discardableResult
    func open(urlString: String, presentSheet: Bool = true) async throws -> String {
        guard let url = RealtimeVoiceAudio.validateBoardURL(urlString) else {
            throw MeetingSessionError.unavailable(L("Enter an https:// or localhost URL for the Assistant Board."))
        }
        finishPendingNavigation()
        loadError = nil
        currentURL = url
        urlDraft = url.absoluteString
        if presentSheet {
            isPresented = true
        }
        isLoading = true
        ensureWebViewHostedForRendering(force: true)
        markBoardDirty()
        AppDiagnostics.log("board-open-start", [
            "presentSheet": presentSheet,
            "isLocal": ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        ])
        webView.load(URLRequest(url: url))
        await waitForLoadFinish(timeoutSeconds: 8)
        ensureWebViewHostedForRendering()
        AppDiagnostics.log("board-open-finish", [
            "hasError": loadError != nil,
            "viewportW": Int(webView.bounds.width),
            "viewportH": Int(webView.bounds.height)
        ])
        if let loadError {
            lastActionSummary = loadError
            throw MeetingSessionError.unavailable(loadError)
        }
        let title = (webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? url.host
            ?? url.absoluteString
        pageTitle = title
        onBoardURLChanged?(url.absoluteString)
        if isLoading {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.taskSync?.adoptJiraSessionFromBoardIfAvailable(self)
            }
        } else {
            await taskSync?.adoptJiraSessionFromBoardIfAvailable(self)
        }
        lastActionSummary = L("Opened %@", title)
        return L("Opened %@ (%@).", title, url.absoluteString)
    }

    @discardableResult
    func startSharing(targetID: UUID? = nil, urlOverride: String? = nil) async throws -> String {
        guard let target = resolveShareTarget?(targetID) else {
            AppDiagnostics.log("board-share-error", [
                "stage": "resolveTarget",
                "errorType": "unavailable",
                "errorDomain": "RockNRoll.Board",
                "errorCode": 1,
                "cancelled": false
            ])
            throw MeetingSessionError.unavailable(L("Connect to a meeting before sharing the Assistant Board."))
        }
        let explicitURL = urlOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedSeedURL: String = {
            if !explicitURL.isEmpty { return explicitURL }
            if let existing = currentURL?.absoluteString, !existing.isEmpty { return existing }
            let draftSeed = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !draftSeed.isEmpty { return draftSeed }
            let scoped = defaultBoardURLForTarget?(target.id).trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !scoped.isEmpty { return scoped }
            return defaultBoardURLProvider?().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }()

        if !target.canShareBoard {
            if target.isBoardShareSessionAlive, !resolvedSeedURL.isEmpty {
                desiredShareTargetID = target.id
                desiredShareURL = resolvedSeedURL
                scheduleShareRecovery(targetID: target.id, reason: "waitingForReconnect")
                lastActionSummary = L("Connection interrupted — waiting to share board to %@", target.title)
                return L("Waiting for connection recovery to share desktop board to “%@”.", target.title)
            }
            AppDiagnostics.log("board-share-error", [
                "stage": "resolveTarget",
                "errorType": "unavailable",
                "errorDomain": "RockNRoll.Board",
                "errorCode": 1,
                "cancelled": false
            ])
            throw MeetingSessionError.unavailable(L("Connect to a meeting before sharing the Assistant Board."))
        }

        if isSharing, sharingSessionID == target.id {
            if !explicitURL.isEmpty, explicitURL != currentURL?.absoluteString {
                _ = try await open(urlString: explicitURL, presentSheet: isPresented)
            }
            return L("Sharing Assistant Board as Desktop (16:9) to “%@”.", target.title)
        }
        guard !isStartingShare else {
            throw MeetingSessionError.unavailable(L("Starting Assistant Board share…"))
        }

        recoveryTask?.cancel()
        recoveryTask = nil
        isRecoveringShare = false
        desiredShareTargetID = target.id
        desiredShareURL = resolvedSeedURL.isEmpty ? nil : resolvedSeedURL

        AppDiagnostics.log("board-share-begin", [
            "hasCurrentURL": currentURL != nil,
            "sheetOpen": isPresented
        ])

        isStartingShare = true
        ensureWebViewHostedForRendering(force: true)
        defer {
            isStartingShare = false
            ensureWebViewHostedForRendering()
        }

        if isSharing {
            let previous = sharedTarget
            teardownActiveShare(clearDesiredIntent: false, notifyTarget: false)
            if let previous {
                await previous.stopBoardSharing()
            }
        }

        shareAttemptGeneration &+= 1
        let attempt = shareAttemptGeneration

        do {
            if !explicitURL.isEmpty {
                let targetURL = RealtimeVoiceAudio.validateBoardURL(explicitURL)
                if !(targetURL != nil && currentURL == targetURL && loadError == nil && !isLoading) {
                    _ = try await open(urlString: explicitURL, presentSheet: isPresented)
                } else if isPresented {
                    ensureWebViewHostedForRendering(force: true)
                }
            } else if currentURL == nil {
                guard !resolvedSeedURL.isEmpty else {
                    clearShareIntent()
                    throw MeetingSessionError.unavailable(L("Enter a Jira board URL or set a Default Jira Board URL in Skills → Team Context first."))
                }
                _ = try await open(urlString: resolvedSeedURL, presentSheet: isPresented)
            }
            if let loaded = currentURL?.absoluteString, !loaded.isEmpty {
                desiredShareURL = loaded
            }

            guard shareAttemptGeneration == attempt else { throw CancellationError() }
            guard target.canShareBoard else {
                throw MeetingSessionError.unavailable(L("Connect to a meeting before sharing the Assistant Board."))
            }

            var initialPixels: CVPixelBuffer?
            var capturedInitial = false
            for _ in 0..<3 {
                guard shareAttemptGeneration == attempt else { throw CancellationError() }
                if let captured = await captureBoardPixelBuffer() {
                    initialPixels = captured
                    capturedInitial = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard shareAttemptGeneration == attempt else { throw CancellationError() }
            if initialPixels == nil {
                initialPixels = await Self.renderPixelBufferOnQueue(cgImage: nil)
            }
            guard shareAttemptGeneration == attempt else { throw CancellationError() }
            guard target.canShareBoard else {
                throw MeetingSessionError.unavailable(L("Connect to a meeting before sharing the Assistant Board."))
            }
            guard let firstBuffer = initialPixels,
                  let initialSample = Self.makeSampleBuffer(from: firstBuffer) else {
                throw MeetingSessionError.unavailable(L("Could not capture the Assistant Board frame."))
            }

            try await target.startBoardSharing(initialSample: initialSample)
            guard shareAttemptGeneration == attempt, target.canShareBoard else {
                await target.stopBoardSharing()
                throw CancellationError()
            }

            sharedTarget = target
            sharingSessionID = target.id
            sharingMeetingTitle = target.title
            target.onExternalBoardShareStopped = { [weak self] in
                self?.stopSharing(notifyTarget: false)
            }
            target.onBoardShareInterrupted = { [weak self] in
                self?.handleInterruptedShare(targetID: target.id)
            }

            let sessionID = target.id
            if presentationModeEnabled, currentURL != nil {
                Task { @MainActor [weak self] in
                    guard let self, self.sharingSessionID == sessionID else { return }
                    _ = try? await self.callBoardAsyncJS(
                        JiraBoardDOMScripts.applyPresentationModeScript(enabled: true),
                        arguments: [:],
                        timeoutSeconds: 3
                    )
                    _ = try? await self.callBoardAsyncJS(
                        JiraBoardDOMScripts.focusActiveCardsScript(),
                        arguments: [:],
                        timeoutSeconds: 3
                    )
                    self.markBoardDirty()
                }
            }
            markBoardDirty()
            let initialGeneration = capturedInitial ? dirtyGeneration : 0
            lastCapturedGeneration = initialGeneration

            frameTask?.cancel()
            frameTask = Task { @MainActor [weak self] in
                guard let self else { return }
                var cachedBuffer: CVPixelBuffer? = capturedInitial ? firstBuffer : nil
                var lastPushUptime = ProcessInfo.processInfo.systemUptime
                var lastFreshSnapshotUptime = capturedInitial ? lastPushUptime : 0

                while !Task.isCancelled {
                    guard let currentTarget = self.sharedTarget,
                          currentTarget.id == sessionID,
                          currentTarget.isBoardShareSessionAlive else {
                        self.stopSharing(notifyTarget: false)
                        return
                    }
                    guard currentTarget.canShareBoard else {
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }

                    let uptime = ProcessInfo.processInfo.systemUptime
                    let isDirty = self.isLoading
                        || self.dirtyGeneration != self.lastCapturedGeneration
                        || (uptime - self.lastDirtyUptime) <= 1.2
                    let needsFreshRefresh = isDirty
                        || cachedBuffer == nil
                        || (uptime - lastFreshSnapshotUptime) >= 3.0

                    if needsFreshRefresh {
                        let targetGen = self.dirtyGeneration
                        let fresh = await self.captureBoardPixelBuffer()
                        guard !Task.isCancelled,
                              self.sharedTarget === currentTarget,
                              self.sharingSessionID == sessionID else {
                            return
                        }
                        if !currentTarget.isBoardShareSessionAlive {
                            self.stopSharing(notifyTarget: false)
                            return
                        }
                        if currentTarget.canShareBoard,
                           let fresh,
                           let sample = Self.makeSampleBuffer(from: fresh) {
                            cachedBuffer = fresh
                            self.lastCapturedGeneration = targetGen
                            lastFreshSnapshotUptime = ProcessInfo.processInfo.systemUptime
                            lastPushUptime = lastFreshSnapshotUptime
                            currentTarget.pushBoardShareFrame(sample)
                        }
                    } else if currentTarget.canShareBoard,
                              (uptime - lastPushUptime) >= 1.0,
                              let cachedBuffer,
                              let sample = Self.makeSampleBuffer(from: cachedBuffer) {
                        lastPushUptime = uptime
                        currentTarget.pushBoardShareFrame(sample)
                    }

                    try? await Task.sleep(for: .milliseconds(isDirty ? 160 : 350))
                }
            }

            ensureWebViewHostedForRendering()
            AppDiagnostics.log("board-share-active", [
                "capturedInitial": capturedInitial,
                "outputW": Int(Self.sharedOutputSize.width),
                "outputH": Int(Self.sharedOutputSize.height)
            ])
            lastActionSummary = L("Sharing desktop board to %@", target.title)
            return L("Sharing Assistant Board as Desktop (16:9) to “%@”.", target.title)
        } catch {
            let ns = error as NSError
            AppDiagnostics.log("board-share-error", [
                "stage": "startSharing",
                "errorType": String(describing: type(of: error)),
                "errorDomain": ns.domain,
                "errorCode": ns.code,
                "cancelled": error is CancellationError
            ])
            if !(error is CancellationError),
               desiredShareTargetID == target.id,
               target.isBoardShareSessionAlive,
               (!(desiredShareURL ?? "").isEmpty || currentURL != nil) {
                scheduleShareRecovery(targetID: target.id, reason: "startError")
            }
            throw error
        }
    }

    func stopSharing(notifyTarget: Bool = true) {
        teardownActiveShare(clearDesiredIntent: true, notifyTarget: notifyTarget)
    }

    private func handleInterruptedShare(targetID: UUID) {
        let shouldRecover = (desiredShareTargetID == targetID || sharingSessionID == targetID)
        let target = resolveShareTarget?(targetID)
        teardownActiveShare(clearDesiredIntent: !shouldRecover, notifyTarget: false)
        if shouldRecover, let target, target.isBoardShareSessionAlive {
            scheduleShareRecovery(targetID: targetID, reason: "interrupted")
        } else {
            clearShareIntent()
        }
    }

    private func clearShareIntent() {
        recoveryTask?.cancel()
        recoveryTask = nil
        desiredShareTargetID = nil
        desiredShareURL = nil
        isRecoveringShare = false
    }

    private func teardownActiveShare(clearDesiredIntent: Bool, notifyTarget: Bool) {
        shareAttemptGeneration &+= 1
        if clearDesiredIntent {
            clearShareIntent()
        }
        let wasSharing = isSharing || frameTask != nil || sharedTarget != nil
        frameTask?.cancel()
        frameTask = nil
        let target = sharedTarget
        sharedTarget = nil
        sharingSessionID = nil
        sharingMeetingTitle = nil
        target?.onExternalBoardShareStopped = nil
        target?.onBoardShareInterrupted = nil
        if notifyTarget, let target {
            Task { @MainActor in
                await target.stopBoardSharing()
            }
        }
        ensureWebViewHostedForRendering()
        if clearDesiredIntent, wasSharing, currentURL != nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = try? await self.callBoardAsyncJS(
                    JiraBoardDOMScripts.applyPresentationModeScript(enabled: false),
                    arguments: [:]
                )
            }
        }
        if wasSharing {
            AppDiagnostics.log("board-share-stop", [
                "notifyTarget": notifyTarget,
                "wasSharing": wasSharing,
                "reason": notifyTarget ? "userOrTool" : (clearDesiredIntent ? "external" : "interrupted")
            ])
            if clearDesiredIntent {
                lastActionSummary = L("Stopped sharing board")
            }
        }
    }

    private func scheduleShareRecovery(targetID: UUID, reason: String) {
        recoveryTask?.cancel()
        isRecoveringShare = true
        AppDiagnostics.log("board-share-recovery-scheduled", ["reason": reason])
        lastActionSummary = L("Board share interrupted — reconnecting automatically…")
        recoveryTask = Task { @MainActor [weak self] in
            defer {
                if self?.desiredShareTargetID == nil || self?.isSharing == true {
                    self?.isRecoveringShare = false
                }
            }
            for attempt in 1...60 {
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled, let self else { return }
                guard self.desiredShareTargetID == targetID else { return }
                if self.isSharing, self.sharingSessionID == targetID {
                    self.isRecoveringShare = false
                    return
                }
                guard let target = self.resolveShareTarget?(targetID), target.isBoardShareSessionAlive else {
                    self.clearShareIntent()
                    return
                }
                guard target.canShareBoard, !self.isStartingShare else { continue }
                do {
                    _ = try await self.startSharing(targetID: targetID, urlOverride: self.desiredShareURL)
                    AppDiagnostics.log("board-share-recovered", ["attempt": attempt])
                    self.isRecoveringShare = false
                    return
                } catch is CancellationError {
                    return
                } catch {
                    if !target.isBoardShareSessionAlive {
                        self.clearShareIntent()
                        return
                    }
                }
            }
            self?.isRecoveringShare = false
        }
    }

    #if DEBUG
    func loadHTMLForTesting(_ html: String, baseURL: URL? = URL(string: "https://jira.example.com/boards/42")) async {
        finishPendingNavigation()
        loadError = nil
        currentURL = baseURL
        urlDraft = baseURL?.absoluteString ?? ""
        isLoading = true
        ensureWebViewHostedForRendering(force: true)
        markBoardDirty()
        webView.loadHTMLString(html, baseURL: baseURL)
        await waitForLoadFinish(timeoutSeconds: 8)
        ensureWebViewHostedForRendering()
    }
    #endif

    func reload() {
        loadError = nil
        markBoardDirty()
        webView.reload()
    }

    func goBack() {
        markBoardDirty()
        webView.goBack()
    }

    func goForward() {
        markBoardDirty()
        webView.goForward()
    }

    func setPresentationMode(_ enabled: Bool) async {
        presentationModeEnabled = enabled
        guard currentURL != nil else { return }
        _ = try? await callBoardAsyncJS(JiraBoardDOMScripts.applyPresentationModeScript(enabled: enabled), arguments: [:])
        if enabled {
            _ = try? await callBoardAsyncJS(JiraBoardDOMScripts.focusActiveCardsScript(), arguments: [:])
        }
        markBoardDirty()
    }

    func scroll(deltaY: Int) async throws -> String {
        guard currentURL != nil else {
            throw MeetingSessionError.unavailable(L("Open a board first before scrolling."))
        }
        let clamped = max(-4000, min(4000, deltaY))
        _ = try await callBoardAsyncJS(JiraBoardDOMScripts.scrollBoardScript(deltaY: clamped), arguments: [:])
        markBoardDirty()
        lastActionSummary = L("Scrolled board by %ld px", clamped)
        return L("Scrolled the board by %ld px.", clamped)
    }

    func filter(query: String) async throws -> String {
        guard currentURL != nil else {
            throw MeetingSessionError.unavailable(L("Open a board first before filtering."))
        }
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = try await callBoardAsyncJS(JiraBoardDOMScripts.filterBoardScript(query: clean), arguments: [:])
        let ok = !msg.contains("No board search input")
        if ok && !clean.isEmpty {
            _ = try? await callBoardAsyncJS(JiraBoardDOMScripts.focusActiveCardsScript(), arguments: [:])
        }
        markBoardDirty()
        lastActionSummary = ok ? (clean.isEmpty ? L("Cleared board search") : L("Filtered board: %@", clean)) : L("No search box found on board")
        return ok
            ? (clean.isEmpty ? L("Cleared board search filter.") : L("Applied board filter “%@”.", clean))
            : L("No search input was found on the current board page.")
    }

    func selectPersonFilter(query: String, people: AssistantPeopleDirectory) async throws -> String {
        guard currentURL != nil else {
            throw MeetingSessionError.unavailable(L("Open a board first before filtering."))
        }
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return try await clearFilters()
        }
        let (terms, label) = JiraBoardDOMScripts.personFilterCandidateTerms(query: clean, directory: people)
        let raw = try await callBoardAsyncJS(
            JiraBoardDOMScripts.selectPersonFilterScript(candidateTerms: terms, displayLabel: label),
            arguments: [:]
        )
        let parsed = (raw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
        let matched = parsed?["matched"] as? Bool ?? false
        if matched {
            _ = try? await callBoardAsyncJS(JiraBoardDOMScripts.focusActiveCardsScript(), arguments: [:])
        }
        markBoardDirty()
        let resolvedLabel = (parsed?["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shownLabel = (resolvedLabel?.isEmpty == false ? resolvedLabel! : label)
        lastActionSummary = matched ? L("Filtered board by %@", shownLabel) : L("No filter matched %@", shownLabel)
        return matched
            ? L("Selected board filter for “%@”.", shownLabel)
            : L("No person filter or search box on the board matched “%@”.", shownLabel)
    }

    func clearFilters() async throws -> String {
        guard currentURL != nil else {
            throw MeetingSessionError.unavailable(L("Open a board first before clearing filters."))
        }
        let msg = try await callBoardAsyncJS(JiraBoardDOMScripts.clearFiltersScript(), arguments: [:])
        markBoardDirty()
        lastActionSummary = L("Cleared board filters")
        return msg.isEmpty ? L("Cleared board filters.") : msg
    }

    func click(selector: String?, text: String?) async throws -> String {
        guard currentURL != nil else {
            throw MeetingSessionError.unavailable(L("Open a board first before clicking."))
        }
        let selLiteral = try jsonLiteral(selector?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        let textLiteral = try jsonLiteral(text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        let js = """
        const sel = \(selLiteral);
        const txt = \(textLiteral).toLowerCase();
        let el = null;
        if (sel) { el = document.querySelector(sel); }
        if (!el && txt) {
          const all = Array.from(document.querySelectorAll('a, button, [role="button"], [data-testid*="issue"], [role="listitem"]'));
          el = all.find(node => (node.innerText || node.textContent || '').toLowerCase().includes(txt));
        }
        if (!el) { return { clicked: false }; }
        el.scrollIntoView({ block: 'center', behavior: 'smooth' });
        el.click();
        return { clicked: true, label: (el.innerText || el.textContent || '').trim().slice(0, 80) };
        """
        let res = try await evaluateJS(js)
        markBoardDirty()
        let dict = res as? [String: Any]
        let clicked = dict?["clicked"] as? Bool ?? false
        let label = (dict?["label"] as? String) ?? selector ?? text ?? ""
        lastActionSummary = clicked ? L("Clicked %@", label) : L("Target not found on board")
        return clicked ? L("Clicked “%@” on the board.", label) : L("No matching element was found on the board.")
    }

    func clickAt(x: Double, y: Double, normalized: Bool = true) async throws -> String {
        guard currentURL != nil else {
            throw MeetingSessionError.unavailable(L("Open a board first before clicking."))
        }
        guard x.isFinite, y.isFinite else {
            throw MeetingSessionError.unavailable(L("Board coordinates must be finite numbers."))
        }
        let clampedX = normalized ? min(max(x, 0.0), 1.0) : max(0.0, x)
        let clampedY = normalized ? min(max(y, 0.0), 1.0) : max(0.0, y)
        let js = """
        const normalized = \(normalized ? "true" : "false");
        const px = normalized ? (\(clampedX) * window.innerWidth) : \(clampedX);
        const py = normalized ? (\(clampedY) * window.innerHeight) : \(clampedY);
        const el = document.elementFromPoint(px, py);
        if (!el) { return { clicked: false, x: Math.round(px), y: Math.round(py) }; }
        for (const kind of ['pointerdown', 'mousedown']) {
          el.dispatchEvent(new PointerEvent(kind, { bubbles: true, cancelable: true, clientX: px, clientY: py, view: window }));
        }
        for (const kind of ['pointerup', 'mouseup', 'click']) {
          el.dispatchEvent(new MouseEvent(kind, { bubbles: true, cancelable: true, clientX: px, clientY: py, view: window }));
        }
        if (typeof el.focus === 'function') { el.focus(); }
        return {
          clicked: true,
          x: Math.round(px),
          y: Math.round(py),
          tag: (el.tagName || '').toLowerCase(),
          label: (el.innerText || el.getAttribute('aria-label') || el.tagName || '').trim().slice(0, 80)
        };
        """
        let res = try await evaluateJS(js)
        markBoardDirty()
        let dict = res as? [String: Any]
        let clicked = dict?["clicked"] as? Bool ?? false
        let px = dict?["x"] as? Int ?? Int(clampedX)
        let py = dict?["y"] as? Int ?? Int(clampedY)
        let label = (dict?["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (dict?["tag"] as? String)
            ?? "element"
        lastActionSummary = clicked ? L("Clicked %@ at (%ld, %ld)", label, px, py) : L("Nothing clickable at (%ld, %ld)", px, py)
        return clicked
            ? L("Clicked “%@” at (%ld, %ld) on the board.", label, px, py)
            : L("No element was found at (%ld, %ld) on the board.", px, py)
    }

    func highlight(text: String) async throws -> String {
        guard currentURL != nil else {
            throw MeetingSessionError.unavailable(L("Open a board first before highlighting."))
        }
        let literal = try jsonLiteral(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let js = """
        const needle = \(literal).toLowerCase();
        if (!needle) { return { found: false }; }
        const old = document.querySelector('[data-rock-highlight="true"]');
        if (old) { old.style.outline = ''; old.removeAttribute('data-rock-highlight'); }
        const nodes = Array.from(document.querySelectorAll('[data-issue-key], [data-testid*="card"], [role="listitem"], tr, article, a, div'));
        const match = nodes.find(n => {
          const t = (n.innerText || '').trim();
          return t.length > 0 && t.length < 360 && t.toLowerCase().includes(needle);
        });
        if (!match) { return { found: false }; }
        match.setAttribute('data-rock-highlight', 'true');
        match.style.outline = '3px solid #FF9500';
        match.style.outlineOffset = '2px';
        match.scrollIntoView({ block: 'center', behavior: 'smooth' });
        return { found: true };
        """
        let res = try await evaluateJS(js)
        markBoardDirty()
        let found = (res as? [String: Any])?["found"] as? Bool ?? false
        lastActionSummary = found ? L("Highlighted %@", text) : L("Item %@ not visible", text)
        return found ? L("Highlighted “%@” on the board.", text) : L("Could not find “%@” on the visible board.", text)
    }

    func inspect() async -> [String: Any] {
        guard currentURL != nil else {
            return ["open": false, "url": "", "title": "", "issues": []]
        }
        if let raw = try? await callBoardAsyncJS(JiraBoardDOMScripts.enhancedInspectScript(), arguments: [:]),
           let data = raw.data(using: .utf8),
           var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            dict["open"] = true
            let cards = (dict["cards"] as? [[String: Any]]) ?? []
            let keys = Array(Set(cards.compactMap { $0["key"] as? String })).sorted()
            dict["issues"] = keys
            return dict
        }
        return ["open": true, "url": currentURL?.absoluteString ?? ""]
    }

    func snapshotBase64(maxWidth: CGFloat = 1280) async throws -> (width: Int, height: Int, jpegBase64: String) {
        guard currentURL != nil else {
            throw MeetingSessionError.unavailable(L("Open a board first before capturing a snapshot."))
        }
        ensureWebViewHostedForRendering(force: true)
        defer { ensureWebViewHostedForRendering() }
        guard webView.bounds.width >= 8, webView.bounds.height >= 8 else {
            throw MeetingSessionError.unavailable(L("Open a board first before capturing a snapshot."))
        }
        let displayScale = currentDisplayScale()
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        config.rect = CGRect(origin: .zero, size: Self.desktopViewportSize)
        config.snapshotWidth = NSNumber(value: Double(maxWidth) / Double(displayScale))
        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: config) { img, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let img {
                    continuation.resume(returning: img)
                } else {
                    continuation.resume(throwing: MeetingSessionError.unavailable(L("Could not capture the Assistant Board snapshot.")))
                }
            }
        }
        let pixelWidth = image.cgImage.map { CGFloat($0.width) } ?? (image.size.width * image.scale)
        let pixelHeight = image.cgImage.map { CGFloat($0.height) } ?? (image.size.height * image.scale)
        let scale = pixelWidth > maxWidth && pixelWidth > 0 ? (maxWidth / pixelWidth) : 1.0
        let targetSize = CGSize(
            width: max(2, (pixelWidth * scale).rounded()),
            height: max(2, (pixelHeight * scale).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let data = scaled.jpegData(compressionQuality: 0.72) else {
            throw MeetingSessionError.unavailable(L("Could not encode the Assistant Board snapshot."))
        }
        lastActionSummary = L("Captured board snapshot (%ld×%ld)", Int(targetSize.width), Int(targetSize.height))
        return (Int(targetSize.width), Int(targetSize.height), data.base64EncodedString())
    }

    // MARK: - Frame Capture & Encoding

    private func captureBoardPixelBuffer() async -> CVPixelBuffer? {
        if let override = snapshotOverrideForTesting {
            guard let cg = await override() else { return nil }
            return await Self.renderPixelBufferOnQueue(cgImage: cg)
        }
        guard currentURL != nil else { return nil }
        ensureWebViewHostedForRendering(force: true)
        guard webView.bounds.width >= 8, webView.bounds.height >= 8 else { return nil }

        let displayScale = currentDisplayScale()
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        config.rect = CGRect(origin: .zero, size: Self.desktopViewportSize)
        config.snapshotWidth = NSNumber(value: Double(Self.sharedOutputSize.width) / Double(displayScale))
        let cg: CGImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image?.cgImage)
            }
        }
        guard let cg else { return nil }
        return await Self.renderPixelBufferOnQueue(cgImage: cg)
    }

    private func currentDisplayScale() -> CGFloat {
        max(
            1.0,
            activeSheetCanvas?.window?.windowScene?.screen.scale
                ?? parkingHostView?.window?.windowScene?.screen.scale
                ?? webView.window?.windowScene?.screen.scale
                ?? webView.traitCollection.displayScale
        )
    }

    private static func renderPixelBufferOnQueue(cgImage: CGImage?) async -> CVPixelBuffer? {
        await withCheckedContinuation { continuation in
            shareRenderQueue.async {
                continuation.resume(returning: makePixelBuffer(from: cgImage))
            }
        }
    }

    nonisolated private static func makePixelBuffer(from cgImage: CGImage?) -> CVPixelBuffer? {
        let width = Int(sharedOutputSize.width)
        let height = Int(sharedOutputSize.height)

        if poolState.pool == nil || poolState.width != width || poolState.height != height {
            var newPool: CVPixelBufferPool?
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            if CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &newPool) == kCVReturnSuccess {
                poolState.pool = newPool
                poolState.width = width
                poolState.height = height
            }
        }

        var pixelBuffer: CVPixelBuffer?
        if let pool = poolState.pool {
            _ = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                nil,
                pool,
                [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary,
                &pixelBuffer
            )
        }
        if pixelBuffer == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &pixelBuffer
            )
        }
        guard let buffer = pixelBuffer else { return nil }

        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        H264InputColorSignalling.tagPresenter(buffer)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        ctx.setFillColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        if let cgImage, cgImage.width >= 2, cgImage.height >= 2 {
            let srcW = CGFloat(cgImage.width)
            let srcH = CGFloat(cgImage.height)
            let fitScale = min(CGFloat(width) / srcW, CGFloat(height) / srcH)
            let drawW = (srcW * fitScale).rounded()
            let drawH = (srcH * fitScale).rounded()
            let drawRect = CGRect(
                x: ((CGFloat(width) - drawW) * 0.5).rounded(),
                y: ((CGFloat(height) - drawH) * 0.5).rounded(),
                width: drawW,
                height: drawH
            )
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: drawRect)
        }
        return buffer
    }

    private static func makeSampleBuffer(from pixels: CVPixelBuffer) -> CMSampleBuffer? {
        PresenterCompositor.sample(
            pixels,
            time: CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 1_000_000_000)
        )
    }

    private static func activeApplicationWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let preferredScenes = scenes.filter {
            $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
        }
        let candidateScenes = preferredScenes.isEmpty ? scenes : preferredScenes
        let windows = candidateScenes.flatMap(\.windows)
        return windows.first(where: { $0.isKeyWindow && !$0.isHidden })
            ?? windows.first(where: { $0.windowLevel == .normal && !$0.isHidden })
            ?? windows.first
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.preferredContentMode = .desktop
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        loadError = nil
        currentURL = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let u = webView.url { urlDraft = u.absoluteString }
        markBoardDirty()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        loadError = nil
        currentURL = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let u = webView.url {
            urlDraft = u.absoluteString
            onBoardURLChanged?(u.absoluteString)
        }
        if let t = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { pageTitle = t }
        markBoardDirty()
        finishPendingNavigation()
        ensureWebViewHostedForRendering()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.isSharing && self.presentationModeEnabled {
                _ = try? await self.callBoardAsyncJS(
                    JiraBoardDOMScripts.applyPresentationModeScript(enabled: true),
                    arguments: [:]
                )
                _ = try? await self.callBoardAsyncJS(
                    JiraBoardDOMScripts.focusActiveCardsScript(),
                    arguments: [:]
                )
                self.markBoardDirty()
            }
            await self.taskSync?.adoptJiraSessionFromBoardIfAvailable(self)
        }
    }

    // MARK: - JiraBoardWebEvaluating

    private struct JSArgumentsBox: @unchecked Sendable {
        let value: [String: Any]
    }

    var currentBoardURL: URL? { currentURL }
    var isBoardLoading: Bool { isLoading }

    func callBoardAsyncJS(_ functionBody: String, arguments: [String: Any]) async throws -> String {
        try await callBoardAsyncJS(functionBody, arguments: arguments, timeoutSeconds: 6)
    }

    func callBoardAsyncJS(
        _ functionBody: String,
        arguments: [String: Any],
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        ensureWebViewHostedForRendering(force: true)
        defer { ensureWebViewHostedForRendering() }
        let argsBox = JSArgumentsBox(value: arguments)
        let webView = self.webView
        return try await JiraBoardAsyncTimeout.run(seconds: timeoutSeconds) {
            let result = try await webView.callAsyncJavaScript(
                functionBody,
                arguments: argsBox.value,
                in: nil,
                contentWorld: .page
            )
            if let str = result as? String { return str }
            if let obj = result, JSONSerialization.isValidJSONObject(obj),
               let data = try? JSONSerialization.data(withJSONObject: obj),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return ""
        }
    }

    func cookiesForBoard(matching origin: URL) async -> [HTTPCookie] {
        let all = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return JiraBoardContextInfo.matchingCookies(all, for: origin)
    }

    func refreshBoardAfterJiraMutation(highlightIssueKey: String?) async {
        guard currentURL != nil else { return }
        let raw = (try? await callBoardAsyncJS(
            JiraBoardDOMScripts.refreshBoardAfterMutationScript(highlightIssueKey: highlightIssueKey),
            arguments: [:]
        )) ?? ""
        if !JiraBoardDOMScripts.parseRefreshedInPlace(raw) {
            finishPendingNavigation()
            isLoading = true
            ensureWebViewHostedForRendering(force: true)
            webView.reload()
            await waitForLoadFinish(timeoutSeconds: 4)
            ensureWebViewHostedForRendering()
            if let key = highlightIssueKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                _ = try? await callBoardAsyncJS(
                    JiraBoardDOMScripts.highlightIssueScript(issueKey: key),
                    arguments: [:]
                )
            }
        }
        markBoardDirty()
        if let key = highlightIssueKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            lastActionSummary = L("Updated %@", key)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        let ns = error as NSError
        if ns.code != NSURLErrorCancelled {
            loadError = error.localizedDescription
            AppDiagnostics.log("board-open-error", [
                "stage": "navigation",
                "errorDomain": ns.domain,
                "errorCode": ns.code
            ])
        }
        finishPendingNavigation()
        ensureWebViewHostedForRendering()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        let ns = error as NSError
        if ns.code != NSURLErrorCancelled {
            loadError = error.localizedDescription
            AppDiagnostics.log("board-open-error", [
                "stage": "provisional",
                "errorDomain": ns.domain,
                "errorCode": ns.code
            ])
        }
        finishPendingNavigation()
        ensureWebViewHostedForRendering()
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        SiteTLSDelegate.shared.handleChallenge(challenge, completionHandler: completionHandler)
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

    // MARK: - Helpers

    private func finishPendingNavigation() {
        let cont = navigationContinuation
        navigationContinuation = nil
        cont?.resume()
    }

    private func waitForLoadFinish(timeoutSeconds: TimeInterval) async {
        guard isLoading else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            navigationContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                self?.finishPendingNavigation()
            }
        }
    }

    private func evaluateJS(_ script: String) async throws -> Any? {
        let wrapped = "(function(){\n\(script)\n})()"
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(wrapped) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    private func jsonLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

struct IOSAssistantBoardSheet: View {
    @ObservedObject var controller: IOSAssistantBoardController
    let defaultBoardURL: String

    @Environment(\.dismiss) private var dismiss
    @State private var filterText = ""
    @State private var errorMessage: String?

    private var effectiveDefaultURL: String {
        let passed = defaultBoardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !passed.isEmpty { return passed }
        return controller.defaultBoardURLProvider?().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Button {
                        controller.goBack()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!controller.canGoBack)
                    .accessibilityLabel(L("Back"))

                    Button {
                        controller.goForward()
                    } label: {
                        Image(systemName: "chevron.forward")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!controller.canGoForward)
                    .accessibilityLabel(L("Forward"))

                    TextField("https://jira.example.com/boards/...", text: $controller.urlDraft)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { openDraft() }

                    Button(L("Go")) { openDraft() }
                        .buttonStyle(.borderedProminent)

                    if !effectiveDefaultURL.isEmpty,
                       controller.currentURL?.absoluteString != effectiveDefaultURL {
                        Button {
                            dismissKeyboard()
                            errorMessage = nil
                            let url = effectiveDefaultURL
                            controller.urlDraft = url
                            Task {
                                do {
                                    _ = try await controller.open(urlString: url)
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                            }
                        } label: {
                            Image(systemName: "link")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(L("Open Jira Board"))
                    }

                    Button {
                        errorMessage = nil
                        controller.reload()
                    } label: {
                        Group {
                            if controller.isLoading {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(L("Reload"))
                }
                .padding(.horizontal)
                .padding(.vertical, 6)

                HStack(spacing: 8) {
                    TextField(L("Filter or issue key…"), text: $filterText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { runFilter() }
                    Button(L("Filter")) { runFilter() }
                        .buttonStyle(.bordered)
                    Button(L("Highlight")) {
                        dismissKeyboard()
                        errorMessage = nil
                        Task {
                            do {
                                _ = try await controller.highlight(text: filterText)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    Button {
                        Task {
                            errorMessage = nil
                            do {
                                _ = try await controller.scroll(deltaY: -420)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(L("Scroll Up"))
                    Button {
                        Task {
                            errorMessage = nil
                            do {
                                _ = try await controller.scroll(deltaY: 420)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(L("Scroll Down"))
                    Button(controller.presentationModeEnabled ? L("Full") : L("Compact")) {
                        let next = !controller.presentationModeEnabled
                        Task { await controller.setPresentationMode(next) }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.bottom, 6)

                if let activeError = errorMessage ?? controller.loadError {
                    Text(activeError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                } else if let summary = controller.lastActionSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }

                IOSDesktopBoardViewportContainer(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                shareFooterBar
            }
            .navigationTitle(controller.pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) {
                        controller.isPresented = false
                        dismiss()
                    }
                }
            }
            .onDisappear {
                controller.isPresented = false
            }
            .task {
                let resolved = effectiveDefaultURL
                if controller.urlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !resolved.isEmpty {
                    controller.urlDraft = resolved
                }
                if controller.currentURL == nil {
                    let seed = controller.urlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? resolved
                        : controller.urlDraft
                    if !seed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        errorMessage = nil
                        do {
                            _ = try await controller.open(urlString: seed)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var shareFooterBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if controller.isSharing {
                HStack(spacing: 8) {
                    Image(systemName: "display")
                        .foregroundStyle(.orange)
                    Text(L("Sharing Desktop (16:9) to %@", controller.sharingMeetingTitle ?? L("Meeting")))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    Spacer()
                    Button(L("Stop Share"), role: .destructive) {
                        errorMessage = nil
                        controller.stopSharing()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Text(L("You can tap Done to return to the call — the 1280×720 desktop board keeps streaming."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if controller.isRecoveringShare {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L("Reconnecting board share automatically…"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    Spacer()
                    Button(L("Stop Share"), role: .destructive) {
                        errorMessage = nil
                        controller.stopSharing()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if controller.canShareToActiveMeeting {
                HStack(spacing: 8) {
                    Button {
                        dismissKeyboard()
                        errorMessage = nil
                        Task {
                            do {
                                _ = try await controller.startSharing()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        Label(
                            controller.isStartingShare ? L("Starting Share…") : L("Share Desktop Board"),
                            systemImage: "display"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(controller.isStartingShare || controller.isLoading)

                    Text(L("1280×720 → 1080p desktop view"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            } else {
                Text(L("Renders in 1280×720 desktop layout (pinch or double-tap to zoom). Join a call to stream it as a desktop screen."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func openDraft() {
        dismissKeyboard()
        errorMessage = nil
        Task {
            do {
                _ = try await controller.open(urlString: controller.urlDraft)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runFilter() {
        dismissKeyboard()
        errorMessage = nil
        Task {
            do {
                _ = try await controller.filter(query: filterText)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct IOSDesktopBoardViewportContainer: UIViewRepresentable {
    @ObservedObject var controller: IOSAssistantBoardController

    final class Coordinator {
        weak var controller: IOSAssistantBoardController?
        weak var canvasView: UIView?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> IOSDesktopBoardViewportView {
        let view = IOSDesktopBoardViewportView()
        context.coordinator.controller = controller
        context.coordinator.canvasView = view.canvasView
        controller.attachToSheetCanvas(view.canvasView)
        return view
    }

    func updateUIView(_ uiView: IOSDesktopBoardViewportView, context: Context) {
        if context.coordinator.controller !== controller {
            if let oldController = context.coordinator.controller,
               let oldCanvas = context.coordinator.canvasView {
                oldController.detachFromSheetCanvas(oldCanvas)
            }
            context.coordinator.controller = controller
            context.coordinator.canvasView = uiView.canvasView
            controller.attachToSheetCanvas(uiView.canvasView)
        }
    }

    static func dismantleUIView(_ uiView: IOSDesktopBoardViewportView, coordinator: Coordinator) {
        coordinator.controller?.detachFromSheetCanvas(uiView.canvasView)
        coordinator.controller = nil
        coordinator.canvasView = nil
    }
}

private final class IOSDesktopBoardViewportView: UIView, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    let canvasView = UIView(frame: CGRect(origin: .zero, size: IOSAssistantBoardController.desktopViewportSize))

    private var hasInitializedZoom = false
    private var lastFitScale: CGFloat = 1.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.08, alpha: 1.0)

        scrollView.delegate = self
        scrollView.backgroundColor = .clear
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.keyboardDismissMode = .interactive
        addSubview(scrollView)

        canvasView.backgroundColor = .white
        scrollView.addSubview(canvasView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }
        scrollView.frame = bounds

        let desktopSize = IOSAssistantBoardController.desktopViewportSize
        if canvasView.bounds.size != desktopSize {
            canvasView.bounds = CGRect(origin: .zero, size: desktopSize)
        }

        let fitScale = max(0.05, min(bounds.width / desktopSize.width, bounds.height / desktopSize.height))
        scrollView.minimumZoomScale = fitScale
        scrollView.maximumZoomScale = max(1.5, fitScale * 4.0)

        let wasFitted = !hasInitializedZoom || abs(scrollView.zoomScale - lastFitScale) < 0.01
        if wasFitted || scrollView.zoomScale < fitScale {
            scrollView.zoomScale = fitScale
            hasInitializedZoom = true
        }
        lastFitScale = fitScale
        centerCanvas()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        canvasView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerCanvas()
    }

    private func centerCanvas() {
        let desktopSize = IOSAssistantBoardController.desktopViewportSize
        let scaledWidth = desktopSize.width * scrollView.zoomScale
        let scaledHeight = desktopSize.height * scrollView.zoomScale
        scrollView.contentSize = CGSize(width: scaledWidth, height: scaledHeight)
        let offsetX = max((scrollView.bounds.width - scaledWidth) * 0.5, 0)
        let offsetY = max((scrollView.bounds.height - scaledHeight) * 0.5, 0)
        canvasView.center = CGPoint(x: scaledWidth * 0.5 + offsetX, y: scaledHeight * 0.5 + offsetY)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let targetScale: CGFloat
        if abs(scrollView.zoomScale - lastFitScale) < 0.05 {
            targetScale = min(1.0, scrollView.maximumZoomScale)
        } else {
            targetScale = lastFitScale
        }
        scrollView.setZoomScale(targetScale, animated: true)
    }
}
