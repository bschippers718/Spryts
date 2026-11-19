import Foundation

// Minimal app dependencies; the ledger and queue under test are the production implementation.
enum ChatTaskOutcome { case completed(String), failed(String), interrupted }
enum Harness { static let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spryts-coordination-cli-" + UUID().uuidString) }

@main
struct TeamChecks {
    static var checks = 0
    static var temporaryDirectories: [URL] = []
    static func expect(_ condition: @autoclosure () -> Bool, _ why: String) {
        precondition(condition(), why)
        checks += 1
    }
    static func directory() throws -> URL {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spryts-team-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        temporaryDirectories.append(path)
        return path
    }
    static func request(_ folder: URL, to: String = "coder", task: String = "Fix the preview") throws -> String {
        let id = UUID().uuidString
        let item = Handoffs.Item(to: to, task: task, at: Date(), from: "pip", projectFolder: "/tmp/project")
        try JSONEncoder().encode(item).write(to: folder.appendingPathComponent(id + ".json"))
        return id
    }
    static func main() throws {
        defer {
            for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        }
        let folder = try directory()
        let id = try request(folder)
        let team = TeamCoordinator(folder: folder)
        team.refresh()
        expect(team.jobs.count == 1 && team.jobs[0].status == .queued, "request imported")
        expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(id + ".json").path), "inbox removed after durable import")
        expect(TeamCoordinator(folder: folder).jobs[0].id == id, "queued task survives relaunch")
        expect(team.update(id, status: .running), "running saved before dispatch")
        team.update(id, status: .waitingApproval)
        let recovered = TeamCoordinator(folder: folder)
        recovered.recoverInterrupted()
        expect(recovered.jobs[0].status == .interrupted, "unfinished work is interrupted, never replayed")
        expect(TeamCoordinator(folder: folder).jobs[0].status == .interrupted, "interruption persists")
        team.finish(id, outcome: .failed("Test command failed"))
        expect(team.jobs[0].status == .failed && team.jobs[0].result == nil, "failure does not become success")
        team.finish(id, outcome: .completed("Changed preview; tests passed"))
        expect(team.jobs[0].result == "Changed preview; tests passed", "final report kept")
        team.markReceiptDelivered(id)
        expect(TeamCoordinator(folder: folder).jobs[0].receiptDeliveredAt != nil, "receipt delivery persists")
        expect(team.context(for: "pip").contains("tests passed"), "sender model sees durable report")
        expect(team.context(for: "ember").isEmpty, "unrelated character receives no task contents")

        let brokenFolder = try directory()
        let queued = try request(brokenFolder)
        try Data("not a directory".utf8).write(to: brokenFolder.appendingPathComponent("jobs"))
        let broken = TeamCoordinator(folder: brokenFolder)
        broken.refresh()
        expect(broken.storageError != nil && broken.jobs.isEmpty, "storage failure exposed")
        expect(FileManager.default.fileExists(atPath: brokenFolder.appendingPathComponent(queued + ".json").path), "unsaved request remains queued")

        let malformedFolder = try directory()
        let badID = UUID().uuidString
        try Data("bad json".utf8).write(to: malformedFolder.appendingPathComponent(badID + ".json"))
        let malformed = TeamCoordinator(folder: malformedFolder)
        malformed.refresh()
        expect(malformed.jobs[0].status == .failed, "malformed requests remain visible as failures")

        let legacyFolder = try directory()
        let legacy = Handoffs.Item(to: "coder", task: "Legacy task", at: Date())
        try JSONEncoder().encode(legacy).write(to: legacyFolder.appendingPathComponent(UUID().uuidString + ".json"))
        let migrated = TeamCoordinator(folder: legacyFolder)
        migrated.refresh()
        expect(migrated.jobs[0].from == "generalist", "older handoff requests remain compatible")

        let damagedHistory = try directory()
        let history = damagedHistory.appendingPathComponent("jobs")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let damagedFile = history.appendingPathComponent(UUID().uuidString + ".json")
        try Data("damaged history".utf8).write(to: damagedFile)
        let damaged = TeamCoordinator(folder: damagedHistory)
        expect(damaged.storageError != nil, "damaged history is explicitly reported")
        expect(FileManager.default.fileExists(atPath: damagedFile.path), "damaged history remains recoverable")

        setenv("SPRYTS_CHARACTER_ROLE", "companion", 1)
        expect(Handoffs.send(["coder", "Do work"]) == 2, "companion cannot dispatch")
        setenv("SPRYTS_CHARACTER_ROLE", "coder", 1)
        setenv("SPRYTS_HANDOFF_ID", "existing", 1)
        expect(Handoffs.send(["generalist", "Do more work"]) == 2, "delegation cannot recurse")
        unsetenv("SPRYTS_HANDOFF_ID")
        unsetenv("SPRYTS_CHARACTER_ROLE")
        print("Passed \(checks) team coordination checks.")
    }
}
