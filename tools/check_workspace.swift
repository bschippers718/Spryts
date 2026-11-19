import Foundation

/// Run tools/check-workspace.command to exercise the production editor model.
@main
struct WorkspaceChecks {
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }

    private static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    static func main() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-draft-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = folder.appendingPathComponent("a.swift")
        let second = folder.appendingPathComponent("b.swift")
        try "let a = 1\n".write(to: first, atomically: true, encoding: .utf8)
        try "let b = 1\n".write(to: second, atomically: true, encoding: .utf8)
        let model = WorkspaceModel()
        model.reload(folder: folder)

        // Following another agent-touched file must preserve every human draft.
        model.open(first)
        model.fileText = "let a = 2\n"
        model.open(second)
        model.fileText = "let b = 2\n"
        expect(model.dirtyCount == 2, "Both edited files must be tracked")
        model.open(first)
        expect(model.fileText == "let a = 2\n", "Navigation discarded the first draft")
        expect(model.dirtyCount == 2, "Switching files changed the unsaved count")

        // A refresh after the agent edits the file cannot replace the draft.
        try "let a = 3\n".write(to: first, atomically: true, encoding: .utf8)
        model.refresh(folder: folder)
        expect(model.stale, "An external edit should appear as a conflict")
        expect(model.fileText == "let a = 2\n", "Refresh overwrote a dirty editor")
        expect(!model.save(), "Ordinary Save silently overwrote external edits")
        expect(model.dirty && model.saveError != nil, "Failed saves must retain edits and explain why")
        let external = try read(first)
        expect(external == "let a = 3\n", "Conflict refusal still changed the disk")

        model.open(second)
        expect(!model.saveAll(), "Save All must stop and reveal a conflicting file")
        expect(model.selected == first, "Save All should reveal the unresolved conflict")
        expect(model.dirtyCount == 2, "Save All lost an unsaved file")
        expect(model.save(overwrite: true), "An explicit overwrite should resolve the conflict")
        let overwritten = try read(first)
        expect(overwritten == "let a = 2\n", "Explicit overwrite did not save the draft")
        expect(model.saveAll(), "Save All failed after resolving its only conflict")
        expect(model.dirtyCount == 0, "Saved files are still marked dirty")
        let secondSaved = try read(second)
        expect(secondSaved == "let b = 2\n", "Save All skipped a hidden draft")

        // Switching projects must preserve drafts even with no document selected.
        model.open(first)
        model.fileText = "unsaved first project draft"
        model.reload(folder: nil)
        expect(model.dirtyCount == 1 && model.selected == nil, "Clearing the project discarded its draft")
        model.reload(folder: folder)
        model.open(first)
        expect(model.fileText == "unsaved first project draft", "Returning to a project discarded its draft")
        model.revert()
        expect(model.dirtyCount == 0 && model.fileText == "let a = 2\n", "Explicit reload failed to discard only its draft")

        // Simulate a write failure without depending on the account's privileges.
        model.fileText = "keep this after a failed write"
        try FileManager.default.removeItem(at: first)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        expect(!model.save(overwrite: true), "Writing a file over a directory should fail")
        expect(model.dirty && model.saveError != nil, "A write failure must remain unsaved and visible")
        expect(model.fileText == "keep this after a failed write", "Failed write lost the editor contents")
        model.open(second)
        model.fileText = "another unsaved draft"
        model.discardAll()
        expect(model.dirtyCount == 0, "Explicit Discard All did not clear every draft")
        expect(model.fileText == "let b = 2\n", "Discard All did not restore the selected file")

        // Read-only placeholders must never accidentally be saved over a file.
        let large = folder.appendingPathComponent("large.txt")
        try String(repeating: "x", count: 600_001).write(to: large, atomically: true, encoding: .utf8)
        model.open(large)
        expect(!model.editable && !model.dirty, "Oversized files must remain read-only")
        let binary = folder.appendingPathComponent("binary.bin")
        try Data([0xFF, 0xFE, 0xFF]).write(to: binary)
        model.open(binary)
        expect(!model.editable && !model.dirty, "Non-UTF-8 files must remain read-only")

        print("PASS: \(checks) workspace checks (navigation, following, conflicts, Save All, project changes, failed writes, discard and read-only files)")
    }
}
