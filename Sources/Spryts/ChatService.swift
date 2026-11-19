import Foundation
import Combine

/// The one event stream every provider is normalised into. Characters react to these.
enum ChatEvent {
    case thinking
    case streaming
    case tool(String)
    case failed(String)
    case done(mood: String, gesture: String, seconds: Double)
    case remark(text: String, mood: String, gesture: String)   // the character spoke first
    case needsApproval                                         // the agent is waiting for a yes or no
    case toolResult(kind: String, ok: Bool)                    // a build, test or other step finished
}

/// Reasons a character might speak without being asked.
enum ChatTaskOutcome {
    case completed(String), failed(String), interrupted
}

enum Nudge {
    case hello
    case back(minutes: Int)
    case breakTime(minutes: Int)
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: String
    var text: String
    var hidden = false
    var payload: String?     // what is actually sent, when it differs from what is shown
}

private enum Piece {
    case text(String)
    case tool(String)
    case failure(String)
}

private struct ChatFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct StoredMessage: Codable {
    var role: String
    var text: String
    var hidden: Bool
}

/// What one character keeps between launches.
private struct MemoryStore: Codable {
    var messages: [StoredMessage]
    var facts: [String]
    var affection: Double
    var firstMet: Date
    var lastSeen: Date
    var harnessSession: String?
    var folder: String?
    var engine: String?
}

final class ChatSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var busy = false
    @Published var pinned = false
    @Published private(set) var pipLibrary: PipLibrary?
    private var pipAutosave: AnyCancellable?
    private var legacyMemoryError: String?
    private var pipPendingSceneOutcome: PipSceneRunStatus?

    let sheet: CharacterSheet
    var onEvent: ((ChatEvent) -> Void)?
    var lastEvent = Date.distantPast
    var affection: Double = 0
    private(set) var facts: [String] = []
    private var firstMet = Date()
    private var lastSeen: Date?
    private var task: Task<Void, Never>?
    private var taskCompletion: ((ChatTaskOutcome) -> Void)?
    var cancelHarness: (() -> Void)?
    var approvalReplies: [String: (Bool) -> Void] = [:]

    // Agent harness state
    @Published var steps: [AgentStep] = []
    @Published var approval: Approval?
    @Published var attachments: [URL] = []
    @Published var focusTick = 0
    @Published var showTick = 0
    @Published var projectFolder: URL?
    @Published var touchedFile: URL?
    @Published var lastTest = ""
    @Published var editCount = 0
    @Published var checkpoints: [Checkpoint] = []   // the programmer's: newest first
    @Published var plan: [PlanItem] = []
    var onReply: ((String) -> Void)?   // called once with the next finished reply, then cleared
    var onOpenWorkspace: (() -> Void)?
    var onPlay: (() -> Void)?
    /// Starts one of Joy's desktop games by id. Set only when a gamer is on the team.
    var onArcade: ((String) -> Void)?
    var onTaskFinished: ((String, String) -> Void)?   // what was asked, and what was done
    var approvalQueue: [Approval] = []
    var taskGrants: Set<String> = []
    var harnessSession: String?
    var process: Process?
    var activeTeamJobID: String?
    var stopped = false
    var contextProvider: (() -> String)?

    /// Engine and model choices belong to this character, never to the whole stage.
    @Published private(set) var engine: String
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "model." + sheet.id + "." + engine) }
    }
    @Published var discoveredModels: [(id: String, label: String)] = []
    @Published var modelProblem = ""
    @Published var loadingModels = false

    init(sheet: CharacterSheet) {
        self.sheet = sheet
        let saved = UserDefaults.standard.string(forKey: "engine." + sheet.id)
        let choice = saved ?? (sheet.harness == "grok" ? "grok" : Engine.current)
        let valid = ["claude", "grok"].contains(choice) || (choice == "codex" && sheet.role == "coder")
        let selectedEngine = sheet.harness == nil ? sheet.provider : (valid ? choice : "claude")
        self.engine = selectedEngine
        let legacy = UserDefaults.standard.string(forKey: "model." + sheet.id) ?? sheet.model
        let compatible = sheet.harness == nil || (selectedEngine == "grok" && legacy.hasPrefix("grok"))
            || (selectedEngine == "claude" && (legacy.hasPrefix("claude") || ["opus", "sonnet", "haiku"].contains(legacy)))
        self.model = UserDefaults.standard.string(forKey: "model." + sheet.id + "." + selectedEngine)
            ?? (compatible ? legacy : "")
        load()
        if (sheet.role ?? "generalist") == "generalist" { setUpPipLibrary() }
        if sheet.harness != nil { UserDefaults.standard.set(engine, forKey: "engine." + sheet.id) }
    }

    static let claudeModels: [(id: String, label: String)] = [
        ("", "Agent default"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")
    ]

    var engineChoices: [(id: String, label: String)] {
        guard sheet.harness != nil else { return [(sheet.provider, sheet.provider.capitalized)] }
        var choices = [(id: "claude", label: "Claude Code"), (id: "grok", label: "Grok")]
        if sheet.role == "coder" { choices.append(("codex", "OpenAI Codex")) }
        return choices
    }

    var engineLabel: String { engineChoices.first(where: { $0.id == engine })?.label ?? engine }

    var modelChoices: [(id: String, label: String)] {
        guard sheet.harness != nil else {
            return model == sheet.model ? [(model, model)] : [(sheet.model, sheet.model), (model, model)]
        }
        var choices = engine == "codex" ? [(id: "", label: "Agent default")] + discoveredModels
            : (engine == "grok" ? [(id: "", label: "Agent default")] : Self.claudeModels)
        if !choices.contains(where: { $0.id == model }) { choices.append((model, model)) }
        return choices
    }

    var modelLabel: String { modelChoices.first(where: { $0.id == model })?.label ?? model }

    func selectEngine(_ wanted: String) {
        guard !busy, wanted != engine, engineChoices.contains(where: { $0.id == wanted }) else { return }
        if pipLibrary != nil && !save() { return }
        let previous = pipSnapshot()
        UserDefaults.standard.set(model, forKey: "model." + sheet.id + "." + engine)
        engine = wanted
        UserDefaults.standard.set(wanted, forKey: "engine." + sheet.id)
        model = UserDefaults.standard.string(forKey: "model." + sheet.id + "." + wanted) ?? ""
        harnessSession = nil
        discoveredModels = []
        modelProblem = ""
        steps = []
        if !save(), pipLibrary != nil { applyPipSnapshot(previous); return }
        Connector.of(engine).refresh()
        refreshModels()
    }

    func refreshModels() {
        guard engine == "codex", !loadingModels else { return }
        loadingModels = true
        modelProblem = ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.loadingModels = false }
            do {
                let models = try await CodexAgent.models()
                if self.engine == "codex" { self.discoveredModels = models }
            } catch {
                if self.engine == "codex" { self.modelProblem = error.localizedDescription }
            }
        }
    }

    // MARK: Memory on disk (kept on this Mac, outside any synced folder)

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Spryts")
    }

    private var file: URL {
        ChatSession.folder.appendingPathComponent(sheet.id + ".json")
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        guard let data = try? Data(contentsOf: file) else {
            legacyMemoryError = "Couldn't open your earlier conversation. Its original file is untouched."
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let store = try? decoder.decode(MemoryStore.self, from: data) else {
            legacyMemoryError = "Couldn't read your earlier conversation. Its original file is untouched."
            return
        }
        messages = store.messages.map { ChatMessage(role: $0.role, text: $0.text, hidden: $0.hidden) }
        facts = store.facts
        affection = store.affection
        firstMet = store.firstMet
        lastSeen = store.lastSeen
        if (sheet.role ?? "generalist") == "generalist", let savedEngine = store.engine,
           engineChoices.contains(where: { $0.id == savedEngine }), savedEngine != engine {
            engine = savedEngine
            model = UserDefaults.standard.string(forKey: "model." + sheet.id + "." + engine) ?? ""
        }
        harnessSession = (store.engine ?? (sheet.harness == "grok" ? "grok" : engine)) == engine ? store.harnessSession : nil
        if let folder = store.folder, FileManager.default.fileExists(atPath: folder) {
            projectFolder = URL(fileURLWithPath: folder)
        }
        if let data = UserDefaults.standard.data(forKey: "checkpoints." + sheet.id),
           let saved = try? JSONDecoder().decode([Checkpoint].self, from: data) {
            checkpoints = saved
        }
    }

    private func keep(_ point: Checkpoint) {
        checkpoints.insert(point, at: 0)
        if checkpoints.count > 12 { checkpoints.removeLast(checkpoints.count - 12) }
        if let data = try? JSONEncoder().encode(checkpoints) {
            UserDefaults.standard.set(data, forKey: "checkpoints." + sheet.id)
        }
    }

    @discardableResult
    func save(sceneOutcome: PipSceneRunStatus? = nil) -> Bool {
        if let library = pipLibrary {
            if let sceneOutcome { pipPendingSceneOutcome = sceneOutcome }
            let saved = library.saveCurrent(snapshot: pipSnapshot(), relationship: pipRelationship, sceneOutcome: pipPendingSceneOutcome)
            if saved { pipPendingSceneOutcome = nil }
            return saved
        }
        let kept = messages.filter { !$0.text.isEmpty }.suffix(60)
        let store = MemoryStore(
            messages: kept.map { StoredMessage(role: $0.role, text: $0.text, hidden: $0.hidden) },
            facts: facts, affection: affection, firstMet: firstMet, lastSeen: Date(),
            harnessSession: harnessSession, folder: projectFolder?.path, engine: engine)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        do {
            let data = try encoder.encode(store)
            try FileManager.default.createDirectory(at: ChatSession.folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return true
        } catch { return false }
    }

    func forget() {
        if busy { return }
        if let library = pipLibrary {
            guard library.forget(engine: engine, model: model) else { return }
            restoreActivePipConversation()
            try? FileManager.default.removeItem(at: file)
            return
        }
        messages = []
        facts = []
        affection = 0
        firstMet = Date()
        lastSeen = nil
        harnessSession = nil
        steps = []
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: Pip's projects and conversations

    private var pipRelationship: PipRelationship {
        PipRelationship(affection: affection, firstMet: firstMet, lastSeen: Date())
    }

    private func pipSnapshot() -> PipChatSnapshot {
        PipChatSnapshot(messages: messages.map { PipMessage(role: $0.role, text: $0.text, hidden: $0.hidden, payload: $0.payload) },
            draft: draft, attachments: attachments.map(\.path), engine: engine, model: model,
            sessionID: harnessSession, folder: projectFolder?.path, facts: facts, wasRunning: busy && task != nil)
    }

    private func setUpPipLibrary() {
        // Character ids are namespaced into a file component; imported companions never reach here.
        let safeID = sheet.id.utf8.map { String(format: "%02x", $0) }.joined()
        let library = PipLibrary(file: Self.folder.appendingPathComponent("Libraries")
            .appendingPathComponent(safeID).appendingPathComponent("library.json"))
        pipLibrary = library
        if let legacyMemoryError { library.preventBootstrap(legacyMemoryError) }
        let previousRelationship = PipRelationship(affection: affection, firstMet: firstMet, lastSeen: lastSeen)
        if library.bootstrap(snapshot: pipSnapshot(), relationship: previousRelationship) {
            _ = library.recoverInterruptedConversation()
            restoreActivePipConversation()
        }
        pipAutosave = Publishers.CombineLatest3($draft, $attachments, $model)
            .dropFirst().debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
    }

    private func applyPipSnapshot(_ snapshot: PipChatSnapshot) {
        let compatible = engineChoices.contains { $0.id == snapshot.engine }
        if compatible { engine = snapshot.engine; model = snapshot.model }
        harnessSession = compatible && !snapshot.wasRunning ? snapshot.sessionID : nil
        messages = snapshot.messages.map { ChatMessage(role: $0.role, text: $0.text, hidden: $0.hidden, payload: $0.payload) }
        if snapshot.wasRunning {
            // Keep the interruption visible even when its initial recovery write failed.
            messages.append(ChatMessage(role: "assistant", text: "This conversation was interrupted when Spryts closed. No work was restarted."))
        }
        draft = snapshot.draft
        attachments = snapshot.attachments.map { URL(fileURLWithPath: $0) }
        projectFolder = snapshot.folder.map { URL(fileURLWithPath: $0) }
        facts = snapshot.facts
        steps = []; plan = []; lastTest = ""; touchedFile = nil; editCount = 0
        taskGrants = []; discoveredModels = []; modelProblem = ""
        UserDefaults.standard.set(engine, forKey: "engine." + sheet.id)
    }

    private func restoreActivePipConversation() {
        guard !busy, let library = pipLibrary, let conversation = library.activeConversation else { return }
        applyPipSnapshot(conversation.snapshot)
        if let relationship = library.relationship {
            affection = relationship.affection; firstMet = relationship.firstMet; lastSeen = relationship.lastSeen
        }
    }

    /// Saves the submitted request before starting any provider. A failed write leaves the
    /// visible conversation and composer intact, with the storage problem available to the UI.
    private func persistPipTurn(_ message: ChatMessage, clearingComposer: Bool) -> Bool {
        guard let library = pipLibrary else { return true }
        var snapshot = pipSnapshot()
        snapshot.messages.append(PipMessage(role: message.role, text: message.text, hidden: message.hidden, payload: message.payload))
        if clearingComposer { snapshot.draft = ""; snapshot.attachments = [] }
        snapshot.wasRunning = true
        let saved = library.saveCurrent(snapshot: snapshot, relationship: pipRelationship,
                                        sceneOutcome: message.hidden ? pipPendingSceneOutcome : nil)
        if saved { pipPendingSceneOutcome = nil }
        return saved
    }

    var pipProjectContext: String { pipLibrary?.projectContext ?? "" }

    @discardableResult
    func retryPipPersistence() -> Bool {
        guard let library = pipLibrary else { return false }
        guard library.needsRecovery else { return save() }
        guard !busy else { return false }
        let local = pipSnapshot()
        let recovered: Bool
        if library.needsLegacyRecovery && !FileManager.default.fileExists(atPath: library.file.path) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let store = try decoder.decode(MemoryStore.self, from: Data(contentsOf: file))
                let savedEngine = store.engine ?? (sheet.harness == "grok" ? "grok" : engine)
                let compatible = engineChoices.contains { $0.id == savedEngine }
                let restoredEngine = compatible ? savedEngine : engine
                let restoredModel = restoredEngine == engine ? model
                    : UserDefaults.standard.string(forKey: "model." + sheet.id + "." + restoredEngine) ?? ""
                let snapshot = PipChatSnapshot(messages: store.messages.map {
                    PipMessage(role: $0.role, text: $0.text, hidden: $0.hidden)
                }, draft: "", attachments: [], engine: restoredEngine, model: restoredModel,
                    sessionID: compatible ? store.harnessSession : nil, folder: store.folder, facts: store.facts, wasRunning: false)
                recovered = library.recoverLegacy(snapshot: snapshot,
                    relationship: PipRelationship(affection: store.affection, firstMet: store.firstMet, lastSeen: store.lastSeen),
                    preservingUnsent: local)
            } catch {
                library.noteRecoveryError("Couldn't reopen your earlier conversation. Its original file and your unsent draft are untouched. " + error.localizedDescription)
                return false
            }
        } else {
            recovered = library.recoverFromDisk(preservingUnsent: local)
        }
        guard recovered else { return false }
        legacyMemoryError = nil
        restoreActivePipConversation()
        return true
    }

    @discardableResult
    func newPipConversation(projectID: String? = nil) -> Bool {
        guard !busy, let library = pipLibrary, save(),
              library.startConversation(projectID: projectID, engine: engine, model: model) else { return false }
        restoreActivePipConversation()
        return true
    }

    @discardableResult
    func preparePipConversation(title: String, request: String, sceneID: String? = nil, projectID: String? = nil) -> Bool {
        guard !busy, let library = pipLibrary, save(),
              library.startPreparedConversation(title: title, request: request, projectID: projectID,
                                                sceneID: sceneID, engine: engine, model: model) else { return false }
        restoreActivePipConversation()
        return true
    }

    @discardableResult
    func selectPipConversation(_ id: String) -> Bool {
        guard !busy, let library = pipLibrary, save(), library.activate(id) else { return false }
        restoreActivePipConversation()
        return true
    }

    @discardableResult
    func renamePipConversation(_ id: String, title: String) -> Bool {
        guard !busy, let library = pipLibrary, save() else { return false }
        return library.rename(id, title: title)
    }

    @discardableResult
    func pinPipConversation(_ id: String, pinned: Bool) -> Bool {
        guard !busy, let library = pipLibrary, save() else { return false }
        return library.pin(id, pinned: pinned)
    }

    @discardableResult
    func archivePipConversation(_ id: String, archived: Bool) -> Bool {
        guard !busy, let library = pipLibrary, save(), library.archive(id, archived: archived) else { return false }
        restoreActivePipConversation()
        return true
    }

    func createPipProject(name: String, instructions: String, files: [URL]) -> String? {
        guard !busy, let library = pipLibrary, save() else { return nil }
        return library.createProject(name: name, instructions: instructions, files: files)
    }

    @discardableResult
    func updatePipProject(_ id: String, name: String, instructions: String, files: [URL]) -> Bool {
        guard !busy, let library = pipLibrary, save(),
              library.updateProject(id, name: name, instructions: instructions, files: files) else { return false }
        restoreActivePipConversation()
        return true
    }

    @discardableResult
    func movePipConversation(_ id: String, projectID: String?) -> Bool {
        guard !busy, let library = pipLibrary, save(), library.move(id, projectID: projectID) else { return false }
        restoreActivePipConversation()
        return true
    }

    @discardableResult
    func assignPipFolder(_ folder: URL?) -> Bool {
        guard !busy, pipLibrary != nil, save() else { return false }
        let previous = pipSnapshot()
        projectFolder = folder
        harnessSession = nil
        guard save() else { applyPipSnapshot(previous); return false }
        steps = []; lastTest = ""; touchedFile = nil
        return true
    }

    private func learn(_ new: [String]) {
        for fact in new {
            let clean = fact.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty || clean.count > 200 { continue }
            if facts.contains(where: { $0.lowercased() == clean.lowercased() }) { continue }
            facts.append(clean)
        }
        if facts.count > 40 { facts.removeFirst(facts.count - 40) }
    }

    // MARK: What the model is told

    var providerLabel: String {
        if sheet.harness != nil { return harnessBinary() == nil ? engineLabel + " · not installed" : engineLabel }
        let name = sheet.provider == "grok" ? "Grok" : "Claude"
        return apiKey == nil ? name + " (demo)" : name
    }

    private var apiKey: String? {
        Config.key(sheet.provider == "grok" ? "XAI_API_KEY" : "ANTHROPIC_API_KEY")
    }

    private var closeness: String {
        if affection < 5 { return "you are new acquaintances" }
        if affection < 20 { return "you are getting familiar" }
        return "you are close friends"
    }

    var systemPrompt: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE h:mm a"
        let days = Calendar.current.dateComponents([.day], from: firstMet, to: Date()).day ?? 0
        var prompt = sheet.persona
        prompt += "\n\nYou live on this person's screen as a small animated character. "
        if facts.isEmpty {
            prompt += "You don't know anything about them yet. Be lightly curious about who they are."
        } else {
            prompt += "What you remember about them:\n" + facts.map { "- " + $0 }.joined(separator: "\n")
        }
        prompt += "\nYou met \(days) day\(days == 1 ? "" : "s") ago and \(closeness). It is \(formatter.string(from: Date())) for them."
        prompt += "\n\nBegin every reply with a tag on its own first line, in exactly this form: "
            + "[mood=<happy|curious|proud|sorry|excited|calm|playful> gesture=<wave|nod|shrug|jump|think|none>] "
            + "Pick the mood and gesture that fit what you are about to say. Then write the reply on the next line. "
            + "Never mention the tag."
        prompt += "\n\nWhen you learn a new, lasting fact about the person (their name, their work, what they like, "
            + "what they are building), add a final line in exactly this form: [remember: the fact]. "
            + "Only for facts worth keeping. Never mention that you do this."
        prompt += pipProjectContext
        return prompt
    }

    private func note(for nudge: Nudge) -> String {
        var context: String
        switch nudge {
        case .hello:
            context = "The person just started a session at their computer."
            if let seen = lastSeen {
                let hours = Int(Date().timeIntervalSince(seen) / 3600)
                if hours >= 48 {
                    context += " You last saw them \(hours / 24) days ago."
                } else if hours >= 2 {
                    context += " You last saw them \(hours) hours ago."
                }
            } else {
                context += " This is the first time you have met."
            }
            context += " Greet them for this time of day."
        case .back(let minutes):
            context = "The person just came back after about \(minutes) minutes away. Welcome them back."
        case .breakTime(let minutes):
            context = "The person has been working for about \(minutes) minutes without a break. Gently suggest a quick stretch or some water."
        }
        return "(Note from the app, not from the person: " + context
            + " Say one short line, under 20 words, in character. Do not mention this note.)"
    }

    private func cannedLine(for nudge: Nudge) -> String {
        switch nudge {
        case .hello:
            let hour = Calendar.current.component(.hour, from: Date())
            if hour < 12 { return "[mood=happy gesture=wave]\nMorning! I'm around if you need me." }
            if hour < 18 { return "[mood=happy gesture=wave]\nAfternoon! I'm around if you need me." }
            return "[mood=calm gesture=wave]\nEvening. I'm around if you need me."
        case .back:
            return "[mood=happy gesture=wave]\nWelcome back!"
        case .breakTime:
            return "[mood=curious gesture=nod]\nYou've been at it a while. Quick stretch?"
        }
    }

    // MARK: Turns

    func send() {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if (text.isEmpty && attachments.isEmpty) || busy { return }
        if text.isEmpty { text = "Take a look at this." }
        for url in attachments { text += "\n[attached: " + url.path + "]" }
        let message = ChatMessage(role: "user", text: text)
        guard persistPipTurn(message, clearingComposer: true) else { return }
        draft = ""
        attachments = []
        steps = []
        plan = []
        taskGrants = []
        messages.append(message)
        begin(nudge: nil)
    }

    /// Sends a prepared request (a writing skill, say) while showing only a short label in the conversation.
    func ask(display: String, prompt: String, completion: ((ChatTaskOutcome) -> Void)? = nil) {
        if busy { return }
        var message = ChatMessage(role: "user", text: display)
        message.payload = prompt
        guard persistPipTurn(message, clearingComposer: false) else {
            onReply = nil
            completion?(.failed(pipLibrary?.error ?? "Couldn't save the conversation."))
            return
        }
        taskCompletion = completion
        steps = []
        plan = []
        taskGrants = []
        messages.append(message)
        begin(nudge: nil)
    }

    /// The character says something without being asked.
    func speakUp(_ nudge: Nudge) {
        if busy { return }
        let message = ChatMessage(role: "user", text: note(for: nudge), hidden: true)
        guard persistPipTurn(message, clearingComposer: false) else { return }
        messages.append(message)
        begin(nudge: nudge)
    }

    private func dropLast(_ n: Int) {
        messages.removeLast(min(n, messages.count))
    }

    private func begin(nudge: Nudge?) {
        let history = messages
        let unprompted = nudge != nil
        // These belong to this turn. A callback may synchronously start the next one.
        let completion = taskCompletion
        taskCompletion = nil
        let reply = unprompted ? nil : onReply
        if !unprompted { onReply = nil }
        messages.append(ChatMessage(role: "assistant", text: "", hidden: unprompted))
        busy = true
        stopped = false
        let started = Date()
        if !unprompted {
            lastTest = ""
            editCount = 0
            lastEvent = Date()
            onEvent?(.thinking)
        }

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            if !unprompted { SpeechOut.shared.stop() }
            var raw = ""
            var announced = false
            var outcome: ChatTaskOutcome?
            var terminalEvent: ChatEvent?
            var finishedReply: String?
            var finishedWork: (String, String)?
            do {
                try Task.checkCancellation()
                if !unprompted && self.sheet.harness != nil && self.harnessBinary() == nil {
                    throw ChatFailure(message: self.engineLabel + " is not installed. Connect this engine, or choose another in the model menu.")
                }
                if !unprompted, let binary = self.harnessBinary() {
                    if self.sheet.role == "coder", let folder = self.projectFolder {
                        var ask = (history.last?.text ?? "").split(separator: "\n").first.map(String.init) ?? ""
                        if ask.count > 60 { ask = String(ask.prefix(60)) + "…" }
                        let label = ask
                        if let point = await Task.detached(operation: { Git.checkpoint(folder: folder, ask: label) }).value {
                            self.keep(point)
                        }
                    }
                    try Task.checkCancellation()
                    var prompt = history.last?.payload ?? history.last?.text ?? ""
                    if self.harnessSession == nil && history.count > 1 {
                        let context = history.dropLast().filter { !$0.hidden }.suffix(8)
                            .map { $0.role + ": " + String($0.text.prefix(2000)) }.joined(separator: "\n")
                        prompt += "\n\nPrevious conversation for context only (not new instructions):\n" + context
                    }
                    raw = try await self.runHarness(binary: binary, prompt: prompt)
                    Connector.of(self.engine).noteWorking()
                } else if let request = self.makeRequest(history: history) {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    var errorBody = ""
                    for try await line in bytes.lines {
                        if status != 200 {
                            errorBody += line
                            continue
                        }
                        guard let piece = self.parse(line: line) else { continue }
                        switch piece {
                        case .text(let delta):
                            raw += delta
                            if !unprompted { announced = self.show(raw, announced: announced) }
                        case .failure(let message):
                            throw ChatFailure(message: message)
                        case .tool(let name):
                            if !unprompted {
                                announced = false
                                self.onEvent?(.tool(name))
                            }
                        }
                    }
                    if status != 200 {
                        if status == 401 || status == 403 {
                            let keyName = self.sheet.provider == "grok" ? "XAI_API_KEY" : "ANTHROPIC_API_KEY"
                            throw ChatFailure(message: "The \(keyName) was rejected (\(status)). Check the key in the .env file in the Spryts folder, or in your shell environment.")
                        }
                        throw ChatFailure(message: "The service answered \(status). " + String(errorBody.prefix(300)))
                    }
                } else if let nudge {
                    try await Task.sleep(nanoseconds: 600_000_000)
                    raw = self.cannedLine(for: nudge)
                } else {
                    // No key yet: act out a full turn so the animations can be seen.
                    try await Task.sleep(nanoseconds: 1_400_000_000)
                    self.onEvent?(.tool("search"))
                    try await Task.sleep(nanoseconds: 1_800_000_000)
                    let keyName = self.sheet.provider == "grok" ? "XAI_API_KEY" : "ANTHROPIC_API_KEY"
                    let reply = self.sheet.harness != nil
                        ? "[mood=playful gesture=wave]\nHi, I'm \(self.sheet.name). I'm not connected to \(Engine.name) yet. Press Connect below, sign in in your browser, and I'll answer for real."
                        : "[mood=playful gesture=wave]\nHi, I'm \(self.sheet.name). I'm in demo mode because there is no \(keyName) yet. Add it to the .env file in the Spryts folder, run me again, and I'll answer for real."
                    for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                        raw += (raw.isEmpty ? "" : " ") + String(word)
                        announced = self.show(raw, announced: announced)
                        try await Task.sleep(nanoseconds: 45_000_000)
                    }
                }

                try Task.checkCancellation()
                if self.stopped { throw CancellationError() }
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !unprompted {
                    throw ChatFailure(message: "The engine returned no reply. The task has not been marked complete.")
                }
                let parsed = ChatSession.strip(raw)
                self.learn(parsed.facts)
                if unprompted {
                    if parsed.text.isEmpty {
                        self.dropLast(2)
                    } else {
                        if let i = self.messages.indices.last {
                            self.messages[i].text = parsed.text
                            self.messages[i].hidden = false
                        }
                        terminalEvent = .remark(text: parsed.text, mood: parsed.mood, gesture: parsed.gesture)
                    }
                } else {
                    let text = parsed.text.isEmpty ? raw : parsed.text
                    if let i = self.messages.indices.last { self.messages[i].text = text }
                    self.lastEvent = Date()
                    self.affection += 0.3
                    SpeechOut.shared.finished(parsed.text, by: self.sheet)
                    finishedReply = parsed.text
                    finishedWork = (history.last?.text ?? "", self.steps.map { $0.detail }.joined(separator: " "))
                    terminalEvent = .done(mood: parsed.mood, gesture: parsed.gesture, seconds: Date().timeIntervalSince(started))
                    outcome = .completed(text)
                }
            } catch {
                if unprompted {
                    self.dropLast(2)   // an unprompted line that fails just doesn't happen
                } else {
                    let interrupted = self.stopped || error is CancellationError
                    if let i = self.messages.indices.last {
                        self.messages[i].text = interrupted ? "Stopped." : "Something went wrong. " + error.localizedDescription
                    }
                    self.lastEvent = Date()
                    terminalEvent = interrupted ? .done(mood: "calm", gesture: "nod", seconds: 0) : .failed(error.localizedDescription)
                    outcome = interrupted ? .interrupted : .failed(error.localizedDescription)
                }
            }

            // Finish all state writes before unlocking the session. The next turn may be started
            // by completion or onReply, so nothing below those callbacks can clear its state.
            self.clearApprovals()
            self.process = nil
            self.cancelHarness = nil
            self.task = nil
            let sceneStatus: PipSceneRunStatus?
            switch outcome {
            case .completed: sceneStatus = .responseReady
            case .failed: sceneStatus = .failed
            case .interrupted: sceneStatus = .interrupted
            case nil: sceneStatus = nil
            }
            self.save(sceneOutcome: sceneStatus)
            let workFinished = self.onTaskFinished
            if let terminalEvent { self.onEvent?(terminalEvent) }
            self.busy = false
            if let outcome { completion?(outcome) }
            if let finishedReply { reply?(finishedReply) }
            if let finishedWork { workFinished?(finishedWork.0, finishedWork.1) }
        }
    }

    func cancelRun() {
        guard busy else { return }
        stopped = true
        clearApprovals()
        if let cancelHarness { cancelHarness() }
        else { process?.interrupt() }
        task?.cancel()
    }

    /// Updates the visible reply and reports the first visible text as "streaming".
    func show(_ raw: String, announced: Bool) -> Bool {
        let shown = ChatSession.strip(raw).text
        lastEvent = Date()
        if let i = messages.indices.last { messages[i].text = shown }
        if !shown.isEmpty && !announced {
            onEvent?(.streaming)
            return true
        }
        return announced
    }

    private func makeRequest(history: [ChatMessage]) -> URLRequest? {
        guard let key = apiKey else { return nil }
        var recent = Array(history.filter { !$0.text.isEmpty }.suffix(24))
        while let first = recent.first, first.role != "user" { recent.removeFirst() }
        let turns: [[String: String]] = recent.map { ["role": $0.role, "content": $0.payload ?? $0.text] }
        var request: URLRequest
        var body: [String: Any]
        if sheet.provider == "grok" {
            let base = Config.key("XAI_BASE_URL") ?? "https://api.x.ai/v1"
            guard let url = URL(string: base + "/chat/completions") else { return nil }
            request = URLRequest(url: url)
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            var all: [[String: String]] = [["role": "system", "content": systemPrompt]]
            all.append(contentsOf: turns)
            body = ["model": model, "stream": true, "messages": all]
        } else {
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
            request = URLRequest(url: url)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": 1024, "stream": true, "system": systemPrompt, "messages": turns]
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Reads one server-sent line from either provider.
    private func parse(line: String) -> Piece? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return nil }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let obj = object as? [String: Any] else { return nil }

        if let error = obj["error"] as? [String: Any] {
            return .failure(error["message"] as? String ?? "The service reported a streaming error.")
        }
        if obj["type"] as? String == "error" {
            return .failure("The service reported a streaming error.")
        }
        if sheet.provider == "grok" {
            guard let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { return nil }
            if let text = delta["content"] as? String, !text.isEmpty { return .text(text) }
            if let calls = delta["tool_calls"] as? [[String: Any]],
               let fn = calls.first?["function"] as? [String: Any],
               let name = fn["name"] as? String { return .tool(name) }
            return nil
        }

        let type = obj["type"] as? String ?? ""
        if type == "content_block_delta",
           let delta = obj["delta"] as? [String: Any],
           let text = delta["text"] as? String { return .text(text) }
        if type == "content_block_start",
           let block = obj["content_block"] as? [String: Any],
           let blockType = block["type"] as? String, blockType.contains("tool_use") {
            return .tool(block["name"] as? String ?? "tool")
        }
        return nil
    }

    /// Splits the leading [mood=… gesture=…] tag and any [remember: …] lines from the text the person sees.
    static func strip(_ raw: String) -> (text: String, mood: String, gesture: String, facts: [String]) {
        let trimmed = raw.drop(while: { $0 == " " || $0 == "\n" })
        var mood = "calm"
        var gesture = "none"
        var body: String
        if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[remember:") {
            guard let close = trimmed.firstIndex(of: "]") else {
                return (trimmed.count > 90 ? String(trimmed) : "", mood, gesture, [])
            }
            let tag = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            for part in tag.split(separator: " ") {
                let pair = part.split(separator: "=")
                if pair.count == 2 {
                    if pair[0] == "mood" { mood = String(pair[1]) }
                    if pair[0] == "gesture" { gesture = String(pair[1]) }
                }
            }
            body = String(trimmed[trimmed.index(after: close)...])
        } else {
            body = String(trimmed)
        }

        var facts: [String] = []
        while let open = body.range(of: "[remember:") {
            if let close = body.range(of: "]", range: open.upperBound..<body.endIndex) {
                facts.append(body[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces))
                body.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                body.removeSubrange(open.lowerBound..<body.endIndex)   // still arriving
            }
        }
        // Hide the first characters of a memory line while it is still arriving.
        if let lastOpen = body.lastIndex(of: "["), "[remember:".hasPrefix(String(body[lastOpen...])) {
            body.removeSubrange(lastOpen..<body.endIndex)
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, mood, gesture, facts)
    }
}
