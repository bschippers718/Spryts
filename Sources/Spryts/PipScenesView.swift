import AppKit
import SwiftUI

/// Scenes collect a goal and its chosen context. The containing workspace owns
/// the durable conversation transaction and is the only place that starts work.
struct PipScenesView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var library: PipLibrary
    @ObservedObject var store: PipSceneStore
    let tint: Color
    let onStart: (PipScene, String, String?, Bool) -> Void
    let onConnections: () -> Void
    var onOpenConversation: ((String) -> Void)? = nil

    @State private var sheet: SceneSheet?
    @State private var deleting: PipScene?
    @State private var confirmDelete = false

    private var recentConversations: [PipConversation] {
        Array(library.conversations.filter { !$0.isArchived && $0.sceneID != nil }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }.prefix(5))
    }

    private enum SceneSheet: Identifiable {
        case setup(PipScene), editor(PipScene?, copy: Bool)
        var id: String {
            switch self {
            case .setup(let scene): return "setup-" + scene.id
            case .editor(let scene, let copy): return "edit-" + (scene?.id ?? "new") + (copy ? "-copy" : "")
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scenes").font(.system(size: 28, weight: .bold))
                        Text("A starting point for work that brings your apps and Spryts together.")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("New Scene", systemImage: "plus") { sheet = .editor(nil, copy: false) }
                        .buttonStyle(.bordered)
                }
                if let error = store.error { sceneError(error) { _ = store.retry() } }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Made for your day").font(.system(size: 17, weight: .semibold))
                    sceneGrid(PipSceneCatalog.builtIns)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your Scenes").font(.system(size: 17, weight: .semibold))
                    if store.customScenes.isEmpty {
                        HStack(spacing: 16) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 27, weight: .light)).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Make familiar work easier to start.").font(.system(size: 14, weight: .medium))
                                Text("Save your own instructions and reference files, or customize a Scene above.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.solidCard(padding: 20)
                    } else { sceneGrid(store.customScenes) }
                }
                if !recentConversations.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Recent Scene conversations").font(.system(size: 17, weight: .semibold))
                        VStack(spacing: 0) {
                            ForEach(Array(recentConversations.enumerated()), id: \.element.id) { index, chat in
                                if index > 0 { Divider() }
                                if let onOpenConversation {
                                    Button { onOpenConversation(chat.id) } label: { recentConversationRow(chat) }
                                        .buttonStyle(.plain)
                                        .disabled(session.busy && library.activeConversationID != chat.id)
                                        .help("Open \(chat.title)")
                                } else { recentConversationRow(chat) }
                            }
                        }.solidCard(corner: 14, padding: 16)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .tint(tint)
        .sheet(item: $sheet) { item in
            switch item {
            case .setup(let scene):
                PipSceneSetupView(session: session, library: library, scene: scene, tint: tint,
                    onStart: onStart,
                    onCustomize: { sheet = .editor(scene, copy: true) },
                    onConnections: { sheet = nil; onConnections() })
            case .editor(let scene, let copy):
                PipSceneEditorView(store: store, scene: scene, copy: copy, tint: tint)
            }
        }
        .confirmationDialog("Delete Scene?", isPresented: $confirmDelete, presenting: deleting) { scene in
            Button("Delete \(scene.name)", role: .destructive) { _ = store.delete(scene.id) }
        } message: { _ in
            Text("This removes the saved Scene. Its conversations stay in your history.")
        }
    }

    private func sceneGrid(_ scenes: [PipScene]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
            ForEach(scenes) { scene in
                Button { sheet = .setup(scene) } label: {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Image(systemName: scene.symbol)
                                .font(.system(size: 24, weight: .regular)).foregroundStyle(tint)
                                .frame(height: 30)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        Text(scene.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                        Text(scene.outcome).font(.system(size: 13)).foregroundStyle(.secondary)
                            .lineLimit(3).frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                        Divider()
                        HStack(spacing: 5) {
                            Image(systemName: "square.stack.3d.up")
                            Text(scene.desiredApps.isEmpty ? "Choose your context" : scene.desiredApps.joined(separator: " · "))
                                .lineLimit(1).truncationMode(.tail)
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .solidCard(corner: 16, padding: 20)
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .help("Set up \(scene.name)")
                .contextMenu {
                    Button("Set Up Scene…") { sheet = .setup(scene) }
                    Button("Customize a Copy…") { sheet = .editor(scene, copy: true) }
                    if store.customScenes.contains(where: { $0.id == scene.id }) {
                        Divider()
                        Button("Edit Scene…") { sheet = .editor(scene, copy: false) }
                        Button("Delete Scene…", role: .destructive) { deleting = scene; confirmDelete = true }
                    }
                }
            }
        }
    }

    private func recentConversationRow(_ chat: PipConversation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(chat.sceneRunStatus?.label ?? "Conversation")
                    Text("·").accessibilityHidden(true)
                    Text(chat.updatedAt.formatted(.relative(presentation: .named)))
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if onOpenConversation != nil {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct PipSceneSetupView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var library: PipLibrary
    let scene: PipScene
    let tint: Color
    let onStart: (PipScene, String, String?, Bool) -> Void
    let onCustomize: () -> Void
    let onConnections: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var apps: Set<String> = []
    @State private var files: [URL]
    @State private var projectID: String?
    @State private var error: String?
    @State private var showsRequest = false
    @FocusState private var focusedInput: String?

    init(session: ChatSession, library: PipLibrary, scene: PipScene, tint: Color,
         onStart: @escaping (PipScene, String, String?, Bool) -> Void,
         onCustomize: @escaping () -> Void, onConnections: @escaping () -> Void) {
        self.session = session; self.library = library; self.scene = scene; self.tint = tint
        self.onStart = onStart; self.onCustomize = onCustomize; self.onConnections = onConnections
        _files = State(initialValue: scene.referenceFiles.map { URL(fileURLWithPath: $0) })
        _projectID = State(initialValue: library.activeProject?.id)
    }

    private var ready: Bool {
        !session.busy && scene.inputs.filter(\.isRequired).allSatisfy {
            !(values[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    private var selectedApps: [String] { scene.desiredApps.filter { apps.contains($0) } }
    private var request: String? {
        try? PipSceneRequestBuilder.build(scene: scene, inputs: values, apps: selectedApps, files: files)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: scene.symbol).font(.system(size: 28, weight: .light)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(scene.name).font(.system(size: 22, weight: .semibold))
                    Text("Set up your Scene").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Customize…", action: onCustomize).controlSize(.small)
            }.padding(24)
            Divider()
            Form {
                Section("The outcome") {
                    Text(scene.outcome).font(.system(size: 14)).textSelection(.enabled)
                    if let example = sceneExample(scene.id) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Example result").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            Text(example).font(.system(size: 12)).foregroundStyle(.secondary)
                            Text("Illustrative only. Your Scene starts when you choose Start Scene.")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }.padding(.vertical, 4)
                    }
                }
                if !scene.inputs.isEmpty {
                    Section("Make it yours") {
                        ForEach(scene.inputs) { input in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(input.label).font(.system(size: 12, weight: .medium))
                                    if input.isRequired { Text("Required").font(.system(size: 10)).foregroundStyle(.secondary) }
                                }
                                TextField(input.label, text: Binding(
                                    get: { values[input.id] ?? "" }, set: { values[input.id] = $0; error = nil }),
                                    prompt: Text(input.placeholder), axis: .vertical)
                                    .lineLimit(2...4).textFieldStyle(.roundedBorder)
                                    .labelsHidden().focused($focusedInput, equals: input.id)
                            }.padding(.vertical, 4)
                        }
                    }
                }
                Section {
                    if scene.desiredApps.isEmpty {
                        Text("This Scene can start with the context you provide below.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        ForEach(scene.desiredApps, id: \.self) { app in
                            Toggle(app, isOn: Binding(get: { apps.contains(app) }, set: { included in
                                if included { apps.insert(app) } else { apps.remove(app) }
                            }))
                            .toggleStyle(.checkbox)
                        }
                    }
                    Text("Choose the apps or Spryts to include. Selecting an app doesn't connect an account or grant access.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Manage Connections…", action: onConnections).controlSize(.small)
                } header: { Text("Apps & Spryts") }
                Section("Reference files") {
                    sceneFileRows(files: $files)
                    Button("Add Files…", systemImage: "plus") { chooseSceneFiles(into: &files) }
                        .controlSize(.small)
                    Text("Files stay on your Mac. Pip can use the selected files when the Scene runs.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section("Conversation") {
                    Picker("Project", selection: $projectID) {
                        Text("No project").tag(String?.none)
                        ForEach(library.projects) { project in Text(project.name).tag(Optional(project.id)) }
                    }
                    if let project = library.projects.first(where: { $0.id == projectID }) {
                        Text("Includes \(project.name)'s instructions and \(project.contextFiles.count) reference file\(project.contextFiles.count == 1 ? "" : "s").")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Preview request", isExpanded: $showsRequest) {
                        Text(request ?? "Complete the required fields to preview the request.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                            .padding(.vertical, 6)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let message = error ?? library.error {
                    Text(message).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                }
                if session.busy {
                    Text("Pip is working. You can prepare this Scene and start it when the current task finishes.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Open as Draft") { start(immediately: false) }.disabled(!ready)
                    Button("Start Scene") { start(immediately: true) }
                        .buttonStyle(.borderedProminent).disabled(!ready)
                }
            }.padding(20)
        }
        .frame(width: 580, height: 640)
        .tint(tint)
        .defaultFocus($focusedInput, scene.inputs.first?.id)
        .task { await Task.yield(); focusedInput = scene.inputs.first?.id }
    }

    private func start(immediately: Bool) {
        guard ready else { return }
        do {
            let prompt = try PipSceneRequestBuilder.build(scene: scene, inputs: values, apps: selectedApps, files: files)
            error = nil
            onStart(scene, prompt, projectID, immediately)
        } catch { self.error = error.localizedDescription }
    }
}

private struct PipSceneEditorDraft: Equatable {
    struct Input: Identifiable, Equatable {
        var id: String
        var label: String
        var placeholder: String
        var isRequired: Bool
    }
    var name: String
    var outcome: String
    var instructions: String
    var apps: String
    var files: [URL]
    var inputs: [Input]
    var symbol: String

    init(scene: PipScene?, copy: Bool) {
        name = scene.map { $0.name + (copy ? " Copy" : "") } ?? ""
        outcome = scene?.outcome ?? ""
        instructions = scene?.instructions ?? ""
        apps = scene?.desiredApps.joined(separator: ", ") ?? ""
        files = scene?.referenceFiles.map { URL(fileURLWithPath: $0) } ?? []
        inputs = scene?.inputs.map { Input(id: $0.id, label: $0.label, placeholder: $0.placeholder, isRequired: $0.isRequired) } ?? []
        symbol = scene?.symbol ?? "sparkles"
    }
}

private struct PipSceneEditorView: View {
    @ObservedObject var store: PipSceneStore
    let scene: PipScene?
    let copy: Bool
    let tint: Color
    private let original: PipSceneEditorDraft
    @State private var draft: PipSceneEditorDraft
    @State private var discard = false
    @State private var saveError: String?
    @State private var attemptedSave = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var naming: Bool

    init(store: PipSceneStore, scene: PipScene?, copy: Bool, tint: Color) {
        self.store = store; self.scene = scene; self.copy = copy; self.tint = tint
        let initial = PipSceneEditorDraft(scene: scene, copy: copy)
        original = initial; _draft = State(initialValue: initial)
    }

    private var isDirty: Bool { draft != original }
    private var isEditing: Bool { scene != nil && !copy }
    private var canSave: Bool {
        [draft.name, draft.outcome, draft.instructions].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && draft.inputs.allSatisfy { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit Scene" : "New Scene").font(.system(size: 22, weight: .semibold))
                Spacer()
                Image(systemName: draft.symbol).font(.system(size: 26, weight: .light)).foregroundStyle(tint)
            }.padding(24)
            Divider()
            Form {
                Section("The idea") {
                    TextField("Name", text: $draft.name).focused($naming)
                    TextField("Outcome", text: $draft.outcome, axis: .vertical).lineLimit(2...3)
                    Text("Describe what a successful run should produce.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("Icon", selection: $draft.symbol) {
                        ForEach(sceneSymbols, id: \.self) { symbol in
                            Image(systemName: symbol).tag(symbol)
                        }
                        if !sceneSymbols.contains(draft.symbol) { Image(systemName: draft.symbol).tag(draft.symbol) }
                    }.pickerStyle(.menu)
                }
                Section("Instructions") {
                    TextEditor(text: $draft.instructions).font(.system(size: 13)).frame(height: 120)
                        .accessibilityLabel("Scene instructions")
                    Text("Tell Pip how to approach the work, what to deliver, and when to bring in other Spryts.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section("Questions to ask before starting") {
                    ForEach($draft.inputs) { $input in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Question", text: $input.label, prompt: Text("Question or field name")).labelsHidden()
                                Button { draft.inputs.removeAll { $0.id == input.id } } label: {
                                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                                }.buttonStyle(.borderless).accessibilityLabel("Remove input")
                            }
                            TextField("Hint", text: $input.placeholder, prompt: Text("Hint or example")).labelsHidden()
                            Toggle("Required", isOn: $input.isRequired).toggleStyle(.checkbox)
                                .font(.system(size: 11))
                        }.padding(.vertical, 4)
                    }
                    Button("Add Question", systemImage: "plus") {
                        draft.inputs.append(.init(id: UUID().uuidString, label: "", placeholder: "", isRequired: false))
                    }.controlSize(.small)
                }
                Section("Suggested apps & Spryts") {
                    TextField("Suggested apps", text: $draft.apps, prompt: Text("For example: Calendar, Mail, Nova"), axis: .vertical)
                        .lineLimit(2...3).labelsHidden()
                    Text("Separate names with commas. People choose which to include each time they start the Scene.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section("Reference files") {
                    sceneFileRows(files: $draft.files)
                    Button("Add Files…", systemImage: "plus") { chooseSceneFiles(into: &draft.files) }
                        .controlSize(.small)
                }
            }.formStyle(.grouped)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let saveError {
                    HStack(alignment: .top, spacing: 10) {
                        Text(saveError).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                        if store.hasPendingWrite { Button("Retry Save", action: retrySave).controlSize(.small) }
                    }
                }
                HStack {
                    Button("Cancel") { if isDirty { discard = true } else { cancel() } }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(isEditing ? "Save Changes" : "Create Scene", action: save)
                        .buttonStyle(.borderedProminent).disabled(!canSave).keyboardShortcut(.defaultAction)
                }
            }.padding(20)
        }
        .frame(width: 580, height: 640)
        .tint(tint)
        .interactiveDismissDisabled(isDirty)
        .defaultFocus($naming, true)
        .task { await Task.yield(); naming = true }
        .onChange(of: draft) {
            if attemptedSave && store.hasPendingWrite {
                store.discardPendingWrite()
                saveError = nil
            }
        }
        .alert("Discard your changes?", isPresented: $discard) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard Changes", role: .destructive, action: cancel)
        } message: { Text("Your changes to this Scene haven't been saved.") }
    }

    private func save() {
        guard canSave else { return }
        attemptedSave = true
        var seen: Set<String> = []
        let apps = draft.apps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        let inputs = draft.inputs.map {
            PipSceneInput(id: $0.id, label: $0.label, placeholder: $0.placeholder, isRequired: $0.isRequired)
        }
        let saved: Bool
        if let scene, isEditing {
            saved = store.update(scene.id, name: draft.name, outcome: draft.outcome, instructions: draft.instructions,
                desiredApps: apps, referenceFiles: draft.files, inputs: inputs, symbol: draft.symbol)
        } else {
            saved = store.create(name: draft.name, outcome: draft.outcome, instructions: draft.instructions,
                desiredApps: apps, referenceFiles: draft.files, inputs: inputs, symbol: draft.symbol) != nil
        }
        if saved { dismiss() }
        else { saveError = store.error ?? "The Scene couldn't be saved. Your changes are still here." }
    }

    private func retrySave() {
        let wasPending = store.hasPendingWrite
        if store.retry() {
            saveError = nil
            if wasPending { dismiss() }
        } else { saveError = store.error }
    }

    private func cancel() {
        if attemptedSave { store.discardPendingWrite() }
        dismiss()
    }
}

private let sceneSymbols = ["sparkles", "sun.max", "person.2", "folder", "doc.text", "bubble.left.and.bubble.right", "calendar", "tray", "hammer", "pencil"]

private func sceneExample(_ id: String) -> String? {
    switch id {
    case "starter.start-my-day": return "Three priorities, the commitments that matter, and room to focus."
    case "starter.meeting-ready": return "A concise brief, useful questions, and the decisions to aim for."
    case "starter.project-launch": return "A clear plan with owners, first steps, and a review point."
    case "starter.paperwork-sorted": return "An organized checklist of documents, missing information, and next steps."
    case "starter.social-studio": return "A focused X post, a thoughtful reply draft, and ideas worth developing."
    default: return nil
    }
}

@ViewBuilder
private func sceneFileRows(files: Binding<[URL]>) -> some View {
    if files.wrappedValue.isEmpty {
        Text("No reference files selected").font(.system(size: 12)).foregroundStyle(.secondary)
    }
    ForEach(files.wrappedValue, id: \.self) { file in
        HStack(spacing: 8) {
            Image(systemName: "doc").foregroundStyle(.secondary)
            Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle).help(file.path)
            Spacer()
            Button { files.wrappedValue.removeAll { $0 == file } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }.buttonStyle(.borderless).accessibilityLabel("Remove \(file.lastPathComponent)")
        }.font(.system(size: 12))
    }
}

private func chooseSceneFiles(into files: inout [URL]) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true; panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true; panel.prompt = "Add"
    panel.message = "Choose reference files for this Scene."
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
        let file = url.standardizedFileURL
        if !files.contains(file) { files.append(file) }
    }
}

private func sceneError(_ message: String, retry: @escaping () -> Void) -> some View {
    HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        Text(message).font(.system(size: 12)).textSelection(.enabled)
        Spacer(minLength: 8)
        Button("Retry", action: retry).controlSize(.small)
    }.solidCard(corner: 12)
}
