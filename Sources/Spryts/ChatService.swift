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
}

final class ChatSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var busy = false
    @Published var pinned = false

    let sheet: CharacterSheet
    var onEvent: ((ChatEvent) -> Void)?
    var lastEvent = Date.distantPast
    var affection: Double = 0
    private(set) var facts: [String] = []
    private var firstMet = Date()
    private var lastSeen: Date?
    private var task: Task<Void, Never>?

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
    var onOpenWorkspace: (() -> Void)?
    var onPlay: (() -> Void)?
    var onTaskFinished: ((String, String) -> Void)?   // what was asked, and what was done
    var approvalQueue: [Approval] = []
    var taskGrants: Set<String> = []
    var harnessSession: String?
    var process: Process?
    var stopped = false
    var contextProvider: (() -> String)?

    init(sheet: CharacterSheet) {
        self.sheet = sheet
        load()
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
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let store = try? decoder.decode(MemoryStore.self, from: data) else { return }
        messages = store.messages.map { ChatMessage(role: $0.role, text: $0.text, hidden: $0.hidden) }
        facts = store.facts
        affection = store.affection
        firstMet = store.firstMet
        lastSeen = store.lastSeen
        harnessSession = store.harnessSession
        if let folder = store.folder, FileManager.default.fileExists(atPath: folder) {
            projectFolder = URL(fileURLWithPath: folder)
        }
    }

    func save() {
        let kept = messages.filter { !$0.text.isEmpty }.suffix(60)
        let store = MemoryStore(
            messages: kept.map { StoredMessage(role: $0.role, text: $0.text, hidden: $0.hidden) },
            facts: facts, affection: affection, firstMet: firstMet, lastSeen: Date(),
            harnessSession: harnessSession, folder: projectFolder?.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(store) else { return }
        try? FileManager.default.createDirectory(at: ChatSession.folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func forget() {
        if busy { return }
        messages = []
        facts = []
        affection = 0
        firstMet = Date()
        lastSeen = nil
        harnessSession = nil
        steps = []
        try? FileManager.default.removeItem(at: file)
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
        if sheet.harness == "claude-code" {
            if Harness.claudePath != nil { return "Claude Code" }
            return apiKey == nil ? "Not connected" : "Claude Code not found, using Claude"
        }
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
        draft = ""
        attachments = []
        steps = []
        taskGrants = []
        messages.append(ChatMessage(role: "user", text: text))
        begin(nudge: nil)
    }

    /// Sends a prepared request (a writing skill, say) while showing only a short label in the conversation.
    func ask(display: String, prompt: String) {
        if busy { return }
        steps = []
        taskGrants = []
        var message = ChatMessage(role: "user", text: display)
        message.payload = prompt
        messages.append(message)
        begin(nudge: nil)
    }

    /// The character says something without being asked.
    func speakUp(_ nudge: Nudge) {
        if busy { return }
        messages.append(ChatMessage(role: "user", text: note(for: nudge), hidden: true))
        begin(nudge: nudge)
    }

    private func dropLast(_ n: Int) {
        messages.removeLast(min(n, messages.count))
    }

    private func begin(nudge: Nudge?) {
        let history = messages
        let unprompted = nudge != nil
        messages.append(ChatMessage(role: "assistant", text: "", hidden: unprompted))
        busy = true
        let started = Date()
        if !unprompted {
            lastEvent = Date()
            onEvent?(.thinking)
        }

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var raw = ""
            var announced = false
            do {
                if !unprompted, let binary = self.harnessBinary() {
                    raw = try await self.runHarness(binary: binary, prompt: history.last?.payload ?? history.last?.text ?? "")
                    Connector.shared.noteWorking()
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
                    let reply = self.sheet.harness == "claude-code"
                        ? "[mood=playful gesture=wave]\nHi, I'm \(self.sheet.name). I'm not connected to Claude yet. Press Connect below, sign in in your browser, and I'll answer for real."
                        : "[mood=playful gesture=wave]\nHi, I'm \(self.sheet.name). I'm in demo mode because there is no \(keyName) yet. Add it to the .env file in the Spryts folder, run me again, and I'll answer for real."
                    for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                        raw += (raw.isEmpty ? "" : " ") + String(word)
                        announced = self.show(raw, announced: announced)
                        try await Task.sleep(nanoseconds: 45_000_000)
                    }
                }

                let parsed = ChatSession.strip(raw)
                self.learn(parsed.facts)
                self.clearApprovals()
                self.busy = false
                if unprompted {
                    if parsed.text.isEmpty {
                        self.dropLast(2)
                    } else {
                        if let i = self.messages.indices.last {
                            self.messages[i].text = parsed.text
                            self.messages[i].hidden = false
                        }
                        self.onEvent?(.remark(text: parsed.text, mood: parsed.mood, gesture: parsed.gesture))
                    }
                } else {
                    if let i = self.messages.indices.last {
                        self.messages[i].text = parsed.text.isEmpty ? raw : parsed.text
                    }
                    self.lastEvent = Date()
                    self.onTaskFinished?(history.last?.text ?? "", self.steps.map { $0.detail }.joined(separator: " "))
                    self.affection += 0.3
                    self.onEvent?(.done(mood: parsed.mood, gesture: parsed.gesture, seconds: Date().timeIntervalSince(started)))
                }
                self.save()
            } catch {
                self.clearApprovals()
                self.process = nil
                self.busy = false
                if unprompted {
                    self.dropLast(2)   // an unprompted line that fails just doesn't happen
                } else {
                    if let i = self.messages.indices.last {
                        self.messages[i].text = "Something went wrong. " + error.localizedDescription
                    }
                    self.lastEvent = Date()
                    self.onEvent?(.failed(error.localizedDescription))
                }
            }
        }
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
            body = ["model": sheet.model, "stream": true, "messages": all]
        } else {
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
            request = URLRequest(url: url)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": sheet.model, "max_tokens": 1024, "stream": true, "system": systemPrompt, "messages": turns]
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
        if type == "error", let err = obj["error"] as? [String: Any] {
            return .text("\n(" + (err["message"] as? String ?? "error") + ")")
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
