import Foundation

@main
struct PipLibraryChecks {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ why: String) {
        precondition(condition(), why)
        checks += 1
    }

    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spryts-pip-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("chief/library.json")
        let library = PipLibrary(file: file)
        let relationship = PipRelationship(affection: 9, firstMet: Date(timeIntervalSince1970: 1_700_000_000), lastSeen: nil)
        var initial = PipChatSnapshot.empty(engine: "grok", model: "fixture-model")
        initial.messages = (0..<100).map { PipMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant",
            text: "Message \($0)", hidden: false, payload: $0 == 0 ? "Prepared request" : nil) }
        initial.draft = "Unsent idea"
        initial.attachments = [root.appendingPathComponent("reference.txt").path]
        initial.sessionID = "original-engine-session"
        initial.folder = root.path
        initial.facts = ["Scoped conversation fact"]
        expect(library.bootstrap(snapshot: initial, relationship: relationship), "migration commits the existing conversation")
        let originalID = library.activeConversationID!
        let reopened = PipLibrary(file: file)
        expect(reopened.activeConversation?.snapshot == initial, "all 100 messages, payloads, draft, references, settings and engine session survive restart")
        expect(reopened.relationship == relationship, "relationship metadata survives migration")
        expect(reopened.bootstrap(snapshot: .empty(engine: "claude", model: ""), relationship: relationship), "already migrated library can reopen")
        expect(reopened.activeConversation?.snapshot == initial, "migration never overwrites an existing library")

        let alpha = library.createProject(name: "Alpha", instructions: "ALPHA_ONLY", files: [root.appendingPathComponent("alpha.txt")])!
        let beta = library.createProject(name: "Beta", instructions: "BETA_ONLY", files: [root.appendingPathComponent("beta.txt")])!
        expect(library.startConversation(projectID: alpha, engine: "claude", model: "sonnet"), "new project conversation is created atomically")
        let alphaChat = library.activeConversationID!
        expect(library.activeConversation?.snapshot.messages.isEmpty == true && library.activeConversation?.snapshot.sessionID == nil,
               "new chat starts with no transcript or engine session")
        expect(library.activeConversation?.snapshot.facts.isEmpty == true, "personal facts from another chat do not leak into project context")
        expect(library.conversations.first { $0.id == originalID }?.snapshot == initial, "new chat preserves the complete preceding conversation")
        expect(library.projectContext.contains("ALPHA_ONLY") && !library.projectContext.contains("BETA_ONLY"), "active project's instructions are isolated")
        expect(library.projectContext.contains("alpha.txt") && !library.projectContext.contains("beta.txt"), "only current project references are injected")
        var alphaSnapshot = library.activeConversation!.snapshot
        alphaSnapshot.sessionID = "alpha-session"
        alphaSnapshot.messages = [PipMessage(role: "user", text: "Research a lunar launch", hidden: false)]
        expect(library.saveCurrent(snapshot: alphaSnapshot, relationship: relationship), "project transcript is durable")
        expect(library.rename(alphaChat, title: "Moon plan") && library.pin(alphaChat, pinned: true), "conversation organization saves")
        expect(library.startConversation(projectID: beta, engine: "grok", model: "fixture"), "second project conversation starts")
        expect(!library.projectContext.contains("ALPHA_ONLY") && library.projectContext.contains("BETA_ONLY"), "switching projects replaces all project context")
        expect(library.conversations(matching: "lunar launch").map(\.id) == [alphaChat], "search finds message contents beyond titles")
        expect(library.conversations(matching: "").first?.id == alphaChat, "pinned chat sorts before newer chats")
        expect(library.activate(alphaChat), "conversation can be resumed")
        expect(library.activeConversation?.snapshot.sessionID == "alpha-session", "switch restores the matching engine session")
        expect(library.updateProject(alpha, name: "Alpha", instructions: "ALPHA_UPDATED", files: []), "project updates commit")
        expect(library.activeConversation?.snapshot.sessionID == nil && library.projectContext.contains("ALPHA_UPDATED"),
               "edited project context invalidates its existing engine session")
        expect(library.move(alphaChat, projectID: beta), "chat can move projects")
        expect(!library.projectContext.contains("ALPHA_UPDATED") && library.projectContext.contains("BETA_ONLY"), "moved chat adopts only its new project instructions")
        expect(library.archive(alphaChat, archived: true), "archiving active conversation succeeds")
        expect(library.activeConversationID != alphaChat && library.conversations(matching: "Moon", archived: true).count == 1,
               "archive preserves history and safely chooses another active conversation")
        expect(library.archive(alphaChat, archived: false) && library.activate(alphaChat), "archive can be restored without data loss")
        expect(library.activeConversation?.title == "Moon plan", "manual chat title survives future writes and switches")

        let beforeFailure = library.conversations
        let beforeSelection = library.activeConversationID
        let goodBytes = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        expect(!library.startConversation(projectID: nil, engine: "claude", model: ""), "failed disk write refuses new chat")
        expect(library.activeConversationID == beforeSelection && library.conversations == beforeFailure && library.error != nil,
               "failed transition preserves both selected chat and all in-memory history")
        expect(!library.startPreparedConversation(title: "Start My Day", request: "Use only selected sources", projectID: nil,
            sceneID: "starter.start-my-day", engine: "grok", model: "fixture"), "failed disk write refuses a prepared Scene")
        expect(library.activeConversationID == beforeSelection && library.conversations == beforeFailure,
               "failed Scene creation preserves the previous selection and all drafts")
        try FileManager.default.removeItem(at: file)
        try goodBytes.write(to: file)
        expect(library.activate(originalID) && library.error == nil, "retry after storage recovery succeeds and clears error")
        expect(library.activeConversation?.snapshot == initial, "storage failure cannot erase the earlier transcript")

        var running = library.activeConversation!.snapshot
        running.wasRunning = true
        expect(library.saveCurrent(snapshot: running, relationship: relationship), "running turn is persisted")
        let interrupted = PipLibrary(file: file)
        expect(interrupted.recoverInterruptedConversation(), "interruption can be recorded on next launch")
        expect(interrupted.activeConversation?.snapshot.sessionID == nil && interrupted.activeConversation?.snapshot.wasRunning == false,
               "interrupted engine is never resumed automatically")
        expect(interrupted.activeConversation?.snapshot.messages.last?.text.contains("interrupted") == true,
               "interrupted work is visibly identified rather than claimed complete")
        let recoveryCount = interrupted.activeConversation!.snapshot.messages.count
        expect(interrupted.recoverInterruptedConversation() && interrupted.activeConversation?.snapshot.messages.count == recoveryCount,
               "reopening twice does not duplicate the interruption receipt")

        let corrupt = root.appendingPathComponent("corrupt.json")
        let corruptBytes = Data("{ definitely not a library".utf8)
        try corruptBytes.write(to: corrupt)
        let unreadable = PipLibrary(file: corrupt)
        expect(!unreadable.bootstrap(snapshot: initial, relationship: relationship) && unreadable.error != nil,
               "corrupt existing data cannot be replaced by a blank migration")
        let preserved = try Data(contentsOf: corrupt)
        expect(preserved == corruptBytes, "corrupt file remains untouched for recovery")
        var localDraft = PipChatSnapshot.empty(engine: "claude", model: "sonnet")
        localDraft.draft = "Typed while the library was unavailable"
        localDraft.attachments = [root.appendingPathComponent("new-draft.txt").path]
        expect(!unreadable.recoverFromDisk(preservingUnsent: localDraft) && unreadable.needsRecovery,
               "retry refuses a still-unreadable file without clearing its recovery guard")
        let repairedBytes = try Data(contentsOf: file)
        try repairedBytes.write(to: corrupt)
        expect(unreadable.recoverFromDisk(preservingUnsent: localDraft) && !unreadable.needsRecovery && unreadable.error == nil,
               "explicit retry rereads repaired data and makes the library writable again")
        expect(unreadable.activeConversation?.title == "Recovered draft" && unreadable.activeConversation?.snapshot.draft == localDraft.draft
               && unreadable.activeConversation?.snapshot.attachments == localDraft.attachments,
               "local text and references survive repair as an accessible recovered conversation")
        expect(unreadable.conversations.first { $0.id == originalID }?.snapshot.draft == initial.draft
               && unreadable.conversations.first { $0.id == originalID }?.snapshot.attachments == initial.attachments,
               "restored file's own saved composer remains intact when preserving different local input")
        expect(unreadable.activeConversation?.projectID == nil && unreadable.activeConversation?.snapshot.sessionID == nil,
               "recovered local input cannot inherit an unrelated restored project or engine session")
        let recoveredAgain = PipLibrary(file: corrupt)
        expect(recoveredAgain.activeConversation?.snapshot.draft == localDraft.draft && recoveredAgain.conversations.count == unreadable.conversations.count,
               "both restored history and the recovered composer are durable before recovery is published")
        expect(library.conversations(matching: "   ") == library.conversations(matching: ""),
               "empty search uses normal filtering and sorting without message-text search")

        let priorSelection = library.activeConversationID
        let priorConversations = library.conversations
        expect(!library.startPreparedConversation(title: "Missing project", request: "A valid request", projectID: "missing",
            sceneID: "starter.start-my-day", engine: "grok", model: "fixture"), "Scene refuses a missing project")
        expect(!library.startPreparedConversation(title: "Too long", request: String(repeating: "a", count: 120_001), projectID: nil,
            sceneID: "starter.start-my-day", engine: "grok", model: "fixture"), "oversized prepared requests fail before saving")
        expect(!library.startPreparedConversation(title: " ", request: "Request", projectID: nil,
            sceneID: nil, engine: "grok", model: "fixture"), "empty prepared titles fail validation")
        expect(library.activeConversationID == priorSelection && library.conversations == priorConversations,
               "invalid preparations preserve all previous work")
        expect(library.startPreparedConversation(title: "Start My Day", request: "Read Calendar only; return a brief", projectID: beta,
            sceneID: "starter.start-my-day", engine: "grok", model: "fixture"), "prepared Scene commits its request and source together")
        let prepared = library.activeConversation!
        expect(prepared.sceneID == "starter.start-my-day" && prepared.sceneRunStatus == .prepared
               && prepared.projectID == beta && prepared.title == "Start My Day", "Scene title, project, identity and initial status persist")
        expect(prepared.snapshot.messages.isEmpty && prepared.snapshot.sessionID == nil && prepared.snapshot.facts.isEmpty
               && prepared.snapshot.folder == nil && prepared.snapshot.attachments.isEmpty && !prepared.snapshot.wasRunning,
               "preparation starts no work and inherits no prior private context or engine session")
        expect(PipLibrary(file: file).activeConversation?.snapshot.draft == "Read Calendar only; return a brief",
               "prepared request survives restart before it is sent")
        var sceneSnapshot = prepared.snapshot
        sceneSnapshot.messages = [PipMessage(role: "user", text: "Hidden greeting", hidden: true)]
        sceneSnapshot.wasRunning = true
        expect(library.saveCurrent(snapshot: sceneSnapshot, relationship: relationship)
               && library.activeConversation?.sceneRunStatus == .prepared, "hidden greetings cannot mark a Scene running")
        let hiddenRestart = PipLibrary(file: file)
        expect(hiddenRestart.recoverInterruptedConversation() && hiddenRestart.activeConversation?.sceneRunStatus == .prepared,
               "interrupted hidden greetings leave the prepared Scene status unchanged")
        sceneSnapshot.messages = [PipMessage(role: "user", text: "Begin the Scene", hidden: false)]
        expect(library.saveCurrent(snapshot: sceneSnapshot, relationship: relationship)
               && library.activeConversation?.sceneRunStatus == .running && library.activeConversation?.sceneStartedAt != nil,
               "visible work records a Scene start time")
        let sceneRestart = PipLibrary(file: file)
        expect(sceneRestart.recoverInterruptedConversation() && sceneRestart.activeConversation?.sceneRunStatus == .interrupted
               && sceneRestart.activeConversation?.sceneFinishedAt != nil, "restarted Scene work is interrupted with a timestamp")
        sceneSnapshot.wasRunning = false
        sceneSnapshot.messages.append(PipMessage(role: "assistant", text: "Here is the brief", hidden: false))
        expect(library.saveCurrent(snapshot: sceneSnapshot, relationship: relationship, sceneOutcome: .responseReady),
               "a finished response records a terminal Scene status")
        let finished = PipLibrary(file: file).activeConversation!
        expect(finished.sceneRunStatus == .responseReady && finished.sceneFinishedAt != nil && finished.title == "Start My Day",
               "response-ready status is durable without claiming verified task success")

        // Older libraries have none of the optional Scene fields.
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        legacy["conversations"] = (legacy["conversations"] as! [[String: Any]]).map { value -> [String: Any] in
            var old = value
            for field in ["sceneID", "sceneRunStatus", "sceneStartedAt", "sceneFinishedAt"] { old.removeValue(forKey: field) }
            return old
        }
        let legacyFile = root.appendingPathComponent("pre-scenes-library.json")
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyFile)
        let migrated = PipLibrary(file: legacyFile)
        expect(migrated.error == nil && migrated.activeConversation?.snapshot == finished.snapshot
               && migrated.activeConversation?.sceneID == nil, "libraries without Scene fields reopen without losing any conversation state")
        print("Passed \(checks) Pip library checks using temporary files only.")
    }
}
