import AppKit
import ConferenceCore
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

private final class BoardDirtyScriptHandlerProxy: NSObject, WKScriptMessageHandler {
    weak var owner: AssistantBoardWindowController?
    init(owner: AssistantBoardWindowController) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor [weak owner] in
            owner?.markBoardDirty()
        }
    }
}

/// Sandbox-safe Computer Use controller for sharing and interacting with Jira or
/// project boards inside an in-app WKWebView window without Accessibility permissions.
@MainActor
final class AssistantBoardWindowController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate, JiraBoardWebEvaluating {
    @Published private(set) var currentURL: URL?
    @Published private(set) var pageTitle: String = L("Assistant Board")
    @Published private(set) var isLoading = false
    @Published private(set) var isWindowVisible = false
    @Published private(set) var sharingMeetingID: UUID?
    @Published private(set) var sharingMeetingTitle: String?
    @Published private(set) var isRecoveringShare = false
    @Published private(set) var lastActionSummary: String?
    @Published private(set) var loadError: String?
    weak var taskSync: WorkspaceTaskSyncController?
    var defaultBoardURLProvider: (() async -> String)?
    var onBoardURLChanged: ((String) -> Void)?

    private var window: NSWindow?
    private var webView: WKWebView?
    private var urlField: NSTextField?
    private var backButton: NSButton?
    private var forwardButton: NSButton?
    private var reloadButton: NSButton?
    private var jiraButton: NSButton?
    private var loadingIndicator: NSProgressIndicator?
    private var shareBannerLabel: NSTextField?
    private var stopShareButton: NSButton?
    private var frameTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var navigationContinuation: CheckedContinuation<Void, Never>?
    private weak var sharedMeetingModel: NativeDesktopMeetingModel?
    private weak var desiredShareModel: NativeDesktopMeetingModel?
    private var lastDirtyUptime: TimeInterval = 0
    private var lastCaptureUptime: TimeInterval = 0
    private static let shareRenderQueue = DispatchQueue(label: "RockNRoll.board-share-render", qos: .userInitiated)
    private final class PixelPoolState: @unchecked Sendable {
        static let shared = PixelPoolState()
        var pool: CVPixelBufferPool?
        var width = 0
        var height = 0
    }

    func markBoardDirty() {
        lastDirtyUptime = ProcessInfo.processInfo.systemUptime
    }

    static func validateBoardURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        let isLocal = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && isLocal) else { return nil }
        return url
    }

    func showWindow() {
        ensureWindow()
        window?.makeKeyAndOrderFront(nil)
        isWindowVisible = true
        if currentURL == nil, (urlField?.stringValue.trimmed.isEmpty ?? true), let provider = defaultBoardURLProvider {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seed = (await provider()).trimmed
                guard !seed.isEmpty else { return }
                if self.urlField?.stringValue.trimmed.isEmpty == true {
                    self.urlField?.stringValue = seed
                }
                if self.currentURL == nil && !self.isLoading {
                    _ = try? await self.open(urlString: seed)
                }
            }
        }
    }

    func closeWindow() {
        stopSharing()
        window?.orderOut(nil)
        isWindowVisible = false
    }

    func open(urlString: String) async throws -> String {
        guard let url = Self.validateBoardURL(urlString) else {
            throw NativeDesktopError.unavailable(L("Enter an https:// or localhost URL for the Assistant Board."))
        }
        showWindow()
        guard let webView else {
            throw NativeDesktopError.unavailable(L("Assistant Board web view is unavailable."))
        }
        if currentURL == url && loadError == nil && !isLoading {
            let title = webView.title?.trimmed.isEmpty == false ? (webView.title ?? url.host ?? url.absoluteString) : url.absoluteString
            pageTitle = title
            onBoardURLChanged?(url.absoluteString)
            await taskSync?.adoptJiraSessionFromBoardIfAvailable(self)
            return L("Opened %@ (%@).", title, url.absoluteString)
        }
        finishPendingNavigation()
        loadError = nil
        currentURL = url
        urlField?.stringValue = url.absoluteString
        isLoading = true
        refreshNavigationUI()
        refreshBanner()
        probeLog("board-open-start", [
            "scheme": url.scheme?.lowercased() ?? "unknown"
        ])
        webView.load(URLRequest(url: url))
        try? await waitForLoadFinish(timeoutSeconds: 8)
        let title = webView.title?.trimmed.isEmpty == false ? (webView.title ?? url.host ?? url.absoluteString) : url.absoluteString
        pageTitle = title
        onBoardURLChanged?(url.absoluteString)
        await taskSync?.adoptJiraSessionFromBoardIfAvailable(self)
        if let err = loadError {
            lastActionSummary = err
            return err
        }
        probeLog("board-open-ready", [
            "timedOutWhileLoading": isLoading
        ])
        lastActionSummary = L("Opened %@", title)
        return L("Opened %@ (%@).", title, url.absoluteString)
    }

    func startSharing(to model: NativeDesktopMeetingModel) async throws -> String {
        guard !model.isClosed else {
            throw NativeDesktopError.unavailable(L("Connect to the meeting before sharing the board."))
        }
        showWindow()
        desiredShareModel = model
        if currentURL == nil {
            let fieldSeed = urlField?.stringValue.trimmed ?? ""
            let resolvedSeed: String
            if !fieldSeed.isEmpty {
                resolvedSeed = fieldSeed
            } else if let provider = defaultBoardURLProvider {
                resolvedSeed = (await provider()).trimmed
            } else {
                resolvedSeed = ""
            }
            if !resolvedSeed.isEmpty {
                if urlField?.stringValue.trimmed.isEmpty == true {
                    urlField?.stringValue = resolvedSeed
                }
                _ = try? await open(urlString: resolvedSeed)
            }
        }
        if !model.connected {
            scheduleShareRecovery(for: model, reason: "waitingForReconnect")
            return L("Waiting for connection recovery to share Assistant Board to “%@”.", model.title)
        }
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecoveringShare = false
        if let activeModel = sharedMeetingModel, activeModel.sessionID != model.sessionID {
            activeModel.onExternalShareStopped = nil
            activeModel.onShareInterrupted = nil
            await activeModel.stopSharing()
            teardownActiveShare(clearDesiredIntent: false, notifyModel: false)
        }
        probeLog("board-share-start", [
            "hasLoadedBoard": currentURL != nil,
            "isLoading": isLoading
        ])
        guard model.startBoardSharing() else {
            probeLog("board-share-error", ["reason": "share-already-active-or-not-ready"])
            if !model.isClosed {
                scheduleShareRecovery(for: model, reason: "startNotReady")
            }
            throw NativeDesktopError.unavailable(L("Stop the active screen share before sharing the Assistant Board."))
        }
        probeLog("board-share-ready", [
            "viewport": "desktop"
        ])
        frameTask?.cancel()
        sharedMeetingModel = model
        sharingMeetingID = model.sessionID
        sharingMeetingTitle = model.title
        model.onExternalShareStopped = { [weak self] in
            self?.stopSharing(notifyModel: false)
        }
        model.onShareInterrupted = { [weak self, weak model] in
            guard let model else { return }
            self?.handleInterruptedShare(for: model)
        }
        refreshBanner()

        let targetSessionID = model.sessionID
        let shareStartedAt = Date()
        markBoardDirty()
        lastCaptureUptime = 0
        if let initialBuffer = await captureFrameBuffer() {
            lastCaptureUptime = ProcessInfo.processInfo.systemUptime
            model.pushBoardShareFrame(initialBuffer)
        }
        frameTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      let meeting = self.sharedMeetingModel,
                      meeting.sessionID == targetSessionID,
                      !meeting.isClosed else {
                    self?.stopSharing(notifyModel: false)
                    return
                }
                if Date().timeIntervalSince(shareStartedAt) > 8.0,
                   !meeting.isSharingLive,
                   !meeting.sharingPending {
                    self.handleInterruptedShare(for: meeting)
                    return
                }
                guard meeting.connected else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                let uptime = ProcessInfo.processInfo.systemUptime
                let isDirty = (uptime - self.lastDirtyUptime) <= 1.0 || self.isLoading
                let due = isDirty || (uptime - self.lastCaptureUptime) >= 1.0
                if due, let buffer = await self.captureFrameBuffer() {
                    self.lastCaptureUptime = ProcessInfo.processInfo.systemUptime
                    meeting.pushBoardShareFrame(buffer)
                }
                try? await Task.sleep(for: .milliseconds(isDirty ? 200 : 500))
            }
        }
        lastActionSummary = L("Sharing board to %@", model.title)
        return L("Sharing Assistant Board window to “%@”.", model.title)
    }

    func stopSharing() {
        stopSharing(notifyModel: true)
    }

    func stopSharing(notifyModel: Bool) {
        teardownActiveShare(clearDesiredIntent: true, notifyModel: notifyModel)
    }

    private func handleInterruptedShare(for model: NativeDesktopMeetingModel) {
        let shouldRecover = !model.isClosed && (desiredShareModel?.sessionID == model.sessionID || sharingMeetingID == model.sessionID)
        teardownActiveShare(clearDesiredIntent: !shouldRecover, notifyModel: false)
        if shouldRecover {
            scheduleShareRecovery(for: model, reason: "interrupted")
        }
    }

    private func teardownActiveShare(clearDesiredIntent: Bool, notifyModel: Bool) {
        if clearDesiredIntent {
            recoveryTask?.cancel()
            recoveryTask = nil
            desiredShareModel?.onShareInterrupted = nil
            desiredShareModel = nil
            isRecoveringShare = false
        }
        let wasSharing = sharingMeetingID != nil || frameTask != nil
        frameTask?.cancel()
        frameTask = nil
        if let model = sharedMeetingModel {
            model.onExternalShareStopped = nil
            model.onShareInterrupted = nil
            if notifyModel {
                Task { @MainActor in await model.stopSharing() }
            }
        }
        sharedMeetingModel = nil
        sharingMeetingID = nil
        sharingMeetingTitle = nil
        if wasSharing {
            probeLog("board-share-stop", ["notifyModel": notifyModel, "recoveredPending": !clearDesiredIntent])
        }
        refreshBanner()
        if clearDesiredIntent {
            lastActionSummary = L("Stopped sharing board")
        }
    }

    private func scheduleShareRecovery(for model: NativeDesktopMeetingModel, reason: String) {
        let targetID = model.sessionID
        desiredShareModel = model
        recoveryTask?.cancel()
        isRecoveringShare = true
        probeLog("board-share-recovery-scheduled", ["reason": reason])
        lastActionSummary = L("Board share interrupted — reconnecting automatically…")
        refreshBanner()
        recoveryTask = Task { @MainActor [weak self] in
            defer {
                if self?.desiredShareModel == nil || self?.sharingMeetingID == targetID {
                    self?.isRecoveringShare = false
                    self?.refreshBanner()
                }
            }
            for attempt in 1...60 {
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled, let self else { return }
                guard let candidate = self.desiredShareModel,
                      candidate.sessionID == targetID,
                      !candidate.isClosed else {
                    self.desiredShareModel = nil
                    self.isRecoveringShare = false
                    self.refreshBanner()
                    return
                }
                if self.sharingMeetingID == targetID {
                    self.isRecoveringShare = false
                    self.refreshBanner()
                    return
                }
                guard candidate.connected, !candidate.isClosed, !candidate.sharingPending else { continue }
                do {
                    _ = try await self.startSharing(to: candidate)
                    probeLog("board-share-recovered", ["attempt": attempt])
                    self.isRecoveringShare = false
                    self.refreshBanner()
                    return
                } catch {
                    if candidate.isClosed {
                        self.desiredShareModel = nil
                        self.isRecoveringShare = false
                        self.refreshBanner()
                        return
                    }
                }
            }
            self?.isRecoveringShare = false
            self?.refreshBanner()
        }
    }

    func scroll(deltaY: Int) async throws -> String {
        guard let webView else {
            throw NativeDesktopError.unavailable(L("Open a board first before scrolling."))
        }
        let clamped = max(-4000, min(4000, deltaY))
        _ = try await evaluateJS(webView: webView, script: "window.scrollBy({top: \(clamped), behavior: 'smooth'}); return window.scrollY;")
        markBoardDirty()
        lastActionSummary = L("Scrolled board by %ld px", clamped)
        return L("Scrolled the board by %ld px.", clamped)
    }

    func filter(query: String) async throws -> String {
        guard webView != nil, currentURL != nil else {
            throw NativeDesktopError.unavailable(L("Open a board first before filtering."))
        }
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = try await callBoardAsyncJS(JiraBoardDOMScripts.filterBoardScript(query: clean), arguments: [:])
        markBoardDirty()
        let ok = !msg.contains("No board search input")
        lastActionSummary = ok ? (clean.isEmpty ? L("Cleared board search") : L("Filtered board: %@", clean)) : L("No search box found on board")
        return ok
            ? (clean.isEmpty ? L("Cleared board search filter.") : L("Applied board filter “%@”.", clean))
            : L("No search input was found on the current board page.")
    }

    func selectPersonFilter(query: String, people: AssistantPeopleDirectory) async throws -> String {
        guard webView != nil, currentURL != nil else {
            throw NativeDesktopError.unavailable(L("Open a board first before filtering."))
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
        markBoardDirty()
        let parsed = (raw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
        let matched = parsed?["matched"] as? Bool ?? false
        let resolvedLabel = (parsed?["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shownLabel = (resolvedLabel?.isEmpty == false ? resolvedLabel! : label)
        lastActionSummary = matched ? L("Filtered board by %@", shownLabel) : L("No filter matched %@", shownLabel)
        return matched
            ? L("Selected board filter for “%@”.", shownLabel)
            : L("No person filter or search box on the board matched “%@”.", shownLabel)
    }

    func clearFilters() async throws -> String {
        guard webView != nil, currentURL != nil else {
            throw NativeDesktopError.unavailable(L("Open a board first before clearing filters."))
        }
        let msg = try await callBoardAsyncJS(JiraBoardDOMScripts.clearFiltersScript(), arguments: [:])
        markBoardDirty()
        lastActionSummary = L("Cleared board filters")
        return msg.isEmpty ? L("Cleared board filters.") : msg
    }

    func click(selector: String?, text: String?) async throws -> String {
        guard let webView else {
            throw NativeDesktopError.unavailable(L("Open a board first before clicking."))
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
        let res = try await evaluateJS(webView: webView, script: js)
        markBoardDirty()
        let dict = res as? [String: Any]
        let clicked = dict?["clicked"] as? Bool ?? false
        let label = (dict?["label"] as? String) ?? selector ?? text ?? ""
        lastActionSummary = clicked ? L("Clicked %@", label) : L("Target not found on board")
        return clicked ? L("Clicked “%@” on the board.", label) : L("No matching element was found on the board.")
    }

    func clickAt(x: Double, y: Double, normalized: Bool = true) async throws -> String {
        guard let webView else {
            throw NativeDesktopError.unavailable(L("Open a board first before clicking."))
        }
        guard x.isFinite, y.isFinite else {
            throw NativeDesktopError.unavailable(L("Board coordinates must be finite numbers."))
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
        let res = try await evaluateJS(webView: webView, script: js)
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

    func snapshotBase64(maxWidth: CGFloat = 1280) async throws -> (width: Int, height: Int, jpegBase64: String) {
        guard let webView, webView.bounds.width >= 8, webView.bounds.height >= 8 else {
            throw NativeDesktopError.unavailable(L("Open a board first before capturing a snapshot."))
        }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        let image: NSImage? = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: config) { img, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: img)
                }
            }
        }
        guard let image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NativeDesktopError.unavailable(L("Could not capture the Assistant Board snapshot."))
        }
        let encoded = await withCheckedContinuation { continuation in
            Self.shareRenderQueue.async {
                continuation.resume(returning: Self.encodeJPEG(cgImage: cg, maxWidth: maxWidth))
            }
        }
        guard let encoded else {
            throw NativeDesktopError.unavailable(L("Could not encode the Assistant Board snapshot."))
        }
        lastActionSummary = L("Captured board snapshot (%ld×%ld)", encoded.width, encoded.height)
        return encoded
    }

    nonisolated private static func encodeJPEG(cgImage: CGImage, maxWidth: CGFloat) -> (width: Int, height: Int, jpegBase64: String)? {
        let targetWidth = min(CGFloat(cgImage.width), maxWidth)
        let scale = CGFloat(cgImage.width) > 0 ? targetWidth / CGFloat(cgImage.width) : 1.0
        let targetHeight = max(2, Int((CGFloat(cgImage.height) * scale).rounded()))
        let intWidth = max(2, Int(targetWidth.rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: intWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: intWidth, height: targetHeight))
        guard let scaled = ctx.makeImage(),
              let jpegData = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(jpegData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.72]
        CGImageDestinationAddImage(dest, scaled, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (intWidth, targetHeight, (jpegData as Data).base64EncodedString())
    }

    func highlight(text: String) async throws -> String {
        guard let webView else {
            throw NativeDesktopError.unavailable(L("Open a board first before highlighting."))
        }
        let targetLiteral = try jsonLiteral(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let js = """
        const needle = \(targetLiteral).toLowerCase();
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
        return { found: true, snippet: (match.innerText || '').trim().slice(0, 120) };
        """
        let res = try await evaluateJS(webView: webView, script: js)
        markBoardDirty()
        let found = (res as? [String: Any])?["found"] as? Bool ?? false
        lastActionSummary = found ? L("Highlighted %@", text) : L("Item %@ not visible", text)
        return found ? L("Highlighted “%@” on the board.", text) : L("Could not find “%@” on the visible board.", text)
    }

    func inspect() async throws -> [String: Any] {
        guard webView != nil, currentURL != nil else {
            return ["open": false, "url": "", "title": "", "issues": []]
        }
        var output: [String: Any] = ["open": true, "url": currentURL?.absoluteString ?? ""]
        if let raw = try? await callBoardAsyncJS(JiraBoardDOMScripts.enhancedInspectScript(), arguments: [:]),
           let data = raw.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            output.merge(dict) { _, new in new }
            let cards = (dict["cards"] as? [[String: Any]]) ?? []
            output["issues"] = Array(Set(cards.compactMap { $0["key"] as? String })).sorted()
        }
        output["sharing"] = sharingMeetingID != nil
        if let sharingMeetingTitle {
            output["sharing_meeting_title"] = sharingMeetingTitle
        }
        return output
    }

    // MARK: - Window & WebView setup

    private func ensureWindow() {
        if window != nil { return }
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
        let win = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = L("Rock Assistant Board")
        win.minSize = NSSize(width: 540, height: 380)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.setFrameAutosaveName("RockAssistantBoardWindow")

        let root = NSView(frame: frame)

        let back = NSButton(
            image: NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: L("Back")) ?? NSImage(),
            target: self,
            action: #selector(handleBack(_:))
        )
        back.bezelStyle = .texturedRounded
        back.isEnabled = false
        back.setAccessibilityLabel(L("Back"))

        let forward = NSButton(
            image: NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: L("Forward")) ?? NSImage(),
            target: self,
            action: #selector(handleForward(_:))
        )
        forward.bezelStyle = .texturedRounded
        forward.isEnabled = false
        forward.setAccessibilityLabel(L("Forward"))

        let reload = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L("Reload")) ?? NSImage(),
            target: self,
            action: #selector(handleReload(_:))
        )
        reload.bezelStyle = .texturedRounded
        reload.setAccessibilityLabel(L("Reload"))

        let field = NSTextField()
        field.placeholderString = "https://jira.example.com/boards/..."
        field.target = self
        field.action = #selector(submitURLField(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        let banner = NSTextField(labelWithString: "")
        banner.font = .systemFont(ofSize: 11, weight: .medium)
        banner.textColor = .secondaryLabelColor
        banner.lineBreakMode = .byTruncatingTail
        banner.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        banner.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stopBtn = NSButton(title: L("Stop Share"), target: self, action: #selector(handleStopShare(_:)))
        stopBtn.bezelStyle = .rounded
        stopBtn.isHidden = true

        let jiraBtn = NSButton(title: L("Open Jira"), target: self, action: #selector(handleOpenDefaultJira(_:)))
        jiraBtn.bezelStyle = .rounded
        jiraBtn.setContentHuggingPriority(.required, for: .horizontal)

        let toolbarStack = NSStackView(views: [back, forward, reload, jiraBtn, field, spinner, banner, stopBtn])
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.spacing = 8
        toolbarStack.detachesHiddenViews = true
        toolbarStack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let controller = WKUserContentController()
        let dirtyJS = """
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
        controller.addUserScript(WKUserScript(source: dirtyJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.add(BoardDirtyScriptHandlerProxy(owner: self), name: "boardDirty")
        config.userContentController = controller
        let web = WKWebView(frame: .zero, configuration: config)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.navigationDelegate = self
        web.uiDelegate = self

        root.addSubview(toolbarStack)
        root.addSubview(web)
        NSLayoutConstraint.activate([
            toolbarStack.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarStack.heightAnchor.constraint(equalToConstant: 44),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 240),

            web.topAnchor.constraint(equalTo: toolbarStack.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        win.contentView = root

        self.window = win
        self.webView = web
        self.backButton = back
        self.forwardButton = forward
        self.reloadButton = reload
        self.jiraButton = jiraBtn
        self.loadingIndicator = spinner
        self.urlField = field
        self.shareBannerLabel = banner
        self.stopShareButton = stopBtn
        refreshNavigationUI()
        refreshBanner()
    }

    @objc private func handleBack(_ sender: Any?) { webView?.goBack() }
    @objc private func handleForward(_ sender: Any?) { webView?.goForward() }
    @objc private func handleReload(_ sender: Any?) {
        if isLoading {
            webView?.stopLoading()
            isLoading = false
            refreshNavigationUI()
        } else {
            loadError = nil
            refreshBanner()
            if webView?.url != nil {
                webView?.reload()
            } else if let candidate = [urlField?.stringValue, currentURL?.absoluteString]
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        _ = try await self.open(urlString: candidate)
                    } catch {
                        self.loadError = error.localizedDescription
                        self.refreshBanner()
                    }
                }
            }
        }
    }

    @objc private func submitURLField(_ sender: NSTextField) {
        let value = sender.stringValue
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.open(urlString: value)
            } catch {
                self.loadError = error.localizedDescription
                self.refreshBanner()
            }
        }
    }

    @objc private func handleStopShare(_ sender: Any?) {
        stopSharing()
    }

    @objc private func handleOpenDefaultJira(_ sender: Any?) {
        guard let provider = defaultBoardURLProvider else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let seed = (await provider()).trimmed
            guard !seed.isEmpty else {
                self.loadError = L("Configure a Jira board URL in Meeting Settings or Team Context first.")
                self.refreshBanner()
                return
            }
            self.urlField?.stringValue = seed
            do {
                _ = try await self.open(urlString: seed)
            } catch {
                self.loadError = error.localizedDescription
                self.refreshBanner()
            }
        }
    }

    private func refreshNavigationUI() {
        backButton?.isEnabled = webView?.canGoBack ?? false
        forwardButton?.isEnabled = webView?.canGoForward ?? false
        loadingIndicator?.isHidden = !isLoading
        if isLoading {
            loadingIndicator?.startAnimation(nil)
            reloadButton?.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("Stop"))
            reloadButton?.setAccessibilityLabel(L("Stop"))
        } else {
            loadingIndicator?.stopAnimation(nil)
            reloadButton?.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L("Reload"))
            reloadButton?.setAccessibilityLabel(L("Reload"))
        }
    }

    private func refreshBanner() {
        if let err = loadError, !err.isEmpty {
            shareBannerLabel?.stringValue = err
            shareBannerLabel?.textColor = .systemRed
            stopShareButton?.isHidden = (sharingMeetingTitle == nil && !isRecoveringShare)
        } else if let title = sharingMeetingTitle {
            shareBannerLabel?.stringValue = L("Sharing to %@", title)
            shareBannerLabel?.textColor = .systemOrange
            stopShareButton?.isHidden = false
        } else if isRecoveringShare {
            shareBannerLabel?.stringValue = L("Reconnecting share…")
            shareBannerLabel?.textColor = .systemOrange
            stopShareButton?.isHidden = false
        } else {
            shareBannerLabel?.stringValue = L("Not sharing")
            shareBannerLabel?.textColor = .secondaryLabelColor
            stopShareButton?.isHidden = true
        }
    }

    // MARK: - Snapshot → CVPixelBuffer

    private func captureFrameBuffer() async -> CVPixelBuffer? {
        guard let webView, webView.bounds.width >= 8, webView.bounds.height >= 8 else { return nil }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        let cg: CGImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
        guard let cg else { return nil }
        return await withCheckedContinuation { continuation in
            Self.shareRenderQueue.async {
                continuation.resume(returning: Self.makePixelBuffer(from: cg))
            }
        }
    }

    nonisolated private static func makePixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        let srcW = CGFloat(cgImage.width)
        let srcH = CGFloat(cgImage.height)
        guard srcW >= 2, srcH >= 2 else { return nil }
        let scale = min(1.0, min(1920.0 / srcW, 1080.0 / srcH))
        let width = max(2, Int(floor(srcW * scale / 2.0) * 2.0))
        let height = max(2, Int(floor(srcH * scale / 2.0) * 2.0))

        let poolState = PixelPoolState.shared
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
                [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary,
                &pixelBuffer
            )
        }
        if pixelBuffer == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        }
        guard let buffer = pixelBuffer else { return nil }

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
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: - WKNavigationDelegate / NSWindowDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        loadError = nil
        currentURL = webView.url
        if let u = webView.url { urlField?.stringValue = u.absoluteString }
        markBoardDirty()
        refreshNavigationUI()
        refreshBanner()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        loadError = nil
        currentURL = webView.url
        if let u = webView.url {
            urlField?.stringValue = u.absoluteString
            onBoardURLChanged?(u.absoluteString)
        }
        if let title = webView.title, !title.trimmed.isEmpty { pageTitle = title }
        markBoardDirty()
        refreshNavigationUI()
        refreshBanner()
        finishPendingNavigation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.taskSync?.adoptJiraSessionFromBoardIfAvailable(self)
        }
    }

    // MARK: - JiraBoardWebEvaluating

    var currentBoardURL: URL? { currentURL }

    func callBoardAsyncJS(_ functionBody: String, arguments: [String: Any]) async throws -> String {
        guard let webView else {
            throw NativeDesktopError.unavailable(L("Assistant Board web view is unavailable."))
        }
        let result = try await webView.callAsyncJavaScript(
            functionBody,
            arguments: arguments,
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

    func cookiesForBoard(matching origin: URL) async -> [HTTPCookie] {
        guard let webView else { return [] }
        let all = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return JiraBoardContextInfo.matchingCookies(all, for: origin)
    }

    func refreshBoardAfterJiraMutation(highlightIssueKey: String?) async {
        guard let webView, currentURL != nil else { return }
        let raw = (try? await callBoardAsyncJS(
            JiraBoardDOMScripts.refreshBoardAfterMutationScript(highlightIssueKey: highlightIssueKey),
            arguments: [:]
        )) ?? ""
        if !JiraBoardDOMScripts.parseRefreshedInPlace(raw) {
            finishPendingNavigation()
            isLoading = true
            refreshNavigationUI()
            refreshBanner()
            webView.reload()
            try? await waitForLoadFinish(timeoutSeconds: 4)
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
        let nsError = error as NSError
        if !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
            loadError = error.localizedDescription
            probeLog("board-open-error", [
                "stage": "navigation",
                "errorDomain": nsError.domain,
                "errorCode": nsError.code
            ])
        }
        refreshNavigationUI()
        refreshBanner()
        finishPendingNavigation()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        let nsError = error as NSError
        if !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
            loadError = error.localizedDescription
            probeLog("board-open-error", [
                "stage": "provisional",
                "errorDomain": nsError.domain,
                "errorCode": nsError.code
            ])
        }
        refreshNavigationUI()
        refreshBanner()
        finishPendingNavigation()
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

    func windowWillClose(_ notification: Notification) {
        finishPendingNavigation()
        isWindowVisible = false
        stopSharing()
    }

    func windowDidResize(_ notification: Notification) {
        markBoardDirty()
    }

    // MARK: - Helpers

    private func finishPendingNavigation() {
        let cont = navigationContinuation
        navigationContinuation = nil
        cont?.resume()
    }

    private func waitForLoadFinish(timeoutSeconds: TimeInterval) async throws {
        guard isLoading else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            navigationContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                self?.finishPendingNavigation()
            }
        }
    }

    private func evaluateJS(webView: WKWebView, script: String) async throws -> Any? {
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
