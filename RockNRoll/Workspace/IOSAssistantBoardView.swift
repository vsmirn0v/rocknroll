import ConferenceCore
import SwiftUI
import UIKit
import WebKit

/// Sandbox-safe in-app WebView controller for inspecting, filtering, clicking,
/// and presenting Jira or project boards on iOS (shareable via Broadcast Upload).
@MainActor
final class IOSAssistantBoardController: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var urlDraft: String = ""
    @Published private(set) var currentURL: URL?
    @Published private(set) var pageTitle: String = L("Assistant Board")
    @Published private(set) var isLoading = false
    @Published private(set) var lastActionSummary: String?
    @Published var isPresented = false

    private(set) lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        return view
    }()

    private var navigationContinuation: CheckedContinuation<Void, Never>?

    @discardableResult
    func open(urlString: String) async throws -> String {
        guard let url = RealtimeVoiceAudio.validateBoardURL(urlString) else {
            throw MeetingSessionError.unavailable(L("Enter an https:// or localhost URL for the Assistant Board."))
        }
        finishPendingNavigation()
        currentURL = url
        urlDraft = url.absoluteString
        isPresented = true
        isLoading = true
        webView.load(URLRequest(url: url))
        await waitForLoadFinish(timeoutSeconds: 8)
        let title = (webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? url.host
            ?? url.absoluteString
        pageTitle = title
        lastActionSummary = L("Opened %@", title)
        return L("Opened %@ (%@).", title, url.absoluteString)
    }

    func reload() {
        webView.reload()
    }

    func scroll(deltaY: Int) async throws -> String {
        guard currentURL != nil else {
            throw MeetingSessionError.unavailable(L("Open a board first before scrolling."))
        }
        let clamped = max(-4000, min(4000, deltaY))
        _ = try await evaluateJS("window.scrollBy({top: \(clamped), behavior: 'smooth'}); return window.scrollY;")
        lastActionSummary = L("Scrolled board by %ld px", clamped)
        return L("Scrolled the board by %ld px.", clamped)
    }

    func filter(query: String) async throws -> String {
        guard currentURL != nil else {
            throw MeetingSessionError.unavailable(L("Open a board first before filtering."))
        }
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let arg = try jsonLiteral(clean)
        let js = """
        const q = \(arg);
        const candidates = Array.from(document.querySelectorAll('input[type="search"], input[aria-label*="Search" i], input[placeholder*="Search" i], input[placeholder*="Filter" i], input[name="search"], [data-testid*="search"] input'));
        const input = candidates.find(el => el.offsetParent !== null) || candidates[0];
        if (!input) { return { matched: false }; }
        input.focus();
        const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set;
        if (setter) { setter.call(input, q); } else { input.value = q; }
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true }));
        return { matched: true };
        """
        let res = try await evaluateJS(js)
        let ok = (res as? [String: Any])?["matched"] as? Bool ?? false
        lastActionSummary = ok ? L("Filtered board: %@", clean) : L("No search box found on board")
        return ok ? L("Applied board filter “%@”.", clean) : L("No search input was found on the current board page.")
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
        let found = (res as? [String: Any])?["found"] as? Bool ?? false
        lastActionSummary = found ? L("Highlighted %@", text) : L("Item %@ not visible", text)
        return found ? L("Highlighted “%@” on the board.", text) : L("Could not find “%@” on the visible board.", text)
    }

    func inspect() async -> [String: Any] {
        guard currentURL != nil else {
            return ["open": false, "url": "", "title": "", "issues": []]
        }
        let js = """
        const title = document.title || '';
        const url = window.location.href || '';
        const keyRe = /\\b[A-Z][A-Z0-9]{1,9}-\\d{1,6}\\b/g;
        const bodyText = (document.body?.innerText || '').slice(0, 24000);
        const foundKeys = Array.from(new Set(bodyText.match(keyRe) || [])).slice(0, 40);
        const cards = Array.from(document.querySelectorAll('[data-issue-key], [data-testid*="issue"], [data-testid*="card"], [role="listitem"]'))
          .slice(0, 30)
          .map(n => (n.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 180))
          .filter(Boolean);
        return { open: true, url, title, issues: foundKeys, cards };
        """
        return (try? await evaluateJS(js)) as? [String: Any] ?? ["open": true, "url": currentURL?.absoluteString ?? ""]
    }

    func snapshotBase64(maxWidth: CGFloat = 1280) async throws -> (width: Int, height: Int, jpegBase64: String) {
        guard currentURL != nil, webView.bounds.width >= 8, webView.bounds.height >= 8 else {
            throw MeetingSessionError.unavailable(L("Open a board first before capturing a snapshot."))
        }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
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
        let scale = image.size.width > maxWidth ? (maxWidth / image.size.width) : 1.0
        let targetSize = CGSize(
            width: max(2, (image.size.width * scale).rounded()),
            height: max(2, (image.size.height * scale).rounded())
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

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        currentURL = webView.url
        if let u = webView.url { urlDraft = u.absoluteString }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        currentURL = webView.url
        if let u = webView.url { urlDraft = u.absoluteString }
        if let t = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { pageTitle = t }
        finishPendingNavigation()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        finishPendingNavigation()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        finishPendingNavigation()
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
    @State private var urlError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("https://jira.example.com/boards/...", text: $controller.urlDraft)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { openDraft() }

                    Button(L("Go")) { openDraft() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    Button {
                        controller.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                HStack(spacing: 8) {
                    TextField(L("Filter or issue key…"), text: $filterText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(L("Filter")) {
                        Task { _ = try? await controller.filter(query: filterText) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button(L("Highlight")) {
                        Task { _ = try? await controller.highlight(text: filterText) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.bottom, 6)

                if let urlError {
                    Text(urlError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                } else if let summary = controller.lastActionSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                IOSBoardWebViewContainer(webView: controller.webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(L("Start Screen Share (ReplayKit) in your active call to show this board to everyone in the meeting."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
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
            .task {
                if controller.currentURL == nil {
                    let seed = controller.urlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? defaultBoardURL
                        : controller.urlDraft
                    if !seed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        urlError = nil
                        _ = try? await controller.open(urlString: seed)
                    }
                }
            }
        }
    }

    private func openDraft() {
        urlError = nil
        Task {
            do {
                _ = try await controller.open(urlString: controller.urlDraft)
            } catch {
                urlError = error.localizedDescription
            }
        }
    }
}

private struct IOSBoardWebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
