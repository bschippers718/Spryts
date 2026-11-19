import Foundation

struct CodexFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A local JSON-RPC connection to the installed Codex agent. No credentials are read or copied.
final class CodexConnection {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var watchdog: Task<Void, Never>?
    var lines: AsyncLineSequence<FileHandle.AsyncBytes> { output.fileHandleForReading.bytes.lines }

    init(binary: String, folder: URL?, environment: [String: String] = [:]) throws {
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = folder
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        // Engine diagnostics can contain user content. Keep them out of application logs.
        process.standardError = FileHandle.nullDevice
        try process.run()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            self?.close()
        }
        try send(["id": 0, "method": "initialize", "params": [
            "clientInfo": ["name": "spryts", "title": "Spryts Studio", "version": "1.2.0"]
        ]])
    }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0a)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func ready() { watchdog?.cancel(); watchdog = nil }

    func close() {
        watchdog?.cancel()
        watchdog = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    deinit { close() }
}

enum CodexAgent {
    static var binary: String? {
        let home = NSHomeDirectory()
        let folders = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = folders.map { $0 + "/codex" } + [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @MainActor
    static func models() async throws -> [(id: String, label: String)] {
        guard let binary else { throw CodexFailure(message: "Install Codex, then check for models again.") }
        let connection = try CodexConnection(binary: binary, folder: nil)
        defer { connection.close() }
        var models: [(id: String, label: String)] = []
        for try await line in connection.lines {
            try Task.checkCancellation()
            guard let message = object(line) else { continue }
            if let error = message["error"] as? [String: Any] {
                throw CodexFailure(message: error["message"] as? String ?? "Codex couldn't list its models.")
            }
            guard let id = message["id"] as? Int, let result = message["result"] as? [String: Any] else { continue }
            if id == 0 {
                try connection.send(["method": "initialized", "params": [:]])
                try connection.send(["id": 1, "method": "model/list", "params": ["limit": 100]])
            } else if id == 1 {
                for model in result["data"] as? [[String: Any]] ?? [] {
                    guard let name = model["model"] as? String, !models.contains(where: { $0.id == name }) else { continue }
                    models.append((name, model["displayName"] as? String ?? name))
                }
                if let cursor = result["nextCursor"] as? String, !cursor.isEmpty {
                    try connection.send(["id": 1, "method": "model/list", "params": ["limit": 100, "cursor": cursor]])
                } else {
                    return models
                }
            }
        }
        throw CodexFailure(message: "Codex didn't return its models. Check its installation and sign-in.")
    }
}

extension ChatSession {
    @MainActor
    func runCodex(binary: String, prompt: String) async throws -> String {
        // Companions never acquire a tool-capable engine through a model setting.
        guard sheet.role == "coder" else { throw CodexFailure(message: "Codex is available in Nova's coding workspace.") }
        let folder = projectFolder ?? Harness.workspace
        try FileManager.default.createDirectory(at: Harness.workspace, withIntermediateDirectories: true)
        let connection = try CodexConnection(binary: binary, folder: folder, environment: teamEnvironment)
        process = connection.process
        var turnID: String?
        var threadID: String?
        cancelHarness = { [weak connection] in
            if let threadID, let turnID {
                try? connection?.send(["id": 99, "method": "turn/interrupt", "params": ["threadId": threadID, "turnId": turnID]])
            }
            // Closing the client also releases any unanswered approval requests.
            connection?.close()
        }
        defer {
            clearApprovals()
            connection.close()
            process = nil
            cancelHarness = nil
        }
        var text = ""
        var final = ""
        var currentMessage = ""
        var announced = false
        var pendingItems: [String: [String: Any]] = [:]
        for try await line in connection.lines {
            try Task.checkCancellation()
            if stopped { throw CancellationError() }
            guard let message = CodexAgent.object(line) else { continue }
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]

            // Server requests are answered through the same visible approval card as other engines.
            if let requestID = message["id"], !method.isEmpty {
                if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
                    let command = params["command"] as? String ?? ""
                    let cwd = params["cwd"] as? String ?? folder.path
                    let itemID = params["itemId"] as? String ?? ""
                    let item = pendingItems[itemID] ?? [:]
                    let changes = item["changes"] as? [[String: Any]] ?? []
                    let detail = method.contains("commandExecution") ? "Folder: " + cwd + "\n" + command
                        : changes.map { ($0["path"] as? String ?? "") + "\n" + String(($0["diff"] as? String ?? "").prefix(5000)) }.joined(separator: "\n")
                    let id = "codex-" + UUID().uuidString
                    let approval = Approval(id: id, sessionID: threadID ?? "", tool: method.contains("commandExecution") ? "Command" : "File changes",
                        detail: (params["reason"] as? String ?? "") + "\n" + (detail.isEmpty ? "Codex requests access outside the project." : detail))
                    approvalReplies[id] = { [weak connection] allow in
                        try? connection?.send(["id": requestID, "result": ["decision": allow ? "accept" : "decline"]])
                    }
                    request(approval)
                } else if method == "item/permissions/requestApproval" {
                    // Persistent permission expansion is not part of this adapter.
                    try connection.send(["id": requestID, "result": ["permissions": [:], "scope": "turn"]])
                } else {
                    try connection.send(["id": requestID, "error": ["code": -32601, "message": "This client doesn't support this request. Ask the user in your final reply instead."]])
                }
                continue
            }

            if let error = message["error"] as? [String: Any] {
                if message["id"] as? Int == 1 { harnessSession = nil }
                throw CodexFailure(message: error["message"] as? String ?? "Codex could not complete the request.")
            }
            if let id = message["id"] as? Int, let result = message["result"] as? [String: Any] {
                if id == 0 {
                    try connection.send(["method": "initialized", "params": [:]])
                    var options: [String: Any] = ["cwd": folder.path, "approvalPolicy": "untrusted", "approvalsReviewer": "user",
                        "sandbox": projectFolder == nil ? "read-only" : "workspace-write", "developerInstructions": harnessPrompt]
                    if !model.isEmpty { options["model"] = model }
                    if let saved = harnessSession { options["threadId"] = saved; options["excludeTurns"] = true }
                    try connection.send(["id": 1, "method": harnessSession == nil ? "thread/start" : "thread/resume", "params": options])
                } else if id == 1, let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String {
                    threadID = id
                    harnessSession = id
                    connection.ready()
                    try connection.send(["id": 2, "method": "turn/start", "params": ["threadId": id,
                        "input": [["type": "text", "text": prompt]]]])
                } else if id == 2, let turn = result["turn"] as? [String: Any] {
                    turnID = turn["id"] as? String
                }
                continue
            }
            // Subagent notifications must never finish or overwrite the parent task.
            if let eventThread = params["threadId"] as? String, eventThread != threadID { continue }
            if let eventTurn = params["turnId"] as? String, let turnID, eventTurn != turnID { continue }
            switch method {
            case "turn/started":
                turnID = (params["turn"] as? [String: Any])?["id"] as? String
            case "item/agentMessage/delta":
                let id = params["itemId"] as? String ?? ""
                if currentMessage != id { currentMessage = id; text = ""; announced = false }
                text += params["delta"] as? String ?? ""
                announced = show(text, announced: announced)
            case "turn/plan/updated":
                plan = (params["plan"] as? [[String: Any]] ?? []).enumerated().map { index, item in
                    let status = item["status"] as? String ?? "pending"
                    let title = item["step"] as? String ?? ""
                    return PlanItem(id: index, text: title, active: title, status: status == "completed" ? "done" : (status == "inProgress" ? "active" : "pending"))
                }
            case "item/started", "item/completed":
                guard let item = params["item"] as? [String: Any], let id = item["id"] as? String else { continue }
                pendingItems[id] = item
                let completed = method == "item/completed"
                let type = item["type"] as? String ?? ""
                if type == "agentMessage" {
                    if completed {
                        text = item["text"] as? String ?? text
                        if item["phase"] as? String != "commentary" { final = text }
                        announced = show(text, announced: announced)
                    }
                    continue
                }
                guard ["commandExecution", "fileChange", "webSearch", "mcpToolCall"].contains(type) else { continue }
                let command = item["command"] as? String ?? ""
                let kind = type == "commandExecution" ? Harness.kind(tool: "Bash", input: ["command": command]) : (type == "fileChange" ? "edit" : "search")
                let changes = item["changes"] as? [[String: Any]] ?? []
                let detail = type == "fileChange" ? changes.compactMap { $0["path"] as? String }.joined(separator: ", ")
                    : (command.isEmpty ? item["query"] as? String ?? item["tool"] as? String ?? type : command)
                let state = item["status"] as? String ?? ""
                let failed = state == "failed" || state == "declined" || ((item["exitCode"] as? Int ?? 0) != 0)
                let step = AgentStep(id: id, tool: type, detail: detail, state: completed ? (failed ? "failed" : "done") : "running",
                    kind: kind, path: changes.first?["path"] as? String ?? "", output: String((item["aggregatedOutput"] as? String ?? "").suffix(12000)))
                if let index = steps.firstIndex(where: { $0.id == id }) { steps[index] = step } else { steps.append(step) }
                lastEvent = Date()
                if completed {
                    if kind == "test" || kind == "build" { lastTest = (failed ? "failed: " : "passed: ") + kind }
                    if kind == "edit" && !failed {
                        editCount += changes.count
                        if let path = changes.last?["path"] as? String { touchedFile = URL(fileURLWithPath: path, relativeTo: folder).standardizedFileURL }
                    }
                    onEvent?(.toolResult(kind: kind, ok: !failed))
                } else { onEvent?(.tool(kind)) }
            case "turn/completed":
                let turn = params["turn"] as? [String: Any] ?? [:]
                let status = turn["status"] as? String ?? "failed"
                if status == "interrupted" { throw CancellationError() }
                guard status == "completed" else {
                    let error = turn["error"] as? [String: Any] ?? [:]
                    throw CodexFailure(message: error["message"] as? String ?? "Codex did not complete the task.")
                }
                guard !final.isEmpty else { throw CodexFailure(message: "Codex finished without a final answer.") }
                return final
            default: break
            }
        }
        if stopped || Task.isCancelled { throw CancellationError() }
        throw CodexFailure(message: "The Codex connection ended before the task completed. Check its sign-in and try again.")
    }
}
