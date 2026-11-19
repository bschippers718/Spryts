import AppKit
import Combine
import WebKit

// The X feed's web view: X's own site, with Sift running in the page.
// The person signs in to X here once; the app never sees the password and never calls X's API.

/// WebKit keeps its message handlers alive, so the handler is a small object that only points back.
private final class SiftMessageRelay: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: SiftWebController?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let owner else { return (nil, "closed") }
        return owner.answer(message)
    }
}

@MainActor
final class SiftWebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var signedOut = false
    @Published private(set) var onFeed = true
    @Published private(set) var problem: String?
    @Published var showFilters = false

    let webView: WKWebView
    let store: SiftStore
    let engine: SiftEngine?
    let engineProblem: String?

    private static let world = WKContentWorld.world(name: "Sift")
    private var world: WKContentWorld { SiftWebController.world }
    private var pushed: SiftSettings
    private var watching: Set<AnyCancellable> = []
    private var observing: [NSKeyValueObservation] = []

    private static var shared: [String: SiftWebController] = [:]

    /// One feed per chief, kept while the app runs so the place in the timeline survives a trip to another pane.
    static func of(_ chiefID: String) -> SiftWebController {
        if let existing = shared[chiefID] { return existing }
        let controller = SiftWebController(store: SiftStore.of(chiefID))
        shared[chiefID] = controller
        return controller
    }

    init(store: SiftStore) {
        self.store = store
        pushed = store.settings
        var loaded: SiftEngine?
        var failure: String?
        do { loaded = try SiftEngine() } catch { failure = error.localizedDescription }
        engine = loaded
        engineProblem = failure

        let relay = SiftMessageRelay()
        let content = WKUserContentController()
        if let loaded {
            content.addUserScript(WKUserScript(source: loaded.script, injectionTime: .atDocumentEnd,
                                               forMainFrameOnly: true, in: SiftWebController.world))
            content.addScriptMessageHandler(relay, contentWorld: SiftWebController.world, name: "sift")
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()          // stay signed in between launches
        configuration.userContentController = content
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init()

        relay.owner = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observing = [
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.loading = view.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.located(view.url) }
            },
        ]
        store.$settings.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] next in self?.settingsChanged(next) }
            .store(in: &watching)
    }

    // MARK: Moving around

    func start() {
        if webView.url == nil && !webView.isLoading { openFeed() }
    }

    func openFeed() {
        problem = nil
        webView.load(URLRequest(url: store.settings.startURL))
    }

    func reload() {
        problem = nil
        if webView.url == nil { openFeed() } else { webView.reload() }
    }

    func goBack() { webView.goBack() }

    func rest() { webView.pauseAllMediaPlayback(completionHandler: nil) }

    func openInBrowser() {
        if let url = webView.url, SiftWebController.isX(url) { NSWorkspace.shared.open(url) }
    }

    static func isX(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" || host.hasSuffix(".twitter.com")
    }

    private func located(_ url: URL?) {
        guard let url else { return }
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        signedOut = path == "/" || path == "/login" || path.hasPrefix("/i/flow/login") || path.hasPrefix("/i/flow/signup")
        onFeed = path == "/home" || path == store.settings.listURL?.path
    }

    // MARK: Settings, both ways

    /// Tells the page what changed, in the shape Chrome's storage reports it. Sift re-filters on its own.
    private func settingsChanged(_ next: SiftSettings) {
        let before = pushed.dictionary
        let after = next.dictionary
        let movedFeed = pushed.startURL != next.startURL
        pushed = next
        var changes: [String: Any] = [:]
        for (key, value) in after {
            let old = before[key]
            if (old as? NSObject) != (value as? NSObject) {
                var change: [String: Any] = ["newValue": value]
                if let old { change["oldValue"] = old }
                changes[key] = change
            }
        }
        if !changes.isEmpty { emit(changes, area: "sync") }
        if movedFeed { openFeed() } else { located(webView.url) }
    }

    private func emit(_ changes: [String: Any], area: String) {
        guard JSONSerialization.isValidJSONObject(changes),
              let data = try? JSONSerialization.data(withJSONObject: changes) else { return }
        webView.callAsyncJavaScript("if (globalThis.__siftChanged) { globalThis.__siftChanged(json, area); }",
                                    arguments: ["json": String(decoding: data, as: UTF8.self), "area": area],
                                    in: nil, in: world, completionHandler: nil)
    }

    /// Sift in the page asking for its storage. Only the main frame of X is answered.
    fileprivate func answer(_ message: WKScriptMessage) -> (Any?, String?) {
        guard message.frameInfo.isMainFrame,
              ["x.com", "twitter.com"].contains(where: { host in
                  let origin = message.frameInfo.securityOrigin.host.lowercased()
                  return origin == host || origin.hasSuffix("." + host)
              }),
              message.frameInfo.securityOrigin.protocol == "https",
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return (nil, "refused") }
        let area = body["area"] as? String ?? ""

        switch type {
        case "get":
            let values: [String: Any] = area == "sync" ? store.settings.dictionary : (area == "local" ? store.local : [:])
            guard let data = try? JSONSerialization.data(withJSONObject: values) else { return ("{}", nil) }
            return (String(decoding: data, as: UTF8.self), nil)
        case "set":
            guard let json = body["values"] as? String, json.utf8.count <= 64_000,
                  let values = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return (nil, "refused") }
            if area == "sync" {
                store.merge(values)          // the page hears about it through settingsChanged
            } else if area == "local", let changes = store.setLocal(values) {
                emit(changes, area: "local")
            }
            return (true, nil)
        case "remove":
            if area == "local", let keys = body["keys"] as? [String] { store.removeLocal(Array(keys.prefix(20))) }
            return (true, nil)
        case "open":
            if body["name"] as? String == "open-options" { showFilters = true }
            return (true, nil)
        default:
            return (nil, "refused")
        }
    }

    /// The most recent posts Sift kept. Read only when the person asks Pip for a brief.
    func keptPosts() async -> [SiftPost] {
        guard engine != nil else { return [] }
        let json: String = await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript("return globalThis.__siftBridge ? globalThis.__siftBridge.posts(limit) : \"[]\";",
                                        arguments: ["limit": SiftEvidence.maximumPosts], in: nil, in: world) { result in
                if case .success(let value) = result, let text = value as? String {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(returning: "[]")
                }
            }
        }
        return SiftPost.parse(json)
    }

    /// Forgets the X sign-in kept by this app. Safari and Chrome are untouched.
    func signOut() {
        let data = WKWebsiteDataStore.default()
        let kinds = WKWebsiteDataStore.allWebsiteDataTypes()
        data.fetchDataRecords(ofTypes: kinds) { [weak self] records in
            let mine = records.filter { record in
                let name = record.displayName.lowercased()
                return name == "x.com" || name.hasSuffix(".x.com") || name == "twitter.com" || name.hasSuffix(".twitter.com")
                    || name == "twimg.com" || name.hasSuffix(".twimg.com")
            }
            data.removeData(ofTypes: kinds, for: mine) {
                Task { @MainActor in self?.openFeed() }
            }
        }
    }

    // MARK: WebKit

    /// The view stays on X. Anything else a person clicks opens in their own browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if let frame = navigationAction.targetFrame, !frame.isMainFrame { return .allow }   // sign-in checks run in frames
        if SiftWebController.isX(url) || url.absoluteString == "about:blank" { return .allow }
        if navigationAction.navigationType == .linkActivated, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if SiftWebController.isX(url) {
            webView.load(navigationAction.request)
        } else if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        problem = nil
        located(webView.url)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return }
        if failure.domain == "WebKitErrorDomain" && failure.code == 102 { return }       // we sent the link to the browser
        problem = "X could not be reached. Check your connection, then reload."
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        problem = "The feed stopped. Reload to pick it back up."
    }
}
