import AppKit
import SwiftUI
import WebKit

// The X Feed pane in Pip's workspace. The web view and its rules are in PipSiftWeb.swift.

private struct SiftWebView: NSViewRepresentable {
    let controller: SiftWebController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

// MARK: - The pane

struct PipSiftView: View {
    @ObservedObject var session: ChatSession
    let tint: Color
    var onPrepared: () -> Void

    @StateObject private var controller: SiftWebController
    @ObservedObject private var store: SiftStore
    @State private var showBrief = false
    @State private var confirmSignOut = false

    init(session: ChatSession, tint: Color, onPrepared: @escaping () -> Void) {
        self.session = session
        self.tint = tint
        self.onPrepared = onPrepared
        let shared = SiftWebController.of(session.sheet.id)
        _controller = StateObject(wrappedValue: shared)
        _store = ObservedObject(wrappedValue: shared.store)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice {
                Label(notice.text, systemImage: notice.symbol)
                    .font(.system(size: 12)).foregroundStyle(notice.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Surface.card)
                Divider()
            }
            ZStack(alignment: .top) {
                SiftWebView(controller: controller)
                if controller.loading {
                    ProgressView().progressViewStyle(.linear).tint(tint).frame(height: 2)
                        .accessibilityLabel("Loading")
                }
            }
        }
        .background(Surface.text)
        .onAppear { controller.start() }
        .onDisappear { controller.rest() }
        .confirmationDialog("Sign out of X in Spryts?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { controller.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This forgets the X sign-in kept by Spryts. Your browsers stay signed in, and your feed settings are kept.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if controller.canGoBack {
                Button { controller.goBack() } label: { Image(systemName: "chevron.backward") }
                    .buttonStyle(.borderless).help("Back")
                    .keyboardShortcut("[", modifiers: .command)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(store.settings.feedName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if !controller.onFeed && !controller.signedOut {
                Button("Back to Feed") { controller.openFeed() }.controlSize(.small)
            }
            Button { showBrief = true } label: { Label("Brief", systemImage: "text.line.first.and.arrowtriangle.forward") }
                .buttonStyle(.borderedProminent).tint(tint).controlSize(.small)
                .disabled(controller.engine == nil || controller.signedOut || session.busy)
                .help("Ask \(session.sheet.name) for a brief of the posts Sift kept")
                .popover(isPresented: $showBrief, arrowEdge: .bottom) {
                    SiftBriefView(session: session, controller: controller, tint: tint) {
                        showBrief = false
                        onPrepared()
                    }
                }
            Button { controller.showFilters = true } label: { Label("Filters", systemImage: "line.3.horizontal.decrease") }
                .controlSize(.small)
                .disabled(controller.engine == nil)
                .popover(isPresented: $controller.showFilters, arrowEdge: .bottom) {
                    if let engine = controller.engine {
                        SiftFiltersView(store: store, engine: engine, tint: tint)
                    }
                }
            Menu {
                Button("Reload") { controller.reload() }.keyboardShortcut("r", modifiers: .command)
                Button("Open in Browser") { controller.openInBrowser() }
                Divider()
                Button(store.settings.enabled ? "Pause Sift" : "Resume Sift") {
                    store.update { $0.enabled.toggle() }
                }.disabled(controller.engine == nil)
                Divider()
                Button("Sign Out of X…") { confirmSignOut = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("More")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// One quiet line: where the posts come from and what is being held back.
    private var status: String {
        let source = store.settings.listURL == nil ? "Home" : "X List"
        let filters = store.settings.summary
        if filters.isEmpty { return source + " · Add topics or a List in Filters" }
        return ([source] + filters.prefix(3)).joined(separator: " · ")
    }

    private var notice: (text: String, symbol: String, warning: Bool)? {
        if let problem = controller.engineProblem {
            return (problem + " X is shown without filtering.", "exclamationmark.triangle", true)
        }
        if let problem = controller.problem { return (problem, "wifi.exclamationmark", true) }
        if let problem = store.error { return (problem, "exclamationmark.triangle", true) }
        if controller.signedOut {
            return ("Sign in to X with your username and password. Sign in with Google or Apple isn’t available inside Spryts.",
                    "person.crop.circle", false)
        }
        return nil
    }
}

// MARK: - Brief

private struct SiftBriefView: View {
    @ObservedObject var session: ChatSession
    let controller: SiftWebController
    let tint: Color
    var onSent: () -> Void

    @State private var focus = ""
    @State private var count: Int?
    @State private var working = false
    @State private var failure: String?

    private var engineName: String {
        session.engine == "codex" ? "OpenAI Codex" : (session.engine == "grok" ? "Grok" : "Claude Code")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Brief from \(session.sheet.name)").font(.system(size: 14, weight: .semibold))
            TextField("What do you want from it? (optional)", text: $focus, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder)
                .onSubmit(ask)
            Text(explanation).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Ask \(session.sheet.name)", action: ask)
                    .buttonStyle(.borderedProminent).tint(tint)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || session.busy || count == 0)
            }
        }
        .padding(16).frame(width: 340)
        .task { count = await controller.keptPosts().count }
    }

    private var explanation: String {
        let posts: String
        switch count {
        case .none: posts = "The latest posts Sift kept"
        case .some(0): return "Sift hasn’t kept any posts yet. Scroll the feed, then try again."
        case .some(1): posts = "The latest post Sift kept"
        case .some(let number): posts = "The latest \(number) posts Sift kept"
        }
        return posts + " will be sent to \(engineName) so \(session.sheet.name) can read them. Nothing is posted, liked or followed."
    }

    private func ask() {
        guard !working, !session.busy else { return }
        working = true
        failure = nil
        Task { @MainActor in
            defer { working = false }
            let posts = await controller.keptPosts()
            do {
                let settings = controller.store.settings
                let request = try SiftEvidence.build(posts: posts, feed: settings.feedName, readAt: Date(),
                                                     filters: settings.summary, focus: focus)
                guard session.preparePipConversation(title: "X Brief · " + settings.feedName, request: request) else {
                    failure = "\(session.sheet.name) couldn’t start a new chat. Finish or save the current one, then try again."
                    return
                }
                onSent()
                session.send()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

// MARK: - Filters

/// Sift's settings as a Mac form. Every control writes straight through; the feed updates as you go.
private struct SiftFiltersView: View {
    @ObservedObject var store: SiftStore
    let engine: SiftEngine
    let tint: Color

    var body: some View {
        Form {
            Section {
                Toggle("Sift", isOn: flag(\.enabled))
            } footer: {
                Text("Turn off to see X as it comes.")
            }

            Section("Where posts come from") {
                TextField("Feed name", text: text(\.profileName), prompt: Text("My Feed"))
                TextField("X List", text: text(\.feedUrl), prompt: Text("https://x.com/i/lists/…"))
                listStatus
            }

            Section("What belongs") {
                if !engine.packs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Starter packs")
                        FlowRow(spacing: 6) {
                            ForEach(engine.packs) { pack in
                                let applied = engine.isApplied(pack, topics: store.settings.topicKeywords)
                                Button {
                                    store.update { $0 = engine.applying(pack, to: $0) }
                                } label: {
                                    Label(pack.name, systemImage: applied ? "checkmark" : "plus")
                                }
                                .capsuleButton(tint: tint, prominent: applied)
                                .disabled(applied)
                                .help(applied ? "\(pack.name) is in your topics" : pack.blurb)
                            }
                        }
                    }
                }
                entries("Topics", \.topicKeywords, hint: "One per line.")
                Toggle("Only show posts about my topics", isOn: flag(\.requireTopicMatch))
            }

            Section("Remove the noise") {
                entries("Blocked phrases", \.mutedKeywords, hint: "One per line. Posts containing any of these are hidden.")
                Toggle("Hide promoted posts", isOn: flag(\.hidePromoted))
                Toggle("Hide reposts", isOn: flag(\.hideReposts))
                Toggle("Hide quote posts", isOn: flag(\.hideQuotes))
                Toggle(isOn: flag(\.hidePostsWithoutLinks)) {
                    Text("Hide posts without links")
                    Text("Mentions, hashtags and links within X do not count.")
                }
            }

            Section("Accounts") {
                entries("Always show", \.trustedHandles, hint: "One @handle per line. These skip the topic filter.")
                entries("Never show", \.hiddenHandles, hint: "One @handle per line.")
                Stepper(value: Binding(get: { store.settings.maxPostsPerAuthor },
                                       set: { value in store.update { $0.maxPostsPerAuthor = value } }),
                        in: 0...SiftSettings.maximumPerAuthor) {
                    Text("Posts per account")
                    Text(store.settings.maxPostsPerAuthor == 0 ? "No limit" : "At most \(store.settings.maxPostsPerAuthor), so one account can’t take over.")
                }
            }

            Section("How X looks") {
                Toggle(isOn: flag(\.defaultToFollowing)) {
                    Text("Open Following")
                    Text("Switch away from For You when Home opens.")
                }
                Toggle(isOn: flag(\.distractionFree)) {
                    Text("Focus layout")
                    Text("Hides the side columns so the feed has the window.")
                }
            }
        }
        .formStyle(.grouped)
        .tint(tint)
        .frame(width: 440, height: 580)
    }

    @ViewBuilder private var listStatus: some View {
        let value = store.settings.feedUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            Text("Paste an X List address for the cleanest feed. Leave it empty to use Home.")
                .font(.footnote).foregroundStyle(.secondary)
        } else if store.settings.listURL == nil {
            Label("That isn’t an X List address. It looks like https://x.com/i/lists/123.", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.orange)
        } else {
            Label("Using this List", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func flag(_ path: WritableKeyPath<SiftSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings[keyPath: path] }, set: { value in store.update { $0[keyPath: path] = value } })
    }

    private func text(_ path: WritableKeyPath<SiftSettings, String>) -> Binding<String> {
        Binding(get: { store.settings[keyPath: path] }, set: { value in store.update { $0[keyPath: path] = value } })
    }

    private func entries(_ title: String, _ path: WritableKeyPath<SiftSettings, String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                let count = SiftSettings.entries(store.settings[keyPath: path]).count
                if count > 0 { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            }
            TextEditor(text: text(path))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 74)
                .background(Surface.text, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Surface.separator, lineWidth: 0.5))
                .accessibilityLabel(title)
            Text(hint).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
