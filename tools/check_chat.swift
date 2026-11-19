import Foundation

// Minimal app boundaries. The production ChatService.swift remains intact; local storage is
// redirected through this FileManager facade and all network traffic is caught by URLProtocol.
struct CharacterSheet {
    var id = UUID().uuidString
    var name = "Fixture"
    var provider = "claude"
    var model = "test-model"
    var persona = "Test character"
    var harness: String? = "fixture"
    var role: String? = "generalist"
}
struct AgentStep { let detail: String }
struct PlanItem {}
struct Approval {}
struct Checkpoint: Codable {}
enum Engine { static var current = "claude"; static let name = "Fixture" }
enum Config {
    static var apiKeyEnabled = true
    static func key(_ name: String) -> String? { apiKeyEnabled ? "fixture-key" : nil }
}
enum Git { static func checkpoint(folder: URL, ask: String) -> Checkpoint? { nil } }
enum CodexAgent { static func models() async throws -> [(id: String, label: String)] { [] } }
final class Connector {
    static let fixture = Connector()
    static func of(_ engine: String) -> Connector { fixture }
    func refresh() {}
    func noteWorking() {}
}
final class SpeechOut {
    static let shared = SpeechOut()
    func stop() {}
    func finished(_ text: String, by sheet: CharacterSheet) {}
}
final class FixtureFileManager {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spryts-chat-" + UUID().uuidString)
    func urls(for directory: Foundation.FileManager.SearchPathDirectory, in domain: Foundation.FileManager.SearchPathDomainMask) -> [URL] { [root] }
    func fileExists(atPath path: String) -> Bool { Foundation.FileManager.default.fileExists(atPath: path) }
    func createDirectory(at url: URL, withIntermediateDirectories intermediate: Bool) throws {
        try Foundation.FileManager.default.createDirectory(at: url, withIntermediateDirectories: intermediate)
    }
    func removeItem(at url: URL) throws { try Foundation.FileManager.default.removeItem(at: url) }
}
enum FileManager { static let `default` = FixtureFileManager() }
final class FixtureDefaults {
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
enum UserDefaults { static let standard = FixtureDefaults() }
enum FixtureRuntime {
    @MainActor static var releaseSecond = false
    @MainActor static var harnessPrompts: [String] = []
    @MainActor static var blockedPrompts: Set<String> = []
}

private struct FixtureFailure: LocalizedError {
    var errorDescription: String? { "Fixture task failed" }
}
extension ChatSession {
    func harnessBinary() -> String? { sheet.harness == nil ? nil : "fixture" }
    func clearApprovals() { approval = nil; approvalQueue = []; approvalReplies = [:] }
    @MainActor
    func runHarness(binary: String, prompt: String) async throws -> String {
        FixtureRuntime.harnessPrompts.append(prompt)
        try await Task.sleep(nanoseconds: 5_000_000)
        while FixtureRuntime.blockedPrompts.contains(prompt) { try await Task.sleep(nanoseconds: 5_000_000) }
        if prompt.hasPrefix("second") {
            while !FixtureRuntime.releaseSecond { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        if prompt.hasPrefix("fail") { throw FixtureFailure() }
        return "[mood=calm gesture=none]\n" + (prompt.hasPrefix("second") ? "Second result" : "First result")
    }
}

final class StreamFixture: URLProtocol {
    static var body = ""
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum URLSession {
    static let shared: Foundation.URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamFixture.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return Foundation.URLSession(configuration: configuration)
    }()
}

@main
struct ChatChecks {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ why: String) {
        precondition(condition(), why)
        checks += 1
    }
    static func summary(_ outcome: ChatTaskOutcome) -> String {
        switch outcome {
        case .completed(let text): return "done:" + text
        case .failed(let text): return "failed:" + text
        case .interrupted: return "interrupted"
        }
    }
    @MainActor
    static func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("A fixture turn never settled")
    }

    @MainActor
    static func main() async throws {
        defer { try? Foundation.FileManager.default.removeItem(at: FileManager.default.root) }

        // Upgrade the actual legacy MemoryStore through ChatSession, using a fake app-support root.
        var legacySheet = CharacterSheet()
        legacySheet.id = "legacy-pip"
        let legacyFile = FileManager.default.root.appendingPathComponent("Spryts/legacy-pip.json")
        try Foundation.FileManager.default.createDirectory(at: legacyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyMessages: [[String: Any]] = (0..<80).map {
            ["role": $0.isMultiple(of: 2) ? "user" : "assistant", "text": "Earlier message \($0)", "hidden": false]
        }
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "messages": legacyMessages, "facts": ["ALPHA_PRIVATE_FACT"], "affection": 3,
            "firstMet": "2025-01-01T00:00:00Z", "lastSeen": "2025-01-02T00:00:00Z",
            "harnessSession": "legacy-grok-session", "folder": FileManager.default.root.path, "engine": "grok"
        ])
        try legacyData.write(to: legacyFile)
        UserDefaults.standard.set("fixture-grok-model", forKey: "model.legacy-pip.grok")
        let legacy = ChatSession(sheet: legacySheet)
        expect(legacy.messages.count == 80 && legacy.harnessSession == "legacy-grok-session" && legacy.engine == "grok",
               "legacy migration preserves every available message and its actual engine session")
        let legacyAfterMigration = try Data(contentsOf: legacyFile)
        expect(legacyData == legacyAfterMigration, "migration leaves the legacy backup byte-for-byte intact")
        let oldID = legacy.pipLibrary!.activeConversationID!
        legacy.draft = "A saved composer"
        legacy.attachments = [FileManager.default.root.appendingPathComponent("attached.txt")]
        legacy.model = "per-chat-model"
        expect(legacy.newPipConversation(), "new Pip chat saves the preceding composer before switching")
        expect(legacy.messages.isEmpty && legacy.draft.isEmpty && legacy.harnessSession == nil && legacy.facts.isEmpty,
               "new chat starts without the earlier transcript, draft, engine session or remembered facts")
        expect(legacy.selectPipConversation(oldID), "earlier chat can be reopened through ChatSession")
        expect(legacy.messages.count == 80 && legacy.draft == "A saved composer" && legacy.attachments.count == 1
               && legacy.model == "per-chat-model" && legacy.harnessSession == "legacy-grok-session",
               "switching back restores transcript, draft, attachments and matching model/session together")
        let alphaID = legacy.createPipProject(name: "Alpha", instructions: "ALPHA_INSTRUCTIONS", files: [])!
        let betaID = legacy.createPipProject(name: "Beta", instructions: "BETA_INSTRUCTIONS", files: [])!
        expect(legacy.newPipConversation(projectID: alphaID) && legacy.systemPrompt.contains("ALPHA_INSTRUCTIONS")
               && !legacy.systemPrompt.contains("ALPHA_PRIVATE_FACT"), "new project has only its own context, without inherited chat facts")
        let alphaChatID = legacy.pipLibrary!.activeConversationID!
        legacy.harnessSession = "alpha-engine-session"
        expect(legacy.save(), "project engine session is saved")
        expect(legacy.newPipConversation(projectID: betaID) && legacy.systemPrompt.contains("BETA_INSTRUCTIONS")
               && !legacy.systemPrompt.contains("ALPHA_INSTRUCTIONS"), "switching to another project fully replaces system context")
        expect(legacy.selectPipConversation(alphaChatID) && legacy.harnessSession == "alpha-engine-session", "project chat restores its own session")
        expect(legacy.updatePipProject(alphaID, name: "Alpha", instructions: "NEW_ALPHA_CONTEXT", files: [])
               && legacy.harnessSession == nil && legacy.systemPrompt.contains("NEW_ALPHA_CONTEXT"),
               "changing project instructions invalidates the live restored provider session")
        legacy.busy = true
        expect(!legacy.selectPipConversation(oldID) && !legacy.newPipConversation()
               && !legacy.movePipConversation(alphaChatID, projectID: betaID), "a live run cannot switch conversations or project context")
        legacy.busy = false
        legacy.draft = "Draft before restart"
        expect(legacy.save(), "composer can flush on app close")
        let restored = ChatSession(sheet: legacySheet)
        expect(restored.pipLibrary?.activeConversationID == alphaChatID && restored.draft == "Draft before restart"
               && restored.systemPrompt.contains("NEW_ALPHA_CONTEXT"), "launch restores selected conversation, composer and project")

        // Block only this fixture's library file; every failed operation must leave the live state intact.
        let libraryFile = restored.pipLibrary!.file
        let goodLibrary = try Data(contentsOf: libraryFile)
        try Foundation.FileManager.default.removeItem(at: libraryFile)
        try Foundation.FileManager.default.createDirectory(at: libraryFile, withIntermediateDirectories: false)
        let selectedBeforeFailure = restored.pipLibrary!.activeConversationID
        let messagesBeforeFailure = restored.messages
        restored.attachments = [FileManager.default.root.appendingPathComponent("queued.txt")]
        restored.send()
        expect(!restored.busy && restored.messages == messagesBeforeFailure && restored.draft == "Draft before restart"
               && restored.attachments.count == 1, "failed request persistence preserves composer and never starts model work")
        var storageOutcome: String?
        var staleReplyFired = false
        restored.onReply = { _ in staleReplyFired = true }
        restored.ask(display: "Prepared", prompt: "prepared") { storageOutcome = summary($0) }
        expect(storageOutcome?.hasPrefix("failed:") == true && !restored.busy && restored.messages == messagesBeforeFailure,
               "prepared requests report failed persistence without adding a phantom turn")
        expect(!restored.selectPipConversation(oldID) && restored.pipLibrary!.activeConversationID == selectedBeforeFailure
               && restored.pipLibrary!.error != nil, "failed save refuses navigation and surfaces an actionable storage error")
        try Foundation.FileManager.default.removeItem(at: libraryFile)
        try goodLibrary.write(to: libraryFile)
        let settingsBeforeRetry = (restored.engine, restored.model, restored.harnessSession)
        expect(restored.retryPipPersistence(), "ordinary storage recovery permits retry without losing unsent input")
        expect(restored.engine == settingsBeforeRetry.0 && restored.model == settingsBeforeRetry.1 && restored.harnessSession == settingsBeforeRetry.2,
               "ordinary write retry does not replace live engine, model or session state")
        var nextResult: String?
        restored.ask(display: "Unrelated next request", prompt: "first") { nextResult = summary($0) }
        try await settle { nextResult != nil }
        expect(!staleReplyFired && nextResult == "done:First result", "failed-persistence reply callback cannot consume an unrelated later answer")

        // Initial read failures retry the corrected file, retaining both old and newly typed composers.
        let savedLibraryBytes = try Data(contentsOf: libraryFile)
        try Data("{ unreadable".utf8).write(to: libraryFile)
        let readFailure = ChatSession(sheet: legacySheet)
        readFailure.draft = "Typed while recovery was needed"
        readFailure.attachments = [FileManager.default.root.appendingPathComponent("recovery.txt")]
        expect(readFailure.pipLibrary!.needsRecovery && !readFailure.retryPipPersistence(), "still-corrupt library refuses recovery and remains protected")
        try savedLibraryBytes.write(to: libraryFile)
        expect(readFailure.retryPipPersistence() && readFailure.draft == "Typed while recovery was needed" && readFailure.attachments.count == 1,
               "repaired library can reopen without discarding current unsent text or file references")
        expect(readFailure.pipLibrary!.conversations.first { $0.id == selectedBeforeFailure }?.snapshot.draft == "Draft before restart",
               "recovery preserves the restored conversation's already-saved draft separately")
        expect(readFailure.save() && !readFailure.pipLibrary!.needsRecovery, "successful recovery unblocks the same save used by quit and restart")

        var brokenLegacySheet = CharacterSheet()
        brokenLegacySheet.id = "repaired-legacy"
        let brokenLegacyFile = FileManager.default.root.appendingPathComponent("Spryts/repaired-legacy.json")
        let invalidLegacy = Data("{ damaged legacy".utf8)
        try invalidLegacy.write(to: brokenLegacyFile)
        let repairedLegacy = ChatSession(sheet: brokenLegacySheet)
        repairedLegacy.draft = "Legacy recovery draft"
        repairedLegacy.attachments = [FileManager.default.root.appendingPathComponent("legacy-reference.txt")]
        expect(!repairedLegacy.retryPipPersistence(), "invalid legacy input cannot migrate on retry")
        let legacyStillInvalid = try Data(contentsOf: brokenLegacyFile)
        expect(legacyStillInvalid == invalidLegacy, "failed legacy recovery never overwrites the original file")
        try legacyData.write(to: brokenLegacyFile)
        expect(repairedLegacy.retryPipPersistence() && repairedLegacy.draft == "Legacy recovery draft" && repairedLegacy.attachments.count == 1,
               "corrected legacy input migrates while preserving the live composer")
        let migratedHistory = repairedLegacy.pipLibrary!.conversations.first { $0.snapshot.messages.count == 80 }!
        expect(repairedLegacy.selectPipConversation(migratedHistory.id) && repairedLegacy.harnessSession == "legacy-grok-session"
               && repairedLegacy.engine == "grok", "repaired legacy history retains its own matching engine session")
        var coderSheet = CharacterSheet()
        coderSheet.role = "coder"
        expect(ChatSession(sheet: coderSheet).pipLibrary == nil, "Nova and other specialist state stays outside Pip's library")

        // Preparing a Scene creates a reviewable draft, leaving the preceding chat wholly restorable.
        let preparation = ChatSession(sheet: CharacterSheet())
        preparation.selectEngine("grok")
        preparation.model = "scene-fixture-model"
        preparation.messages = [ChatMessage(role: "user", text: "Earlier question", payload: "Earlier complete request"), ChatMessage(role: "assistant", text: "Earlier answer")]
        preparation.draft = "Unsent text before a Scene"
        preparation.attachments = [FileManager.default.root.appendingPathComponent("unsent-scene-file.txt")]
        preparation.harnessSession = "preceding-provider-session"
        preparation.projectFolder = FileManager.default.root.appendingPathComponent("preceding-workspace")
        let precedingID = preparation.pipLibrary!.activeConversationID!
        let precedingMessages = preparation.messages.map { PipMessage(role: $0.role, text: $0.text, hidden: $0.hidden, payload: $0.payload) }
        let callsBeforePreparation = FixtureRuntime.harnessPrompts.count
        expect(preparation.preparePipConversation(title: "Start My Day", request: "first scene request", sceneID: "start-my-day"),
               "Scene preparation creates a new conversation")
        let preparedID = preparation.pipLibrary!.activeConversationID!
        let prepared = PipLibrary(file: preparation.pipLibrary!.file).activeConversation!
        expect(preparedID != precedingID && prepared.title == "Start My Day" && prepared.sceneID == "start-my-day"
               && prepared.sceneRunStatus == .prepared && prepared.sceneStartedAt == nil && prepared.sceneFinishedAt == nil,
               "prepared Scene origin and draft status are durable without run timestamps")
        expect(preparation.draft == "first scene request" && preparation.messages.isEmpty && preparation.attachments.isEmpty
               && preparation.harnessSession == nil && preparation.projectFolder == nil && !preparation.busy,
               "prepared Scene has only its reviewed request, without previous chat payload or session")
        try await Task.sleep(nanoseconds: 20_000_000)
        expect(FixtureRuntime.harnessPrompts.count == callsBeforePreparation && StreamFixture.requests == 0,
               "Scene preparation never calls an engine or an API")
        expect(preparation.selectPipConversation(precedingID)
               && preparation.messages.map { PipMessage(role: $0.role, text: $0.text, hidden: $0.hidden, payload: $0.payload) } == precedingMessages
               && preparation.draft == "Unsent text before a Scene" && preparation.attachments.map(\.lastPathComponent) == ["unsent-scene-file.txt"]
               && preparation.engine == "grok" && preparation.model == "scene-fixture-model"
               && preparation.harnessSession == "preceding-provider-session" && preparation.projectFolder?.lastPathComponent == "preceding-workspace",
               "preparing a Scene preserves the complete preceding unsent composer and provider state")
        expect(preparation.selectPipConversation(preparedID), "prepared Scene can be reopened without dispatch")
        preparation.busy = true
        expect(!preparation.preparePipConversation(title: "Another Scene", request: "new request", sceneID: "another")
               && preparation.pipLibrary!.activeConversationID == preparedID && preparation.draft == "first scene request",
               "busy chat refuses Scene preparation without changing the selected draft")
        preparation.busy = false

        let preparationFile = preparation.pipLibrary!.file
        let preparationBytes = try Data(contentsOf: preparationFile)
        try Foundation.FileManager.default.removeItem(at: preparationFile)
        try Foundation.FileManager.default.createDirectory(at: preparationFile, withIntermediateDirectories: false)
        preparation.draft = "Edited Scene awaiting review"
        preparation.attachments = [FileManager.default.root.appendingPathComponent("scene-review.txt")]
        let preparationCount = preparation.pipLibrary!.conversations.count
        expect(!preparation.preparePipConversation(title: "Must not appear", request: "new request", sceneID: "failed-preparation")
               && preparation.pipLibrary!.activeConversationID == preparedID && preparation.pipLibrary!.conversations.count == preparationCount
               && preparation.draft == "Edited Scene awaiting review" && preparation.attachments.count == 1
               && preparation.messages.isEmpty && !preparation.busy && FixtureRuntime.harnessPrompts.count == callsBeforePreparation,
               "failed preparation save preserves the current chat and composer without phantom Scene or inference")
        try Foundation.FileManager.default.removeItem(at: preparationFile)
        try preparationBytes.write(to: preparationFile)
        expect(preparation.retryPipPersistence(), "Scene preparation storage failure can be retried")

        // Hidden remarks must not turn a prepared Scene into an executed Scene.
        Config.apiKeyEnabled = false
        preparation.speakUp(.hello)
        expect(preparation.busy && preparation.pipLibrary!.activeConversation?.sceneRunStatus == .prepared,
               "hidden nudge does not mark a prepared Scene running")
        try await settle { !preparation.busy }
        expect(preparation.pipLibrary!.activeConversation?.sceneRunStatus == .prepared
               && preparation.pipLibrary!.activeConversation?.sceneStartedAt == nil
               && preparation.draft == "Edited Scene awaiting review" && preparation.attachments.count == 1,
               "completed hidden nudge leaves Scene draft and status unchanged")
        Config.apiKeyEnabled = true
        preparation.draft = "first scene request"
        preparation.attachments = []
        preparation.send()
        let runningScene = PipLibrary(file: preparationFile).activeConversation!
        expect(preparation.busy && runningScene.sceneRunStatus == .running && runningScene.sceneStartedAt != nil
               && runningScene.sceneFinishedAt == nil && runningScene.snapshot.wasRunning && runningScene.snapshot.draft.isEmpty,
               "Send durably marks Scene running and consumes its composer before model work")
        try await settle { !preparation.busy }
        let completedScene = PipLibrary(file: preparationFile).activeConversation!
        expect(completedScene.sceneRunStatus == .responseReady && completedScene.sceneFinishedAt != nil
               && !completedScene.snapshot.wasRunning && completedScene.snapshot.messages.last?.text == "First result",
               "a completed model turn produces Response ready, with a durable reply and finish time")
        let completedTimes = (preparation.pipLibrary!.activeConversation?.sceneStartedAt, preparation.pipLibrary!.activeConversation?.sceneFinishedAt)
        Config.apiKeyEnabled = false
        preparation.speakUp(.back(minutes: 10))
        expect(preparation.pipLibrary!.activeConversation?.sceneRunStatus == .responseReady,
               "hidden nudge does not replace a completed Scene status while running")
        try await settle { !preparation.busy }
        expect(preparation.pipLibrary!.activeConversation?.sceneRunStatus == .responseReady
               && preparation.pipLibrary!.activeConversation?.sceneStartedAt == completedTimes.0
               && preparation.pipLibrary!.activeConversation?.sceneFinishedAt == completedTimes.1,
               "hidden remark completion preserves Scene outcome and original timestamps")
        Config.apiKeyEnabled = true

        // Each terminal outcome survives a failed final write, then an ordinary explicit retry.
        for (request, expectedStatus, expectedText) in [
            ("first held scene", PipSceneRunStatus.responseReady, "First result"),
            ("fail held scene", PipSceneRunStatus.failed, "Something went wrong. Fixture task failed"),
            ("second held scene", PipSceneRunStatus.interrupted, "Stopped.")
        ] {
            let finishing = ChatSession(sheet: CharacterSheet())
            expect(finishing.preparePipConversation(title: "Lifecycle fixture", request: request, sceneID: "lifecycle"),
                   "lifecycle Scene is prepared")
            FixtureRuntime.blockedPrompts.insert(request)
            finishing.send()
            try await settle { FixtureRuntime.harnessPrompts.contains(request) }
            let finishingFile = finishing.pipLibrary!.file
            let runningBytes = try Data(contentsOf: finishingFile)
            try Foundation.FileManager.default.removeItem(at: finishingFile)
            try Foundation.FileManager.default.createDirectory(at: finishingFile, withIntermediateDirectories: false)
            if expectedStatus == .interrupted { finishing.cancelRun() }
            FixtureRuntime.blockedPrompts.remove(request)
            try await settle { !finishing.busy }
            expect(finishing.messages.last?.text == expectedText && finishing.pipLibrary!.error != nil
                   && finishing.pipLibrary!.activeConversation?.sceneRunStatus == .running,
                   "failed final write keeps the real terminal reply in memory without claiming durable \(expectedStatus.rawValue)")
            try Foundation.FileManager.default.removeItem(at: finishingFile)
            try runningBytes.write(to: finishingFile)
            expect(finishing.retryPipPersistence(), "pending \(expectedStatus.rawValue) outcome retries successfully")
            let persistedFinish = PipLibrary(file: finishingFile).activeConversation!
            expect(persistedFinish.sceneRunStatus == expectedStatus && persistedFinish.sceneFinishedAt != nil
                   && !persistedFinish.snapshot.wasRunning && persistedFinish.snapshot.messages.last?.text == expectedText,
                   "retry persists \(expectedStatus.rawValue) with the matching terminal reply, rather than leaving Working")
        }

        // A hidden nudge may be the first successful save after a failed final Scene write.
        let pending = ChatSession(sheet: CharacterSheet())
        let pendingRequest = "first pending scene"
        expect(pending.preparePipConversation(title: "Pending outcome", request: pendingRequest, sceneID: "pending"), "pending Scene prepared")
        FixtureRuntime.blockedPrompts.insert(pendingRequest)
        pending.send()
        try await settle { FixtureRuntime.harnessPrompts.contains(pendingRequest) }
        let pendingFile = pending.pipLibrary!.file
        let pendingBytes = try Data(contentsOf: pendingFile)
        try Foundation.FileManager.default.removeItem(at: pendingFile)
        try Foundation.FileManager.default.createDirectory(at: pendingFile, withIntermediateDirectories: false)
        FixtureRuntime.blockedPrompts.remove(pendingRequest)
        try await settle { !pending.busy }
        expect(pending.pipLibrary!.error != nil && pending.messages.last?.text == "First result", "terminal outcome remains pending after disk failure")
        try Foundation.FileManager.default.removeItem(at: pendingFile)
        try pendingBytes.write(to: pendingFile)
        Config.apiKeyEnabled = false
        pending.speakUp(.hello)
        expect(pending.pipLibrary!.activeConversation?.sceneRunStatus == .responseReady,
               "first successful hidden save commits the pending Scene outcome before clearing it")
        try await settle { !pending.busy }
        Config.apiKeyEnabled = true
        expect(PipLibrary(file: pendingFile).activeConversation?.sceneRunStatus == .responseReady,
               "hidden nudge completion cannot lose a previously unsaved terminal Scene outcome")
        expect(StreamFixture.requests == 0, "all Scene fixtures use fake harnesses or local canned remarks, with no API streams")

        // A reply callback starts turn two before turn one's finish function returns.
        let session = ChatSession(sheet: CharacterSheet())
        var outcomes: [String] = []
        var replies: [String] = []
        var nextCancelSurvived = false
        session.onReply = { text in
            replies.append(text)
            session.onReply = { replies.append($0) }
            session.ask(display: "Second", prompt: "second") { outcomes.append(summary($0)) }
            session.cancelHarness = { nextCancelSurvived = true }
        }
        session.ask(display: "First", prompt: "first") { outcomes.append(summary($0)) }
        let submitted = PipLibrary(file: session.pipLibrary!.file).activeConversation!.snapshot
        expect(submitted.wasRunning && submitted.messages.last?.payload == "first",
               "submitted user request is durable before the asynchronous provider turn starts")
        try await settle { outcomes.count == 1 && session.busy }
        session.cancelHarness?()
        expect(nextCancelSurvived, "old turn cleanup must not erase the new turn's cancellation callback")
        FixtureRuntime.releaseSecond = true
        try await settle { outcomes.count == 2 && !session.busy }
        expect(outcomes == ["done:First result", "done:Second result"], "each completion belongs to its original request")
        expect(replies == ["First result", "Second result"], "capturing the first reply does not consume the next turn's onReply")
        expect(session.messages.filter { $0.role == "assistant" }.map(\.text) == ["First result", "Second result"], "reentrant reply does not overwrite either assistant message")

        // A failed turn's own completion can also start another run safely.
        FixtureRuntime.releaseSecond = false
        let retry = ChatSession(sheet: CharacterSheet())
        var retryOutcomes: [String] = []
        var retryCancelSurvived = false
        retry.ask(display: "Failure", prompt: "fail") { outcome in
            retryOutcomes.append(summary(outcome))
            retry.ask(display: "Second", prompt: "second") { retryOutcomes.append(summary($0)) }
            retry.cancelHarness = { retryCancelSurvived = true }
        }
        try await settle { retryOutcomes.count == 1 && retry.busy }
        retry.cancelHarness?()
        expect(retryCancelSurvived, "error cleanup must finish before invoking a reentrant completion")
        FixtureRuntime.releaseSecond = true
        try await settle { retryOutcomes.count == 2 && !retry.busy }
        expect(retryOutcomes == ["failed:Fixture task failed", "done:Second result"], "failure callback cannot capture or clear its successor")

        // HTTP 200 can still contain an error event after a partial answer, on either provider.
        for provider in ["claude", "grok"] {
            var sheet = CharacterSheet()
            sheet.harness = nil
            sheet.provider = provider
            StreamFixture.body = provider == "claude"
                ? "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"Partial reply\"}}\n\ndata: {\"type\":\"error\",\"error\":{\"message\":\"Fixture stream failed\"}}\n\n"
                : "data: {\"choices\":[{\"delta\":{\"content\":\"Partial reply\"}}]}\n\ndata: {\"error\":{\"message\":\"Fixture stream failed\"}}\n\n"
            let stream = ChatSession(sheet: sheet)
            var streamOutcomes: [String] = []
            var replied = false
            stream.onReply = { _ in replied = true }
            stream.ask(display: "Stream", prompt: "stream") { streamOutcomes.append(summary($0)) }
            try await settle { !streamOutcomes.isEmpty }
            expect(streamOutcomes == ["failed:Fixture stream failed"], provider + " streaming error is never task success")
            expect(!replied && !stream.busy, provider + " streaming error does not invoke successful onReply")
            expect(stream.messages.last?.text == "Something went wrong. Fixture stream failed", provider + " failure replaces the incomplete reply")
        }
        expect(StreamFixture.requests == 2, "both API streams use the local fixture without real network calls")
        print("Passed \(checks) chat lifecycle checks without model inference.")
    }
}
