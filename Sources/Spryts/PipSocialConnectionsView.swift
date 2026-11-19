import AppKit
import SwiftUI

private struct PipSocialNetwork: Identifiable {
    let id: String
    let name: String
    let detail: String
    let setup: URL

    static let services = [
        PipSocialNetwork(id: "linkedin", name: "LinkedIn", detail: "Professional posts and launch drafts. Account access depends on the connected service.",
                         setup: URL(string: "https://learn.microsoft.com/en-us/linkedin/consumer/integrations/self-serve/share-on-linkedin")!),
        PipSocialNetwork(id: "instagram", name: "Instagram", detail: "Visual campaigns for business and creator accounts. Requires an approved integration.",
                         setup: URL(string: "https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/")!),
        PipSocialNetwork(id: "threads", name: "Threads", detail: "Conversations and post drafts through an authorized Threads integration.",
                         setup: URL(string: "https://developers.facebook.com/docs/threads/")!),
        PipSocialNetwork(id: "bluesky", name: "Bluesky", detail: "Community research and post drafts through a connected service.",
                         setup: URL(string: "https://docs.bsky.app/docs/advanced-guides/oauth-client")!)
    ]
}

/// A network's website, its engine tools and its authenticated account are distinct surfaces.
/// Only the native X adapter can show its verified account here.
struct PipSocialConnectionsView: View {
    @ObservedObject var session: ChatSession
    let tint: Color
    var onPrepared: () -> Void
    @ObservedObject private var x = PipXConnection.shared
    @State private var showingX = false
    @State private var showingNetworks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(text: "Social networks")
            HStack(spacing: 14) {
                Text("𝕏").font(.system(size: 29, weight: .medium))
                    .frame(width: 44, height: 44).background(Surface.card, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text("X / Twitter").font(.system(size: 15, weight: .semibold))
                    Text(x.account.map { "Signed in as @" + $0.username } ?? "Mentions, your posts, and conversation research")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(x.account == nil ? "Set Up X…" : "Open X…") { showingX = true }
                    .controlSize(.small)
            }
            Text("Bring selected posts into a conversation with Pip to find themes, prepare replies, and develop your next post.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            DisclosureGroup("More networks", isExpanded: $showingNetworks) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("These networks need a service configured in your selected engine. Opening a setup guide doesn’t connect an account.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(PipSocialNetwork.services) { network in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "network").foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(network.name).font(.system(size: 13, weight: .medium))
                                Text(network.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            Link("Setup Guide", destination: network.setup).font(.system(size: 12))
                        }
                    }
                }.padding(.top, 12)
            }.font(.system(size: 12, weight: .medium))
        }
        .solidCard(corner: 12, padding: 18)
        .sheet(isPresented: $showingX) {
            PipXWorkspaceView(session: session, connection: x, tint: tint) {
                showingX = false
                onPrepared()
            }
        }
    }
}

private struct PipXWorkspaceView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var connection: PipXConnection
    let tint: Color
    let onPrepared: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var showDeveloperSetup = false
    @State private var feed = PipXFeed.mentions
    @State private var query = ""
    @State private var selected = Set<String>()
    @State private var task = "Summarize the conversation"
    @State private var brief = ""
    @State private var showingDisconnect = false
    @State private var preparationError: String?

    private let tasks = ["Summarize the conversation", "Draft thoughtful replies", "Develop post ideas"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("𝕏").font(.system(size: 27))
                VStack(alignment: .leading, spacing: 3) {
                    Text("X Workspace").font(.system(size: 19, weight: .semibold))
                    Text(connection.account.map { $0.name + " · @" + $0.username } ?? "Connect your account to work with real conversations.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if connection.isWorking { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(connection.isWorking)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = connection.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if connection.account == nil { signIn }
                    else { accountWorkspace }
                }.padding(22)
            }
            if connection.account != nil {
                Divider()
                handoff.padding(20)
            }
        }
        .frame(width: 780, height: 690)
        .background(Surface.text)
        .tint(tint)
        .interactiveDismissDisabled(connection.isWorking)
        .onAppear { clientID = connection.configuredClientID }
        .onChange(of: connection.posts.map(\.id)) { selected = Set(connection.posts.map(\.id)) }
        .confirmationDialog("Disconnect X from this Mac?", isPresented: $showingDisconnect) {
            Button("Disconnect", role: .destructive) { connection.disconnect() }
        } message: {
            Text("This removes the saved sign-in from Spryts. You can also revoke Spryts in your X account’s connected-app settings.")
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your network, with context").font(.system(size: 25, weight: .semibold))
                Text("Read your latest mentions, revisit your own posts, or research a topic. Choose what to bring to Pip, then shape a useful response together.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Label("Read-only access", systemImage: "eye")
                Label("Sign-in saved in Keychain", systemImage: "key")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            Text("X API reads use the developer app’s API credits. Fetches are manual and limited to 10 posts at a time.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("Sign In with X") { connection.connect(clientID: clientID) }
                    .buttonStyle(.borderedProminent)
                    .disabled(connection.isWorking || clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Restore Saved Sign-In") { connection.restoreSavedConnection() }
                    .disabled(connection.isWorking)
                Button("Remove Saved Sign-In…") { showingDisconnect = true }
                    .disabled(connection.isWorking)
            }
            if clientID.isEmpty {
                Text("X sign-in hasn’t been configured for this build yet. The developer setup below is required before customers can connect.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            DisclosureGroup("Developer setup", isExpanded: $showDeveloperSetup) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Register Spryts as an X Native App with OAuth 2.0. Add the exact callback below to that app’s settings, then provide its public client ID. No client secret belongs in this Mac app.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("spryts-auth://oauth/x").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    TextField("Public client ID", text: $clientID).textFieldStyle(.roundedBorder)
                        .disabled(connection.isWorking)
                    HStack {
                        Link("X App Settings", destination: URL(string: "https://console.x.com/")!)
                        Link("Authentication Guide", destination: URL(string: "https://docs.x.com/fundamentals/authentication/oauth-2-0/authorization-code")!)
                        Link("API Usage", destination: URL(string: "https://docs.x.com/x-api/getting-started/pricing")!)
                    }.font(.system(size: 11))
                }.padding(.top, 12)
            }.font(.system(size: 12, weight: .medium))
        }
    }

    private var accountWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Show", selection: $feed) {
                    ForEach(PipXFeed.allCases) { feed in Text(feed.title).tag(feed) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 370)
                Spacer()
                Button("Disconnect…") { showingDisconnect = true }.controlSize(.small).disabled(connection.isWorking)
            }
            if feed == .search {
                TextField("Search X for a topic, phrase, or account", text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit { if canLoad { fetch() } }
            }
            HStack {
                Text("Fetch up to 10 posts · Uses X API credits")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Fetch Posts", systemImage: "arrow.clockwise", action: fetch)
                    .disabled(!canLoad)
            }
            if let fetched = connection.fetchedAt {
                Text(connection.feedLabel + " · Fetched " + fetched.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if connection.posts.isEmpty {
                ContentUnavailableView(connection.fetchedAt == nil ? "Choose a view, then fetch posts" : "No posts returned",
                                       systemImage: "text.bubble", description: Text(connection.fetchedAt == nil
                                        ? "Results appear here after a request. No feeds run in the background."
                                        : "Try another view or a different search. No feeds run in the background."))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(connection.posts) { post in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("Include post", isOn: Binding(get: { selected.contains(post.id) }, set: { include in
                                if include { selected.insert(post.id) } else { selected.remove(post.id) }
                            })).toggleStyle(.checkbox).labelsHidden().padding(.top, 2)
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(post.author).font(.system(size: 12, weight: .semibold))
                                    if let date = post.createdAt { Text(date, style: .date).font(.system(size: 11)).foregroundStyle(.secondary) }
                                    Spacer()
                                    Link(destination: post.url) { Image(systemName: "arrow.up.right") }
                                        .help("Open original post on X")
                                }
                                Text(post.text).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                            }
                        }.padding(.vertical, 16)
                        Divider()
                    }
                }
            }
        }
    }

    private var canLoad: Bool {
        !connection.isWorking && (feed != .search || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func fetch() { connection.load(feed, query: query) }

    private var handoff: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("With Pip", selection: $task) { ForEach(tasks, id: \.self) { Text($0) } }.frame(maxWidth: 320)
                Spacer()
                Text("\(selected.count) selected").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            TextField("Add a goal or context (optional)", text: $brief).textFieldStyle(.roundedBorder)
            HStack(alignment: .center, spacing: 16) {
                Text("Selected posts will go into a new conversation using \(session.engineLabel). Replies and posts remain drafts.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Ask Pip", action: askPip).buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || session.busy || connection.isWorking)
            }
            if let error = session.pipLibrary?.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            if let error = preparationError { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
        }
    }

    private func askPip() {
        let posts = connection.posts.filter { selected.contains($0.id) }
        guard !posts.isEmpty, let fetchedAt = connection.fetchedAt, let account = connection.account else { return }
        preparationError = nil
        do {
            let request = try PipXEvidence.build(posts: posts.map {
                .init(id: $0.id, author: $0.author, text: $0.text, url: $0.url, createdAt: $0.createdAt)
            }, account: .init(id: account.id, name: account.name, username: account.username),
                feedLabel: connection.feedLabel, fetchedAt: fetchedAt, task: task, brief: brief)
            guard session.preparePipConversation(title: "Social Studio · X", request: request,
                                                 sceneID: "starter.social-studio") else { return }
            onPrepared()
            session.send()
        } catch {
            preparationError = error.localizedDescription
        }
    }
}
