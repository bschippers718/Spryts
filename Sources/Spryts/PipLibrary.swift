import Foundation
import Combine

struct PipMessage: Codable, Equatable {
    var role: String
    var text: String
    var hidden: Bool
    var payload: String?
}

/// Everything that must travel with one conversation, including an unsent composer.
struct PipChatSnapshot: Codable, Equatable {
    var messages: [PipMessage]
    var draft: String
    var attachments: [String]
    var engine: String
    var model: String
    var sessionID: String?
    var folder: String?
    var facts: [String]
    var wasRunning: Bool

    static func empty(engine: String, model: String) -> PipChatSnapshot {
        PipChatSnapshot(messages: [], draft: "", attachments: [], engine: engine, model: model,
                        sessionID: nil, folder: nil, facts: [], wasRunning: false)
    }
}

enum PipSceneRunStatus: String, Codable {
    case prepared, running, responseReady, failed, interrupted
    var label: String {
        switch self {
        case .prepared: return "Draft ready"
        case .running: return "Working"
        case .responseReady: return "Response ready"
        case .failed: return "Needs attention"
        case .interrupted: return "Interrupted"
        }
    }
}

struct PipConversation: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var hasCustomTitle: Bool
    let createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var isArchived: Bool
    var projectID: String?
    var snapshot: PipChatSnapshot
    var sceneID: String? = nil
    var sceneRunStatus: PipSceneRunStatus? = nil
    var sceneStartedAt: Date? = nil
    var sceneFinishedAt: Date? = nil

    var preview: String {
        let text = snapshot.messages.last { !$0.hidden && !$0.text.isEmpty }?.text ?? snapshot.draft
        return String(text.replacingOccurrences(of: "\n", with: " ").prefix(160))
    }

    static func new(projectID: String?, snapshot: PipChatSnapshot) -> PipConversation {
        PipConversation(id: UUID().uuidString, title: "New chat", hasCustomTitle: false,
                        createdAt: Date(), updatedAt: Date(), isPinned: false, isArchived: false,
                        projectID: projectID, snapshot: snapshot)
    }
}

struct PipProject: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var instructions: String
    var contextFiles: [String]
    let createdAt: Date
    var updatedAt: Date
}

struct PipRelationship: Codable, Equatable {
    var affection: Double
    var firstMet: Date
    var lastSeen: Date?
}

private struct PipLibraryFile: Codable {
    var version = 1
    var activeConversationID: String?
    var conversations: [PipConversation]
    var projects: [PipProject]
    var relationship: PipRelationship
}

private struct PipLibraryFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The chief's local library. A single atomic file makes chat switching and project edits a
/// transaction: a failed write never publishes a partially changed selection or loses history.
final class PipLibrary: ObservableObject {
    @Published private(set) var conversations: [PipConversation] = []
    @Published private(set) var projects: [PipProject] = []
    @Published private(set) var activeConversationID: String?
    @Published private(set) var error: String?
    @Published private(set) var needsRecovery = false
    private var state: PipLibraryFile?
    private var legacyRecovery = false
    let file: URL

    var activeConversation: PipConversation? { conversations.first { $0.id == activeConversationID } }
    var activeProject: PipProject? { projects.first { $0.id == activeConversation?.projectID } }
    var relationship: PipRelationship? { state?.relationship }
    var needsLegacyRecovery: Bool { needsRecovery && legacyRecovery }

    func preventBootstrap(_ message: String) {
        guard state == nil, !needsRecovery else { return }
        needsRecovery = true
        legacyRecovery = true
        error = message
    }

    init(file: URL) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let stored = try decoder.decode(PipLibraryFile.self, from: Data(contentsOf: file))
            try Self.validate(stored)
            publish(stored)
        } catch {
            needsRecovery = true
            self.error = "Couldn't read your saved chats. The original file is untouched. " + error.localizedDescription
        }
    }

    private static func validate(_ candidate: PipLibraryFile) throws {
        let ids = candidate.conversations.map(\.id)
        let projectIDs = Set(candidate.projects.map(\.id))
        guard candidate.version == 1, Set(ids).count == ids.count,
              projectIDs.count == candidate.projects.count,
              let active = candidate.activeConversationID,
              candidate.conversations.contains(where: { $0.id == active && !$0.isArchived }),
              candidate.conversations.allSatisfy({ $0.projectID == nil || projectIDs.contains($0.projectID!) }) else {
            throw PipLibraryFailure(message: "The library format or its active conversation is invalid.")
        }
    }

    private func publish(_ candidate: PipLibraryFile) {
        state = candidate
        conversations = candidate.conversations
        projects = candidate.projects
        activeConversationID = candidate.activeConversationID
    }

    private func commit(_ candidate: PipLibraryFile, recovering: Bool = false) -> Bool {
        guard !needsRecovery || recovering else { return false }
        do {
            try Self.validate(candidate)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(candidate)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            publish(candidate)
            needsRecovery = false
            legacyRecovery = false
            error = nil
            return true
        } catch {
            self.error = "Couldn't save your chats. Your current conversation is still open. " + error.localizedDescription
            return false
        }
    }

    private func change(_ mutate: (inout PipLibraryFile) throws -> Void) -> Bool {
        guard var candidate = state else { return false }
        do { try mutate(&candidate) }
        catch { self.error = error.localizedDescription; return false }
        return commit(candidate)
    }

    /// Used exactly once when upgrading. The legacy memory file remains untouched as a fallback.
    @discardableResult
    func bootstrap(snapshot: PipChatSnapshot, relationship: PipRelationship) -> Bool {
        if state != nil { return true }
        guard !needsRecovery else { return false }
        var conversation = PipConversation.new(projectID: nil, snapshot: snapshot)
        Self.updateAutomaticTitle(&conversation)
        return commit(PipLibraryFile(activeConversationID: conversation.id, conversations: [conversation],
                                     projects: [], relationship: relationship))
    }

    /// Called only by the existing explicit Forget action, never by New chat.
    @discardableResult
    func forget(engine: String, model: String) -> Bool {
        let conversation = PipConversation.new(projectID: nil, snapshot: .empty(engine: engine, model: model))
        return commit(PipLibraryFile(activeConversationID: conversation.id, conversations: [conversation],
            projects: [], relationship: PipRelationship(affection: 0, firstMet: Date(), lastSeen: nil)))
    }

    @discardableResult
    func saveCurrent(snapshot: PipChatSnapshot, relationship: PipRelationship, sceneOutcome: PipSceneRunStatus? = nil) -> Bool {
        guard state != nil else { return bootstrap(snapshot: snapshot, relationship: relationship) }
        return change { candidate in
            guard let index = candidate.conversations.firstIndex(where: { $0.id == candidate.activeConversationID }) else {
                throw PipLibraryFailure(message: "Choose a conversation before saving.")
            }
            if candidate.conversations[index].snapshot != snapshot {
                candidate.conversations[index].snapshot = snapshot
                candidate.conversations[index].updatedAt = Date()
                Self.updateAutomaticTitle(&candidate.conversations[index])
            }
            candidate.relationship = relationship
            if candidate.conversations[index].sceneID != nil {
                if snapshot.wasRunning && snapshot.messages.last?.hidden == false
                    && candidate.conversations[index].sceneRunStatus != .running {
                    candidate.conversations[index].sceneRunStatus = .running
                    candidate.conversations[index].sceneStartedAt = Date()
                    candidate.conversations[index].sceneFinishedAt = nil
                }
                if let sceneOutcome {
                    candidate.conversations[index].sceneRunStatus = sceneOutcome
                    candidate.conversations[index].sceneFinishedAt = Date()
                }
            }
        }
    }

    /// Reopen only on an explicit retry. Validation and preservation of the live composer
    /// happen before publishing or replacing anything, so a second failure remains recoverable.
    @discardableResult
    func recoverFromDisk(preservingUnsent local: PipChatSnapshot) -> Bool {
        guard needsRecovery else { return false }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var candidate = try decoder.decode(PipLibraryFile.self, from: Data(contentsOf: file))
            try Self.validate(candidate)
            Self.markInterrupted(&candidate)
            Self.preserveUnsent(local, in: &candidate)
            return commit(candidate, recovering: true)
        } catch {
            self.error = "Couldn't reopen your saved chats. The original file and your unsent draft are untouched. " + error.localizedDescription
            return false
        }
    }

    @discardableResult
    func recoverLegacy(snapshot: PipChatSnapshot, relationship: PipRelationship, preservingUnsent local: PipChatSnapshot) -> Bool {
        guard needsLegacyRecovery, !FileManager.default.fileExists(atPath: file.path) else { return false }
        var conversation = PipConversation.new(projectID: nil, snapshot: snapshot)
        Self.updateAutomaticTitle(&conversation)
        var candidate = PipLibraryFile(activeConversationID: conversation.id, conversations: [conversation],
                                       projects: [], relationship: relationship)
        Self.preserveUnsent(local, in: &candidate)
        return commit(candidate, recovering: true)
    }

    func noteRecoveryError(_ message: String) { error = message }

    private static func preserveUnsent(_ local: PipChatSnapshot, in candidate: inout PipLibraryFile) {
        guard !local.draft.isEmpty || !local.attachments.isEmpty else { return }
        let saved = candidate.conversations.first { $0.id == candidate.activeConversationID }?.snapshot
        guard saved?.draft != local.draft || saved?.attachments != local.attachments else { return }
        // Do not combine two independent requests, or insert unknown local context into a
        // restored project. Both composers remain available as separate conversations.
        var snapshot = PipChatSnapshot.empty(engine: local.engine, model: local.model)
        snapshot.draft = local.draft
        snapshot.attachments = local.attachments
        var recovered = PipConversation.new(projectID: nil, snapshot: snapshot)
        recovered.title = "Recovered draft"
        recovered.hasCustomTitle = true
        candidate.conversations.insert(recovered, at: 0)
        candidate.activeConversationID = recovered.id
    }

    private static func updateAutomaticTitle(_ conversation: inout PipConversation) {
        guard !conversation.hasCustomTitle,
              let message = conversation.snapshot.messages.first(where: { $0.role == "user" && !$0.hidden && !$0.text.isEmpty }) else { return }
        let firstLine = message.text.split(separator: "\n").first.map(String.init) ?? message.text
        conversation.title = String(firstLine.prefix(100))
    }

    @discardableResult
    func startConversation(projectID: String?, engine: String, model: String) -> Bool {
        change { candidate in
            try Self.requireProject(projectID, in: candidate)
            let conversation = PipConversation.new(projectID: projectID, snapshot: .empty(engine: engine, model: model))
            candidate.conversations.insert(conversation, at: 0)
            candidate.activeConversationID = conversation.id
        }
    }

    /// Keep the reviewed request and its origin in the same transaction as its new chat.
    /// If this fails, the previous selection is unchanged and no engine can start work.
    @discardableResult
    func startPreparedConversation(title: String, request: String, projectID: String?, sceneID: String?,
                                   engine: String, model: String) -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Give this request a name and a description before starting."
            return false
        }
        guard name.count <= 120, request.count <= 120_000,
              sceneID.map({ !$0.isEmpty && $0.count <= 160 }) ?? true else {
            error = "This prepared request is too long. Shorten its name or description, then try again."
            return false
        }
        return change { candidate in
            try Self.requireProject(projectID, in: candidate)
            var snapshot = PipChatSnapshot.empty(engine: engine, model: model)
            snapshot.draft = request
            var conversation = PipConversation.new(projectID: projectID, snapshot: snapshot)
            conversation.title = name
            conversation.hasCustomTitle = true
            conversation.sceneID = sceneID
            if sceneID != nil { conversation.sceneRunStatus = .prepared }
            candidate.conversations.insert(conversation, at: 0)
            candidate.activeConversationID = conversation.id
        }
    }

    @discardableResult
    func activate(_ id: String) -> Bool {
        change { candidate in
            guard let conversation = candidate.conversations.first(where: { $0.id == id }), !conversation.isArchived else {
                throw PipLibraryFailure(message: "Restore this conversation from the archive before opening it.")
            }
            candidate.activeConversationID = id
        }
    }

    @discardableResult
    func rename(_ id: String, title: String) -> Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 120 else { error = "Give the chat a name of 1 to 120 characters."; return false }
        return change { candidate in
            guard let index = candidate.conversations.firstIndex(where: { $0.id == id }) else {
                throw PipLibraryFailure(message: "This conversation is no longer available.")
            }
            candidate.conversations[index].title = clean
            candidate.conversations[index].hasCustomTitle = true
        }
    }

    @discardableResult
    func pin(_ id: String, pinned: Bool) -> Bool {
        change { candidate in
            guard let index = candidate.conversations.firstIndex(where: { $0.id == id }) else {
                throw PipLibraryFailure(message: "This conversation is no longer available.")
            }
            candidate.conversations[index].isPinned = pinned
        }
    }

    @discardableResult
    func archive(_ id: String, archived: Bool) -> Bool {
        change { candidate in
            guard let index = candidate.conversations.firstIndex(where: { $0.id == id }) else {
                throw PipLibraryFailure(message: "This conversation is no longer available.")
            }
            candidate.conversations[index].isArchived = archived
            if archived && candidate.activeConversationID == id {
                if let next = candidate.conversations.filter({ !$0.isArchived }).max(by: { $0.updatedAt < $1.updatedAt }) {
                    candidate.activeConversationID = next.id
                } else {
                    let previous = candidate.conversations[index]
                    let next = PipConversation.new(projectID: previous.projectID,
                        snapshot: .empty(engine: previous.snapshot.engine, model: previous.snapshot.model))
                    candidate.conversations.insert(next, at: 0)
                    candidate.activeConversationID = next.id
                }
            }
        }
    }

    @discardableResult
    func move(_ id: String, projectID: String?) -> Bool {
        change { candidate in
            try Self.requireProject(projectID, in: candidate)
            guard let index = candidate.conversations.firstIndex(where: { $0.id == id }) else {
                throw PipLibraryFailure(message: "This conversation is no longer available.")
            }
            guard candidate.conversations[index].projectID != projectID else { return }
            candidate.conversations[index].projectID = projectID
            candidate.conversations[index].snapshot.sessionID = nil
            candidate.conversations[index].updatedAt = Date()
        }
    }

    func createProject(name: String, instructions: String, files: [URL]) -> String? {
        do {
            let values = try Self.projectValues(name: name, instructions: instructions, files: files)
            let project = PipProject(id: UUID().uuidString, name: values.0, instructions: values.1,
                                     contextFiles: values.2, createdAt: Date(), updatedAt: Date())
            guard change({ $0.projects.append(project) }) else { return nil }
            return project.id
        } catch { self.error = error.localizedDescription; return nil }
    }

    @discardableResult
    func updateProject(_ id: String, name: String, instructions: String, files: [URL]) -> Bool {
        do {
            let values = try Self.projectValues(name: name, instructions: instructions, files: files)
            return change { candidate in
                guard let index = candidate.projects.firstIndex(where: { $0.id == id }) else {
                    throw PipLibraryFailure(message: "This project is no longer available.")
                }
                candidate.projects[index].name = values.0
                candidate.projects[index].instructions = values.1
                candidate.projects[index].contextFiles = values.2
                candidate.projects[index].updatedAt = Date()
                // A resumed model must not retain superseded project instructions or references.
                for i in candidate.conversations.indices where candidate.conversations[i].projectID == id {
                    candidate.conversations[i].snapshot.sessionID = nil
                }
            }
        } catch { self.error = error.localizedDescription; return false }
    }

    private static func requireProject(_ id: String?, in candidate: PipLibraryFile) throws {
        guard let id else { return }
        guard candidate.projects.contains(where: { $0.id == id }) else {
            throw PipLibraryFailure(message: "This project is no longer available.")
        }
    }

    private static func projectValues(name: String, instructions: String, files: [URL]) throws -> (String, String, [String]) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 120, instructions.count <= 16_000, files.count <= 32,
              files.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }) else {
            throw PipLibraryFailure(message: "Use a project name up to 120 characters, instructions up to 16,000 characters, and at most 32 local reference files.")
        }
        var seen = Set<String>()
        let paths = files.map { $0.standardizedFileURL.path }.filter { seen.insert($0).inserted }
        return (clean, instructions.trimmingCharacters(in: .whitespacesAndNewlines), paths)
    }

    func conversations(matching query: String, projectID: String? = nil, archived: Bool = false) -> [PipConversation] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return conversations.filter { conversation in
            guard conversation.isArchived == archived, projectID == nil || conversation.projectID == projectID else { return false }
            guard !terms.isEmpty else { return true }
            let text = conversation.title + "\n" + conversation.snapshot.draft + "\n"
                + conversation.snapshot.messages.filter { !$0.hidden }.map(\.text).joined(separator: "\n")
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    /// Only this project's explicit references enter the prompt. They remain paths, not grants:
    /// the engine must read relevant files through its ordinary tools and approval boundary.
    var projectContext: String {
        guard let project = activeProject else { return "" }
        var context = "\n\nCurrent project: " + project.name + ". Use this project's context for this conversation only."
        if !project.instructions.isEmpty { context += "\nProject instructions from the person:\n" + project.instructions }
        if !project.contextFiles.isEmpty {
            context += "\nProject reference files (read relevant files when needed; references do not grant write access):\n"
                + project.contextFiles.map { "- " + $0 }.joined(separator: "\n")
        }
        context += "\nDo not use another project's instructions, references or conversation. Existing approvals and tool restrictions still apply."
        return context
    }

    @discardableResult
    func recoverInterruptedConversation() -> Bool {
        guard activeConversation?.snapshot.wasRunning == true else { return true }
        return change { Self.markInterrupted(&$0) }
    }

    private static func markInterrupted(_ candidate: inout PipLibraryFile) {
        guard let index = candidate.conversations.firstIndex(where: { $0.id == candidate.activeConversationID }),
              candidate.conversations[index].snapshot.wasRunning else { return }
        candidate.conversations[index].snapshot.wasRunning = false
        candidate.conversations[index].snapshot.sessionID = nil
        if candidate.conversations[index].sceneRunStatus == .running {
            candidate.conversations[index].sceneRunStatus = .interrupted
            candidate.conversations[index].sceneFinishedAt = Date()
        }
        candidate.conversations[index].snapshot.messages.append(PipMessage(role: "assistant",
            text: "This conversation was interrupted when Spryts closed. No work was restarted.", hidden: false))
    }
}
