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
final class SiftWebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var signedOut = false
    @Published private(set) var onFeed = true
    @Published private(set) var problem: String?
    @Published var showFilters = false
    /// True while the Google or Apple sign-in window is open.
    @Published private(set) var signingIn = false
    private var signInPanel: NSPanel?
    private var signInView: WKWebView?

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

    /// Posts read from the page for a brief, and whether Sift filtered them.
    struct FeedSample: Equatable {
        let posts: [SiftPost]
        let filtered: Bool
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

    /// Reads posts for Brief: prefers Sift's kept registry, and falls back to visible `<article>` posts
    /// when X's layout prevents Sift from matching `article[data-testid="tweet"]`.
    func briefPosts() async -> FeedSample {
        let kept = await keptPosts()
        if !kept.isEmpty { return FeedSample(posts: kept, filtered: true) }
        guard engine != nil else { return FeedSample(posts: [], filtered: false) }
        let json: String = await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript("return globalThis.__siftBridge ? globalThis.__siftBridge.visiblePosts(limit) : \"[]\";",
                                        arguments: ["limit": SiftEvidence.maximumPosts], in: nil, in: world) { result in
                if case .success(let value) = result, let text = value as? String {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(returning: "[]")
                }
            }
        }
        return FeedSample(posts: SiftPost.parse(json), filtered: false)
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
        if webView !== self.webView {
            // The sign-in window: Google, Apple and X only. Anything else simply does not load.
            return SiftWebController.isSignIn(url) || SiftWebController.isX(url) || url.absoluteString == "about:blank" ? .allow : .cancel
        }
        if SiftWebController.isX(url) || url.absoluteString == "about:blank" { return .allow }
        if navigationAction.navigationType == .linkActivated, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        let blank = url == nil || url?.absoluteString.isEmpty == true || url?.absoluteString == "about:blank"
        if webView === self.webView, blank || url.map({ SiftWebController.isSignIn($0) }) == true {
            // "Sign in with Google" and "Sign in with Apple" open a small window and hand the result back to the page
            // that opened them. That only works if the window is ours, so it opens here, not in the browser.
            return openSignIn(with: configuration)
        }
        guard let url else { return nil }
        if SiftWebController.isX(url) {
            self.webView.load(navigationAction.request)
        } else if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    /// The places a sign-in window may go besides X itself.
    static func isSignIn(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return ["accounts.google.com", "accounts.youtube.com", "appleid.apple.com", "idmsa.apple.com"].contains(host)
    }

    /// A small window for the sign-in page. WebKit links it to the feed, so the result reaches X when it closes.
    private func openSignIn(with configuration: WKWebViewConfiguration) -> WKWebView {
        closeSignIn()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 660), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 660),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Sign in to X"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.contentView = view
        panel.delegate = self
        if let parent = webView.window {
            let frame = parent.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 250, y: frame.midY - 330))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        signInPanel = panel
        signInView = view
        signingIn = true
        return view
    }

    func closeSignIn() {
        guard let panel = signInPanel else { return }
        signInPanel = nil
        signInView = nil
        signingIn = false
        panel.delegate = nil
        panel.orderOut(nil)
    }

    /// The sign-in page closed itself: it is done.
    func webViewDidClose(_ webView: WKWebView) {
        if webView === signInView { closeSignIn() }
    }

    /// The person closed the sign-in window.
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSPanel) === signInPanel { closeSignIn() }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Always show whose page the sign-in window is on.
        if webView === signInView, let host = webView.url?.host { signInPanel?.title = "Sign in · " + host }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        problem = nil
        located(webView.url)
        checkReading()
    }

    // MARK: Can Sift read the page

    private var readingCheck = 0
    /// The last report is kept beside the other logs. The checks turn this off.
    static var keepsReports = true
    static let cannotRead = "Sift can’t read this page, so posts are unfiltered."

    /// A while after the feed loads, asks the page whether Sift is reading the posts on it.
    /// The answer is counts and element names, never a post. It is kept in one small file for fixing a bad page.
    private func checkReading() {
        readingCheck += 1
        let mine = readingCheck
        guard engine != nil else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard let self, self.readingCheck == mine, self.onFeed, !self.signedOut else { return }
            guard var report = await self.readingReport(), self.readingCheck == mine else { return }
            let healthy = SiftWebController.reads(report)
            report["healthy"] = healthy
            if !healthy {
                self.problem = SiftWebController.cannotRead
            } else if self.problem == SiftWebController.cannotRead {
                self.problem = nil
            }
            if SiftWebController.keepsReports,
               let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: Config.home.appendingPathComponent("sift-health.log"), options: .atomic)
            }
        }
    }

    /// What the page says about itself: how many posts are on it and how many Sift has read.
    func readingReport() async -> [String: Any]? {
        guard engine != nil else { return nil }
        let json: String? = await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript("return globalThis.__siftBridge ? await globalThis.__siftBridge.health() : '';",
                                        arguments: [:], in: nil, in: world) { result in
                if case .success(let value) = result, let text = value as? String, !text.isEmpty {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let json, json.utf8.count <= 20_000 else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }

    /// Sift is reading the page when its own pass finishes and every post on the page went through it.
    static func reads(_ report: [String: Any]) -> Bool {
        func number(_ key: String) -> Int { (report[key] as? NSNumber)?.intValue ?? 0 }
        if let error = report["error"] as? String, !error.isEmpty { return false }
        if number("articles") > 0 { return number("read") >= number("articles") }
        if number("anyArticle") > 0 || number("roleArticle") > 0 { return number("read") > 0 }
        return number("cells") < 3          // an empty timeline is fine; a full one with no posts Sift knows is not
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return }
        if failure.domain == "WebKitErrorDomain" && failure.code == 102 { return }       // we sent the link to the browser
        problem = "X could not be reached. Check your connection, then reload."
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        problem = "The feed stopped. Reload to pick it back up."
    }
}
