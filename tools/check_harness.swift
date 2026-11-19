import Foundation

// The production runOnce method and AgentStep/PlanItem types are extracted by
// check-harness.command. These stubs replace UI notifications, account lookup,
// workspace setup, and semantic tool labels; none participate in stream parsing,
// completion, cancellation, subprocess cleanup, or diagnostic isolation.
struct HarnessTestSheet { var role: String? = "coder"; var id = "test" }
struct HarnessFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
enum Config { static func key(_ name: String) -> String? { nil } }
enum HarnessTestEvent { case tool(String); case toolResult(kind: String, ok: Bool) }
enum Harness {
    static var logs: [String] = []
    static let workspace = FileManager.default.temporaryDirectory
    static let grokWorkspace = workspace
    static let hookSettings = workspace.appendingPathComponent("unused")
    static let sharedFolders: [String] = []
    static let coderAllowed: [String] = []
    static let credentialVariables = ["ANTHROPIC_API_KEY"]
    static let grokSignedIn = true
    static func prepareWorkspace() throws {}
    static func trainingFolder(for id: String) -> URL { workspace }
    static func forecastFolder(for id: String) -> URL { workspace }
    static func officeFolder(for id: String) -> URL { workspace }
    static func log(_ text: String) { logs.append(text) }
    static func canonical(_ name: String) -> String { name }
    static func planItems(_ input: [String: Any]) -> [PlanItem]? { nil }
    static func kind(tool: String, input: [String: Any]) -> String { "run" }
    static func summarize(tool: String, input: [String: Any], limit: Int) -> String { tool }
}
final class ChatSession {
    var engine = "claude", harnessPrompt = "", model = ""
    var sheet = HarnessTestSheet()
    var projectFolder: URL?
    var harnessSession: String?
    var teamEnvironment: [String: String] = [:]
    var stopped = false
    var process: Process?
    var cancelHarness: (() -> Void)?
    var steps: [AgentStep] = []
    var plan: [PlanItem] = []
    var touchedFile: URL?
    var lastEvent = Date()
    var onEvent: ((HarnessTestEvent) -> Void)?
    var lastTest = ""
    var editCount = 0
    func show(_ text: String, announced: Bool) -> Bool { true }
    func checkGrokGate(since date: Date, usedTools: Bool) {}
    func grokArguments(prompt: String) throws -> [String] { [] }
}

@main
struct HarnessChecks {
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }

    @MainActor
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("harness-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func executable(_ name: String, _ body: String) throws -> String {
            let url = folder.appendingPathComponent(name)
            try ("#!/usr/bin/python3\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url.path
        }

        // These fixtures emit known stream records and never call a real engine.
        let good = try executable("good", "import json\nprint(json.dumps({'type':'result','result':'finished'}))\n")
        let crash = try executable("crash", "import json,sys\nprint(json.dumps({'type':'result','result':'partial'}))\nsys.exit(7)\n")
        let partial = try executable("partial", "import json\nprint(json.dumps({'type':'stream_event','event':{'delta':{'type':'text_delta','text':'partial'}}}))\n")
        let alpha = try executable("alpha", "import sys,time\nprint('ALPHA_PRIVATE',file=sys.stderr,flush=True)\ntime.sleep(.1)\nsys.exit(1)\n")
        let beta = try executable("beta", "import sys,time\nprint('BETA_PRIVATE',file=sys.stderr,flush=True)\ntime.sleep(.1)\nsys.exit(1)\n")
        let hanging = try executable("hang", """
        import json,signal,time
        signal.signal(signal.SIGINT,signal.SIG_IGN)
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        print(json.dumps({'type':'assistant','message':{'content':[{'type':'tool_use','id':'unfinished','name':'Bash','input':{}}]}}),flush=True)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline: time.sleep(.1)
        """ + "\n")

        let success = ChatSession()
        let result = try await success.runOnce(binary: good, prompt: "fixture", dropKeys: false)
        expect(result == "finished", "A successful terminal result was not returned")
        expect(success.process == nil && success.cancelHarness == nil, "Successful runs must release their process and cancel handler")

        for binary in [crash, partial] {
            let session = ChatSession()
            do {
                _ = try await session.runOnce(binary: binary, prompt: "fixture", dropKeys: false)
                fatalError("A failed exit or incomplete stream was reported as completed")
            } catch is HarnessFailure {
                expect(session.process == nil, "Failed runs must release their process")
            }
        }

        @Sendable @MainActor func failure(_ binary: String) async -> String {
            do {
                _ = try await ChatSession().runOnce(binary: binary, prompt: "fixture", dropKeys: false)
                return ""
            } catch { return error.localizedDescription }
        }
        async let first = failure(alpha)
        async let second = failure(beta)
        let errors = await (first, second)
        expect(errors.0.contains("ALPHA_PRIVATE") && !errors.0.contains("BETA_PRIVATE"), "First run received another run's diagnostics")
        expect(errors.1.contains("BETA_PRIVATE") && !errors.1.contains("ALPHA_PRIVATE"), "Second run received another run's diagnostics")
        expect(!Harness.logs.joined().contains("PRIVATE"), "Raw engine diagnostics leaked into application logs")

        let session = ChatSession()
        let task = Task { try await session.runOnce(binary: hanging, prompt: "fixture", dropKeys: false) }
        let readyBy = Date().addingTimeInterval(3)
        while session.steps.isEmpty && Date() < readyBy {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let process = session.process else { fatalError("The cancellation fixture never started") }
        expect(!session.steps.isEmpty, "The cancellation fixture never became ready")
        let began = Date()
        session.stopped = true
        session.cancelHarness?()
        task.cancel()
        do {
            _ = try await task.value
            fatalError("A cancelled task was reported as completed")
        } catch is CancellationError {}
        expect(!process.isRunning && session.process == nil, "A cancelled engine was left running")
        expect(session.cancelHarness == nil, "Cancellation left a stale process handler")
        expect(Date().timeIntervalSince(began) < 5, "An engine ignoring normal stop signals was not terminated promptly")
        expect(!session.steps.isEmpty && session.steps.allSatisfy { $0.state == "denied" }, "Unfinished cancelled tools must not appear completed")

        print("PASS: \(checks) harness checks (terminal completion, failed exits, incomplete streams, concurrent diagnostics, private logs and forced cancellation)")
    }
}
