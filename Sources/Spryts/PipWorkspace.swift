import AppKit
import Combine
import SwiftUI

enum PipDestination: Hashable {
    case conversation(String), project(String)
    case scenes, today, chats, projects, connections, team, archive
}

enum PipSheet: Identifiable {
    case newProject, editProject(String), renameConversation(String)
    var id: String {
        switch self {
        case .newProject: return "new-project"
        case .editProject(let id): return "project-" + id
        case .renameConversation(let id): return "conversation-" + id
        }
    }
}

/// Navigation is shared by the native toolbar, sidebar and detail. It never owns a model run.
final class PipNavigation: ObservableObject {
    @Published var destination: PipDestination
    @Published var query = ""
    @Published var searchTick = 0
    @Published var showInspector = false
    @Published var detailWidth: CGFloat = 0
    @Published var sheet: PipSheet?
    let session: ChatSession

    init(session: ChatSession) {
        self.session = session
        destination = session.pipLibrary?.activeConversationID.map(PipDestination.conversation) ?? .today
        if let library = session.pipLibrary, library.error == nil, library.projects.isEmpty,
           library.conversations.count == 1, let chat = library.activeConversation,
           chat.snapshot.draft.isEmpty, chat.snapshot.attachments.isEmpty,
           chat.snapshot.messages.allSatisfy({ $0.hidden || $0.text.isEmpty }) {
            destination = .scenes
        }
    }

    var isConversation: Bool {
        if case .conversation = destination { return true }
        return false
    }

    var title: String {
        switch destination {
        case .conversation(let id): return session.pipLibrary?.conversations.first { $0.id == id }?.title ?? "New Chat"
        case .project(let id): return session.pipLibrary?.projects.first { $0.id == id }?.name ?? "Project"
        case .today: return "Today"
        case .scenes: return "Scenes"
        case .chats: return "All Chats"
        case .projects: return "Projects"
        case .connections: return "Connections"
        case .team: return "Team"
        case .archive: return "Archived Chats"
        }
    }

    func select(_ value: PipDestination?) {
        guard let value else { return }
        if case .conversation(let id) = value {
            if id != session.pipLibrary?.activeConversationID {
                guard session.selectPipConversation(id) else { return }
            }
        }
        destination = value
    }

    func newChat(projectID: String? = nil) {
        guard session.newPipConversation(projectID: projectID), let id = session.pipLibrary?.activeConversationID else { return }
        query = ""
        destination = .conversation(id)
        session.focusTick += 1
    }

    func showCurrentChat() {
        if let id = session.pipLibrary?.activeConversationID { destination = .conversation(id) }
        else { newChat() }
    }

    func focusConversation() {
        guard !isConversation else { return }
        if detailWidth >= 740 { showInspector = true }
        else { showInspector = false; showCurrentChat() }
    }

    func archive(_ chat: PipConversation, archived: Bool) {
        guard session.archivePipConversation(chat.id, archived: archived) else { return }
        if destination == .conversation(chat.id) { showCurrentChat() }
    }
}

struct PipSidebarView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var library: PipLibrary
    @ObservedObject var navigation: PipNavigation
    let tint: Color
    @FocusState private var searching: Bool

    private var chats: [PipConversation] { library.conversations(matching: navigation.query) }
    private var projects: [PipProject] {
        library.projects.filter {
            navigation.query.isEmpty || $0.name.localizedCaseInsensitiveContains(navigation.query)
                || $0.instructions.localizedCaseInsensitiveContains(navigation.query)
        }
    }
    private var selection: Binding<PipDestination?> {
        Binding(get: { navigation.destination }, set: navigation.select)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats and projects", text: $navigation.query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onSubmit { navigation.destination = .chats }
                if !navigation.query.isEmpty {
                    Button { navigation.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 12))
            .padding(9)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

            List(selection: selection) {
                if navigation.query.isEmpty {
                    Section {
                        sidebarItem("Scenes", icon: "square.stack.3d.up", destination: .scenes)
                        sidebarItem("Today", icon: "sun.max", destination: .today)
                        sidebarItem("All Chats", icon: "bubble.left.and.bubble.right", destination: .chats)
                        sidebarItem("Projects", icon: "folder", destination: .projects)
                        sidebarItem("Connections", icon: "app.connected.to.app.below.fill", destination: .connections)
                        sidebarItem("Team", icon: "person.2", destination: .team)
                    }
                }
                if !projects.isEmpty {
                    Section("Projects") {
                        ForEach(projects) { project in
                            Label(project.name, systemImage: "folder")
                                .lineLimit(1).tag(PipDestination.project(project.id))
                                .help(project.name)
                                .contextMenu {
                                    Button("New Chat in Project") { navigation.newChat(projectID: project.id) }
                                        .disabled(session.busy)
                                    Button("Edit Project…") { navigation.sheet = .editProject(project.id) }
                                        .disabled(session.busy)
                                }
                        }
                    }
                }
                if chats.contains(where: \.isPinned) {
                    Section("Pinned") {
                        ForEach(chats.filter(\.isPinned)) { chat in chatRow(chat) }
                    }
                }
                Section(navigation.query.isEmpty ? "Recent Chats" : "Matching Chats") {
                    ForEach(chats.filter { !$0.isPinned }.prefix(navigation.query.isEmpty ? 30 : 100)) { chat in chatRow(chat) }
                    if chats.filter({ !$0.isPinned }).count > (navigation.query.isEmpty ? 30 : 100) {
                        sidebarItem(navigation.query.isEmpty ? "Show All Chats" : "Show All Results",
                                    icon: "ellipsis.bubble", destination: .chats)
                    }
                    if chats.isEmpty {
                        Text(navigation.query.isEmpty ? "Your conversations appear here." : "No matching chats")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Section {
                    sidebarItem("Archived Chats", icon: "archivebox", destination: .archive)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 9) {
                Image(systemName: "sparkle").font(.system(size: 18)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.sheet.name).font(.system(size: 12, weight: .semibold))
                    Text("Chief of Staff").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if session.busy {
                    Button { navigation.showCurrentChat() } label: {
                        Image(systemName: session.approval == nil ? "ellipsis.message" : "hand.raised.fill")
                    }
                    .buttonStyle(.plain)
                    .help(session.approval == nil ? "Go to the running conversation" : "Review pending approval")
                }
            }.padding(14)
        }
        .tint(tint)
        .onChange(of: navigation.searchTick) { searching = true }
    }

    private func sidebarItem(_ title: String, icon: String, destination: PipDestination) -> some View {
        Label(title, systemImage: icon).tag(destination)
    }

    private func chatRow(_ chat: PipConversation) -> some View {
        HStack(spacing: 7) {
            Image(systemName: chat.isPinned ? "pin" : "bubble.left")
                .foregroundStyle(.secondary).font(.system(size: 11))
            Text(chat.title).lineLimit(1)
            Spacer(minLength: 0)
            if chat.id == library.activeConversationID && session.busy {
                Circle().fill(tint).frame(width: 5, height: 5)
            }
        }
        .tag(PipDestination.conversation(chat.id))
        .help(chat.title + "\n" + chat.updatedAt.formatted(date: .abbreviated, time: .shortened))
        .contextMenu { PipChatMenu(session: session, library: library, navigation: navigation, chat: chat) }
        .disabled(session.busy && chat.id != library.activeConversationID)
    }
}

struct PipChatMenu: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var library: PipLibrary
    @ObservedObject var navigation: PipNavigation
    let chat: PipConversation

    var body: some View {
        Group {
            Button("Rename…") { navigation.sheet = .renameConversation(chat.id) }
            Button(chat.isPinned ? "Unpin" : "Pin") { _ = session.pinPipConversation(chat.id, pinned: !chat.isPinned) }
            Menu("Move to Project") {
                Button("No Project") { _ = session.movePipConversation(chat.id, projectID: nil) }
                ForEach(library.projects) { project in
                    Button(project.name) { _ = session.movePipConversation(chat.id, projectID: project.id) }
                }
            }
            Divider()
            Button(chat.isArchived ? "Restore Chat" : "Archive Chat") { navigation.archive(chat, archived: !chat.isArchived) }
        }.disabled(session.busy)
    }
}

struct PipDetailView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var library: PipLibrary
    @ObservedObject var navigation: PipNavigation
    @ObservedObject var shelf: AppShelf
    @ObservedObject var scenes: PipSceneStore
    let team: [ChatSession]
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            if let error = library.error {
                HStack(spacing: 12) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Retry") { session.retryPipPersistence() }.controlSize(.small).disabled(session.busy)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.06))
                Divider()
            }
            if navigation.isConversation {
                conversationHeader
                PipConversationView(session: session, name: session.sheet.name, tint: tint)
            } else {
                HSplitView {
                    destinationContent.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    if navigation.showInspector {
                        VStack(spacing: 0) {
                            HStack {
                                Button { navigation.showCurrentChat() } label: {
                                    Text(library.activeConversation?.title ?? "Chat with " + session.sheet.name).lineLimit(1)
                                }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Button { navigation.showInspector = false } label: { Image(systemName: "sidebar.right") }
                                    .buttonStyle(.borderless).disabled(session.approval != nil)
                                    .help("Hide conversation")
                            }.padding(14)
                            Divider()
                            PipConversationView(session: session, name: session.sheet.name, tint: tint, compact: true)
                        }.frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
                    }
                }
            }
        }
        .background(Surface.text)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { navigation.detailWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) {
                        navigation.detailWidth = geometry.size.width
                        if navigation.showInspector && geometry.size.width < 740 {
                            navigation.showInspector = false
                            navigation.showCurrentChat()
                        }
                    }
            }
        }
        .tint(tint)
        .sheet(item: $navigation.sheet) { item in
            switch item {
            case .newProject:
                PipProjectEditor(session: session, library: library, navigation: navigation, project: nil)
            case .editProject(let id):
                PipProjectEditor(session: session, library: library, navigation: navigation,
                                 project: library.projects.first { $0.id == id })
            case .renameConversation(let id):
                if let chat = library.conversations.first(where: { $0.id == id }) {
                    PipRenameConversation(session: session, navigation: navigation, chat: chat)
                }
            }
        }
        .onChange(of: session.focusTick) {
            navigation.focusConversation()
        }
        .onChange(of: session.approval?.id) {
            if session.approval != nil { navigation.showCurrentChat() }
        }
        .onChange(of: session.busy) {
            if session.busy { navigation.focusConversation() }
        }
        .onChange(of: library.activeConversationID) {
            if navigation.isConversation { navigation.showCurrentChat() }
        }
    }

    private var conversationHeader: some View {
        HStack(spacing: 8) {
            if let project = library.activeProject {
                Button { navigation.destination = .project(project.id) } label: {
                    Label(project.name, systemImage: "folder")
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                Text("Conversation").foregroundStyle(.secondary)
            }
            Spacer()
            if session.busy {
                Label(session.approval == nil ? "Working" : "Needs your approval",
                      systemImage: session.approval == nil ? "circle.dotted" : "hand.raised")
                    .foregroundStyle(.secondary)
            }
            if let chat = library.activeConversation {
                Menu { PipChatMenu(session: session, library: library, navigation: navigation, chat: chat) }
                label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                .help("Conversation actions")
            }
        }.font(.system(size: 12)).padding(.horizontal, 24).frame(height: 42)
    }

    @ViewBuilder private var destinationContent: some View {
        switch navigation.destination {
        case .scenes:
            PipScenesView(session: session, library: library, store: scenes, tint: tint,
                          onStart: startScene, onConnections: { navigation.destination = .connections },
                          onOpenConversation: { navigation.select(.conversation($0)) })
        case .today:
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.stack.3d.up").foregroundStyle(tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("A useful place to start").font(.system(size: 14, weight: .semibold))
                            Text("Prepare your day, get meeting-ready, or bring a project to life.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Explore Scenes") { navigation.destination = .scenes }
                    }.solidCard(corner: 12, padding: 18)
                    TodayView(session: session, office: Office.of(session.sheet.id), name: session.sheet.name, tint: tint)
                    DeskTeamPreview(sessions: team, chiefID: session.sheet.id) { navigation.destination = .team }
                }.padding(28).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
            }
        case .projects:
            projectsView
        case .chats:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(navigation.query.isEmpty ? "All Chats" : "Search Results")
                        .font(.system(size: 25, weight: .bold))
                    let chats = library.conversations(matching: navigation.query)
                    if chats.isEmpty {
                        ContentUnavailableView("No matching conversations", systemImage: "bubble.left.and.bubble.right")
                    } else { conversationList(chats) }
                }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
            }
        case .project(let id):
            if let project = library.projects.first(where: { $0.id == id }) { projectView(project) }
            else { ContentUnavailableView("Project unavailable", systemImage: "folder") }
        case .connections:
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Connections").font(.system(size: 25, weight: .bold))
                    PipConnectionsView(session: session, shelf: shelf, tint: tint,
                                       onScenes: { navigation.destination = .scenes }, onPrepared: {
                        navigation.showCurrentChat()
                        session.focusTick += 1
                    })
                }.padding(28).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
            }
        case .team:
            ScrollView {
                DeskTeamView(sessions: team, chief: session, tint: tint)
                    .padding(28).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
            }
        case .archive:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Archived Chats").font(.system(size: 25, weight: .bold))
                    Text("Your conversations are kept here until you restore them.").foregroundStyle(.secondary)
                    let chats = library.conversations(matching: navigation.query, archived: true)
                    if chats.isEmpty { ContentUnavailableView("No archived chats", systemImage: "archivebox") }
                    else { conversationList(chats) }
                }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
            }
        case .conversation: EmptyView()
        }
    }

    private func startScene(_ scene: PipScene, request: String, projectID: String?, runImmediately: Bool) {
        guard session.preparePipConversation(title: String(scene.name.prefix(100)), request: request,
                                             sceneID: scene.id, projectID: projectID) else { return }
        navigation.showCurrentChat()
        session.focusTick += 1
        if runImmediately { session.send() }
    }

    private var projectsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Projects").font(.system(size: 25, weight: .bold))
                        Text("Keep related chats, instructions, and reference files together.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("New Project", systemImage: "folder.badge.plus") { navigation.sheet = .newProject }
                        .disabled(session.busy)
                }
                if library.projects.isEmpty {
                    ContentUnavailableView {
                        Label("A place for ongoing work", systemImage: "folder")
                    } description: {
                        Text("Create a project for a launch, a trip, a client, or anything you want Pip to keep context on.")
                    } actions: {
                        Button("Create Project…") { navigation.sheet = .newProject }.disabled(session.busy)
                    }.padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                        ForEach(library.projects) { project in
                            Button { navigation.destination = .project(project.id) } label: {
                                VStack(alignment: .leading, spacing: 14) {
                                    Image(systemName: "folder").font(.system(size: 24)).foregroundStyle(tint)
                                    Text(project.name).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                                    Text(project.instructions.isEmpty ? "Add instructions and reference files to give Pip context." : project.instructions)
                                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                                    let count = library.conversations.filter { $0.projectID == project.id && !$0.isArchived }.count
                                    Text("\(count) chat\(count == 1 ? "" : "s") · \(project.contextFiles.count) reference file\(project.contextFiles.count == 1 ? "" : "s")")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                                    .solidCard(corner: 12, padding: 20)
                                    .contentShape(RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 1040, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func projectView(_ project: PipProject) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 28)).foregroundStyle(tint).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(project.name).font(.system(size: 25, weight: .bold))
                        Text("Shared context for every conversation in this project.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit…") { navigation.sheet = .editProject(project.id) }.disabled(session.busy)
                }
                if !project.instructions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "Instructions")
                        Text(project.instructions).font(.system(size: 13)).textSelection(.enabled)
                    }.solidCard(corner: 12, padding: 18)
                }
                if !project.contextFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(text: "Reference files")
                        ForEach(project.contextFiles, id: \.self) { path in
                            HStack(spacing: 9) {
                                let exists = FileManager.default.fileExists(atPath: path)
                                Image(systemName: exists ? "doc" : "exclamationmark.triangle").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12))
                                    if !exists { Text("File unavailable at its saved location").font(.system(size: 11)).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                label: { Image(systemName: "arrow.up.forward.square") }
                                .buttonStyle(.borderless).disabled(!exists).help("Reveal in Finder")
                            }.help(path)
                        }
                    }.solidCard(corner: 12, padding: 18)
                }
                HStack {
                    SectionTitle(text: "Conversations")
                    Spacer()
                    Button("New Chat", systemImage: "square.and.pencil") { navigation.newChat(projectID: project.id) }
                        .disabled(session.busy)
                }
                let chats = library.conversations(matching: "", projectID: project.id)
                if chats.isEmpty {
                    ContentUnavailableView("Start this project’s first conversation", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Pip will use this project’s instructions and reference files."))
                } else { conversationList(chats) }
            }.padding(28).frame(maxWidth: 920, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func conversationList(_ chats: [PipConversation]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(chats) { chat in
                HStack(spacing: 12) {
                    Image(systemName: chat.isPinned ? "pin" : "bubble.left").foregroundStyle(.secondary)
                    Button {
                        if chat.isArchived, !session.archivePipConversation(chat.id, archived: false) { return }
                        navigation.select(.conversation(chat.id))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chat.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(chat.preview.isEmpty ? "No messages yet" : chat.preview)
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(session.busy)
                    Text(chat.updatedAt, style: .date).font(.system(size: 11)).foregroundStyle(.secondary)
                    Menu { PipChatMenu(session: session, library: library, navigation: navigation, chat: chat) }
                    label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }.padding(.vertical, 16)
                Divider()
            }
        }
    }
}

private struct PipProjectEditor: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var library: PipLibrary
    @ObservedObject var navigation: PipNavigation
    let project: PipProject?
    @State private var name = ""
    @State private var instructions = ""
    @State private var files: [URL] = []
    @State private var attemptedSave = false
    @FocusState private var naming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(project == nil ? "New Project" : "Edit Project").font(.system(size: 20, weight: .semibold))
            Form {
                TextField("Name", text: $name).focused($naming)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Instructions").font(.system(size: 12, weight: .medium))
                    Text("What should Pip know or do in every chat in this project?")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    TextEditor(text: $instructions).font(.system(size: 13)).frame(height: 110)
                        .padding(4).background(Surface.text, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Surface.separator, lineWidth: 0.5))
                }.padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Reference files").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("Add Files…", action: addFiles)
                    }
                    Text("Files stay in their original folders. Pip can read them when working in this project.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if !files.isEmpty {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(files, id: \.self) { file in
                                    HStack {
                                        Label(file.lastPathComponent, systemImage: "doc").lineLimit(1)
                                        Spacer()
                                        Button { files.removeAll { $0 == file } } label: { Image(systemName: "minus.circle") }
                                            .buttonStyle(.borderless).help("Remove reference")
                                    }.font(.system(size: 12)).help(file.path)
                                }
                            }
                        }.frame(maxHeight: 120)
                    }
                }
            }.formStyle(.grouped)
            if attemptedSave, let error = library.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { navigation.sheet = nil }.keyboardShortcut(.cancelAction)
                Button(project == nil ? "Create Project" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.busy)
            }
        }.padding(24).frame(width: 540)
        .onAppear {
            name = project?.name ?? ""
            instructions = project?.instructions ?? ""
            files = (project?.contextFiles ?? []).map { URL(fileURLWithPath: $0) }
            naming = true
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.title = "Add Reference Files"
        panel.prompt = "Add References"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !files.contains(url) { files.append(url) }
    }

    private func save() {
        attemptedSave = true
        if let project {
            guard session.updatePipProject(project.id, name: name, instructions: instructions, files: files) else { return }
            navigation.destination = .project(project.id)
        } else {
            guard let id = session.createPipProject(name: name, instructions: instructions, files: files) else { return }
            navigation.destination = .project(id)
        }
        navigation.sheet = nil
    }
}

private struct PipRenameConversation: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var navigation: PipNavigation
    let chat: PipConversation
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Chat").font(.system(size: 18, weight: .semibold))
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            if let error = session.pipLibrary?.error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { navigation.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if session.renamePipConversation(chat.id, title: title) { navigation.sheet = nil }
                }.keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.busy)
            }
        }.padding(24).frame(width: 380).onAppear { title = chat.title }
    }
}

/// AppKit owns the split view and toolbar so resizing, sidebar hiding and window controls behave like macOS.
@MainActor
final class PipSplitController: NSSplitViewController, NSToolbarDelegate {
    private let session: ChatSession
    private let navigation: PipNavigation
    private let library: PipLibrary
    private let scenes: PipSceneStore
    private var observations: Set<AnyCancellable> = []
    private static let newChat = NSToolbarItem.Identifier("Pip.NewChat")
    private static let newProject = NSToolbarItem.Identifier("Pip.NewProject")
    private static let models = NSToolbarItem.Identifier("Pip.Models")
    private static let inspector = NSToolbarItem.Identifier("Pip.Inspector")

    init(session: ChatSession, library: PipLibrary, shelf: AppShelf, team: [ChatSession], tint: Color) {
        self.session = session
        self.library = library
        self.scenes = PipSceneStore(chiefID: session.sheet.id)
        self.navigation = PipNavigation(session: session)
        super.init(nibName: nil, bundle: nil)
        let sidebar = NSHostingController(rootView: PipSidebarView(session: session, library: library, navigation: navigation, tint: tint))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 300
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)
        let detail = NSHostingController(rootView: PipDetailView(session: session, library: library, navigation: navigation,
                                                               shelf: shelf, scenes: scenes, team: team, tint: tint))
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 520
        addSplitViewItem(detailItem)
        splitView.autosaveName = "PipWorkspaceSplit-" + session.sheet.id
        for publisher in [session.objectWillChange.eraseToAnyPublisher(), library.objectWillChange.eraseToAnyPublisher(), navigation.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshWindow() }
            }.store(in: &observations)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func installToolbar(in window: NSWindow) {
        let toolbar = NSToolbar(identifier: "PipWorkspaceToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        refreshWindow()
    }

    private func refreshWindow() {
        guard let window = view.window else { return }
        window.title = navigation.title
        window.subtitle = session.sheet.name + " · Chief of Staff"
        window.toolbar?.validateVisibleItems()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.newChat, Self.newProject, .flexibleSpace, Self.models, Self.inspector]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .toggleSidebar || id == .sidebarTrackingSeparator || id == .flexibleSpace { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        switch id {
        case Self.newChat:
            item.label = "New Chat"
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Chat")
            item.toolTip = "New Chat (⌘N)"
            item.action = #selector(newPipChat(_:))
        case Self.newProject:
            item.label = "New Project"
            item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Project")
            item.toolTip = "New Project (⇧⌘N)"
            item.action = #selector(newPipProject(_:))
        case Self.models:
            item.label = "Engine and Model"
            let host = NSHostingView(rootView: EngineModelMenu(session: session).frame(maxWidth: 230).padding(.horizontal, 4))
            host.frame = NSRect(x: 0, y: 0, width: 230, height: 28)
            item.view = host
        case Self.inspector:
            item.label = "Conversation"
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Show Conversation")
            item.toolTip = "Show Conversation (⌘L)"
            item.action = #selector(focusPipChat(_:))
        default: return nil
        }
        return item
    }

    @objc func newPipChat(_ sender: Any?) {
        if case .project(let id) = navigation.destination { navigation.newChat(projectID: id) }
        else if navigation.isConversation { navigation.newChat(projectID: library.activeProject?.id) }
        else { navigation.newChat() }
    }
    @objc func newPipProject(_ sender: Any?) { if !session.busy { navigation.sheet = .newProject } }
    @objc func searchPipChats(_ sender: Any?) {
        splitViewItems.first?.isCollapsed = false
        navigation.searchTick += 1
    }
    @objc func focusPipChat(_ sender: Any?) {
        navigation.focusConversation()
        session.focusTick += 1
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(newPipChat(_:)) || item.action == #selector(newPipProject(_:)) { return !session.busy }
        if item.action == #selector(searchPipChats(_:)) || item.action == #selector(focusPipChat(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }
}
