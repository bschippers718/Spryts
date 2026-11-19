import Foundation

// Lightweight application dependencies. The real CodexAgent.swift owns all transport, protocol,
// lifecycle and approval routing exercised below; this harness never starts a real model.
struct CharacterSheet { var role: String? = "coder" }
struct AgentStep {
    let id: String; let tool: String; let detail: String; let state: String
    let kind: String; let path: String; let output: String
}
struct PlanItem { let id: Int; let text: String; let active: String; let status: String }
struct Approval { let id: String; let sessionID: String; let tool: String; let detail: String }
enum ChatEvent { case tool(String), toolResult(kind: String, ok: Bool) }
enum Harness {
    static let workspace = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spryts-codex-workspace-" + UUID().uuidString)
    static func kind(tool: String, input: [String: Any]) -> String {
        (input["command"] as? String ?? "").contains("test") ? "test" : "run"
    }
}
final class ChatSession {
    var sheet = CharacterSheet()
    var projectFolder: URL?
    var teamEnvironment: [String: String] = [:]
    var process: Process?
    var cancelHarness: (() -> Void)?
    var stopped = false
    var harnessSession: String?
    var harnessPrompt = "Test specialist instructions"
    var model = "test-model"
    var steps: [AgentStep] = []
    var plan: [PlanItem] = []
    var lastEvent = Date.distantPast
    var lastTest = ""
    var editCount = 0
    var touchedFile: URL?
    var onEvent: ((ChatEvent) -> Void)?
    var approvalReplies: [String: (Bool) -> Void] = [:]
    var approvalChoice = true
    var cancelOnApproval = false
    var approvals: [Approval] = []
    var shown: [String] = []
    func clearApprovals() { approvalReplies.removeAll() }
    func show(_ text: String, announced: Bool) -> Bool { shown.append(text); return true }
    func request(_ approval: Approval) {
        approvals.append(approval)
        if cancelOnApproval {
            stopped = true
            cancelHarness?()
            return
        }
        approvalReplies.removeValue(forKey: approval.id)?(approvalChoice)
    }
}

@main
struct CodexChecks {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ why: String) {
        precondition(condition(), why)
        checks += 1
    }

    // Fake JSON-RPC peer. Assertions validate what the production adapter actually sends.
    static let peer = #"""
#!/usr/bin/python3
import json, os, sys
scenario = os.environ['SPRYTS_TEST_SCENARIO']
audit = os.environ['SPRYTS_TEST_AUDIT']
thread = 'thread-root'

def send(message):
    print(json.dumps(message), flush=True)

def note(method, params, owner=thread):
    send({'method': method, 'params': dict(params, threadId=owner)})

def finish(text='Verified result', status='completed'):
    note('item/completed', {'item': {'id': 'reply', 'type': 'agentMessage', 'phase': 'final_answer', 'text': text}})
    note('turn/completed', {'turn': {'id': 'turn-root', 'status': status, 'error': {'message': 'Fixture failure'}}})

pending = set()
for raw in sys.stdin:
    message = json.loads(raw)
    with open(audit, 'a') as log:
        log.write(json.dumps(message) + '\n')
    method = message.get('method')
    params = message.get('params', {})
    if method == 'initialize':
        assert params['clientInfo']['name'] == 'spryts'
        send({'id': message['id'], 'result': {}})
    elif method == 'initialized':
        pass
    elif method in ('thread/start', 'thread/resume'):
        assert params['approvalPolicy'] == 'untrusted'
        assert params['approvalsReviewer'] == 'user'
        assert params['developerInstructions'] == 'Test specialist instructions'
        assert params['model'] == 'test-model'
        assert params['sandbox'] == ('read-only' if scenario == 'readonly' else 'workspace-write')
        if scenario == 'resume-error':
            assert method == 'thread/resume' and params['threadId'] == 'expired-thread'
            send({'id': message['id'], 'error': {'code': -32000, 'message': 'Saved thread was not found'}})
            continue
        send({'id': message['id'], 'result': {'thread': {'id': thread}}})
    elif method == 'turn/start':
        assert params['threadId'] == thread
        assert params['input'][0]['text'] == 'Test the adapter'
        send({'id': message['id'], 'result': {'turn': {'id': 'turn-root'}}})
        note('turn/started', {'turn': {'id': 'turn-root'}})
        if scenario == 'failed':
            finish(status='failed')
        elif scenario == 'interrupted':
            finish(status='interrupted')
        elif scenario == 'disconnect':
            sys.exit(0)
        elif scenario == 'empty':
            note('turn/completed', {'turn': {'id': 'turn-root', 'status': 'completed'}})
        elif scenario in ('accept', 'decline', 'file-approval', 'cancel'):
            file_change = scenario == 'file-approval'
            item = {'id': 'work', 'type': 'fileChange' if file_change else 'commandExecution', 'status': 'inProgress'}
            item.update({'changes': [{'path': '/tmp/approved.txt', 'diff': '+approved'}]} if file_change else {'command': 'swift test'})
            note('item/started', {'item': item})
            send({'id': 'approval-request', 'method': 'item/fileChange/requestApproval' if file_change else 'item/commandExecution/requestApproval',
                  'params': {'threadId': thread, 'turnId': 'turn-root', 'itemId': 'work', 'command': 'swift test', 'cwd': '/tmp', 'reason': 'Fixture approval'}})
        elif scenario == 'deny-unsupported':
            pending = {'permissions', 'unknown'}
            send({'id': 'permissions', 'method': 'item/permissions/requestApproval', 'params': {'threadId': thread, 'turnId': 'turn-root', 'itemId': 'permissions'}})
            send({'id': 'unknown', 'method': 'future/unknownRequest', 'params': {'threadId': thread}})
        elif scenario == 'wrong-thread':
            note('item/completed', {'item': {'id': 'other-message', 'type': 'agentMessage', 'text': 'WRONG THREAD'}}, owner='other-thread')
            note('turn/completed', {'turn': {'id': 'other-turn', 'status': 'completed'}}, owner='other-thread')
            finish()
        else:
            note('item/agentMessage/delta', {'itemId': 'commentary', 'delta': 'Reading the code'})
            note('item/completed', {'item': {'id': 'commentary', 'type': 'agentMessage', 'phase': 'commentary', 'text': 'Reading the code'}})
            note('turn/plan/updated', {'plan': [{'step': 'Test the change', 'status': 'inProgress'}]})
            note('item/started', {'item': {'id': 'test', 'type': 'commandExecution', 'status': 'inProgress', 'command': 'swift test'}})
            note('item/completed', {'item': {'id': 'test', 'type': 'commandExecution', 'status': 'completed', 'command': 'swift test', 'exitCode': 0, 'aggregatedOutput': 'All tests passed'}})
            note('item/completed', {'item': {'id': 'edit', 'type': 'fileChange', 'status': 'completed', 'changes': [{'path': 'Example.swift', 'diff': '+fixed'}]}})
            finish()
    elif message.get('id') == 'approval-request':
        decision = message['result']['decision']
        assert decision == ('decline' if scenario == 'decline' else 'accept')
        note('item/completed', {'item': {'id': 'work', 'type': 'commandExecution', 'status': 'declined' if decision == 'decline' else 'completed', 'command': 'swift test', 'exitCode': None if decision == 'decline' else 0}})
        finish('Declined by the user' if decision == 'decline' else 'Approved work finished')
    elif message.get('id') in pending:
        key = message['id']
        if key == 'permissions':
            assert message['result']['permissions'] == {} and message['result']['scope'] == 'turn'
        else:
            assert message['error']['code'] == -32601
        pending.remove(key)
        if not pending:
            finish('Unsupported requests were denied')
"""#

    @MainActor
    static func main() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spryts-codex-peer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: Harness.workspace)
        }
        let binary = folder.appendingPathComponent("fake-codex")
        try peer.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        for scenario in ["success", "readonly", "accept", "decline", "file-approval", "deny-unsupported", "wrong-thread", "failed", "interrupted", "disconnect", "empty", "resume-error", "cancel"] {
            let session = ChatSession()
            if scenario != "readonly" { session.projectFolder = folder }
            session.teamEnvironment = ["SPRYTS_TEST_SCENARIO": scenario, "SPRYTS_TEST_AUDIT": folder.appendingPathComponent(scenario + ".jsonl").path]
            session.approvalChoice = scenario != "decline"
            session.cancelOnApproval = scenario == "cancel"
            if scenario == "resume-error" { session.harnessSession = "expired-thread" }
            let mustFail = ["failed", "interrupted", "disconnect", "empty", "resume-error", "cancel"].contains(scenario)
            do {
                let result = try await session.runCodex(binary: binary.path, prompt: "Test the adapter")
                expect(!mustFail, scenario + " must not return success")
                expect(!result.isEmpty, scenario + " returns a final report")
                if scenario == "success" {
                    expect(result == "Verified result", "commentary must not become final answer")
                    expect(session.shown.contains("Reading the code"), "streaming commentary reaches the UI")
                    expect(session.steps.count == 2 && session.steps.allSatisfy { $0.state == "done" }, "tool started and completed updates share one step")
                    expect(session.lastTest == "passed: test" && session.editCount == 1, "tests and edits update workspace state")
                    expect(session.plan.first?.status == "active", "plan status maps to workspace status")
                }
                if scenario == "wrong-thread" {
                    expect(result == "Verified result" && !session.shown.contains("WRONG THREAD"), "other-thread events never finish or replace the active task")
                }
                if ["accept", "decline", "file-approval"].contains(scenario) {
                    expect(session.approvals.count == 1, "server request routes through the approval callback")
                    if scenario == "decline" { expect(session.steps.first?.state == "failed", "declined command is not marked successful") }
                    if scenario == "file-approval" { expect(session.approvals[0].detail.contains("approved.txt"), "file approval shows planned changes") }
                }
            } catch {
                expect(mustFail, scenario + " unexpectedly failed: " + error.localizedDescription)
                if scenario == "interrupted" || scenario == "cancel" { expect(error is CancellationError, "interruption remains cancellation") }
                if scenario == "failed" { expect(error.localizedDescription.contains("Fixture failure"), "failed turn preserves its error") }
                if scenario == "disconnect" { expect(error.localizedDescription.contains("ended before"), "disconnect cannot report a completed turn") }
                if scenario == "empty" { expect(error.localizedDescription.contains("without a final answer"), "empty final is explicitly rejected") }
                if scenario == "resume-error" {
                    expect(error.localizedDescription.contains("Saved thread"), "resume rejection remains visible")
                    expect(session.harnessSession == nil, "invalid saved thread is cleared for the next attempt")
                }
            }
            expect(session.process == nil && session.cancelHarness == nil && session.approvalReplies.isEmpty, scenario + " releases process and approval callbacks")
        }
        print("Passed \(checks) Codex protocol checks without model inference.")
    }
}
