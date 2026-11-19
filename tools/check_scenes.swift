import Foundation

@main
struct SceneChecks {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ why: String) {
        precondition(condition(), why)
        checks += 1
    }
    static func rejects(_ why: String, operation: () throws -> Void) {
        do { try operation(); preconditionFailure(why) }
        catch { checks += 1 }
    }

    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spryts-scenes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("chief/scenes.json")
        let store = PipSceneStore(file: file)
        let starters = PipSceneCatalog.builtIns
        expect(starters.count == 5 && Set(starters.map(\.id)).count == 5, "catalog has five distinct stable starter Scenes")
        expect(starters.map(\.name) == ["Start My Day", "Meeting Ready", "Project Launch", "Paperwork, Sorted", "Social Studio"],
               "the five starters match the agreed customer outcomes")
        expect(!FileManager.default.fileExists(atPath: file.path), "opening the catalog does not create user data")
        for scene in starters {
            let inputs = Dictionary(uniqueKeysWithValues: scene.inputs.filter(\.isRequired).map { ($0.id, "Fixture details for " + $0.label) })
            let request = try PipSceneRequestBuilder.build(scene: scene, inputs: inputs, apps: [], files: [])
            expect(request.contains(scene.outcome) && request.contains("No apps, services or accounts were selected"),
                   scene.name + " builds an honest text-only request when no sources are selected")
            expect(request.contains("one-time request") && request.contains("separate explicit review and authorization"),
                   scene.name + " does not silently schedule or authorize external changes")
        }

        let input = PipSceneInput(id: "topic", label: "Topic", placeholder: "What should be covered?", isRequired: true)
        let savedReference = root.appendingPathComponent("saved-reference.txt")
        let id = store.create(name: "  Client brief  ", outcome: "A clear client brief", instructions: "Use the supplied evidence.",
            desiredApps: ["Mail", "mail", "Notes"], referenceFiles: [savedReference, savedReference], inputs: [input], symbol: "doc.text")!
        expect(store.customScenes.count == 1 && store.scenes.count == 6 && store.customScenes[0].name == "Client brief",
               "creating a custom Scene adds it without altering the starter catalog")
        expect(store.customScenes[0].desiredApps == ["Mail", "Notes"] && store.customScenes[0].referenceFiles == [savedReference.path],
               "source suggestions and references are normalized without reading files")
        let reloaded = PipSceneStore(file: file)
        expect(reloaded.customScenes.first?.id == id && reloaded.customScenes.first?.inputs == [input]
               && reloaded.customScenes.first?.symbol == "doc.text", "custom setup fields, icon and identity survive restart")
        let custom = reloaded.customScenes[0]
        let textOnly = try PipSceneRequestBuilder.build(scene: custom, inputs: ["topic": "A launch"], apps: [], files: [])
        expect(!textOnly.contains(savedReference.path) && !textOnly.contains("- Mail"),
               "saved references and desired apps are never silently selected by the builder")
        let secondReference = root.appendingPathComponent("another-reference.txt")
        let selected = try PipSceneRequestBuilder.build(scene: custom, inputs: ["topic": "A launch"],
            apps: ["Notes", "Mail"], files: [savedReference, secondReference])
        let reordered = try PipSceneRequestBuilder.build(scene: custom, inputs: ["topic": "A launch"],
            apps: ["Mail", "Notes"], files: [secondReference, savedReference])
        expect(selected == reordered, "request preparation is deterministic for the same source sets")
        expect(selected.contains(savedReference.path) && selected.contains("access is unverified")
               && selected.contains("paths are references, not permission grants"), "selected sources are explicit references rather than access claims")
        rejects("required input cannot silently disappear") {
            _ = try PipSceneRequestBuilder.build(scene: custom, inputs: [:], apps: [], files: [])
        }
        rejects("unknown input values cannot silently disappear") {
            _ = try PipSceneRequestBuilder.build(scene: custom, inputs: ["topic": "Brief", "unknown": "Lost value"], apps: [], files: [])
        }
        rejects("remote URLs cannot masquerade as local file references") {
            _ = try PipSceneRequestBuilder.build(scene: custom, inputs: ["topic": "Brief"], apps: [], files: [URL(string: "https://example.com/private")!])
        }
        rejects("unbounded setup input is rejected") {
            _ = try PipSceneRequestBuilder.build(scene: custom, inputs: ["topic": String(repeating: "x", count: 6001)], apps: [], files: [])
        }
        let social = starters.first { $0.id == "starter.social-studio" }!
        let socialRequest = try PipSceneRequestBuilder.build(scene: social,
            inputs: ["brief": "A launch", "audience": "People trying the product"], apps: ["X / Twitter"], files: [])
        expect(socialRequest.contains("Cite source links or filenames and dates") && socialRequest.contains("Do not invent trending topics")
               && socialRequest.contains("Do not send, publish, schedule, like, repost, follow, unfollow or delete"),
               "Social Studio requires evidence and leaves account actions for explicit review")

        expect(!store.delete(starters[0].id), "starter Scene cannot be deleted")
        expect(!store.update(starters[0].id, name: "Changed", outcome: "Changed", instructions: "", desiredApps: [], referenceFiles: []),
               "starter Scene cannot be modified through custom CRUD")
        expect(PipSceneCatalog.builtIns == starters, "failed custom mutations leave all starter definitions unchanged")
        expect(store.create(name: "", outcome: "Result", instructions: "", desiredApps: [], referenceFiles: []) == nil,
               "invalid custom Scene is rejected before persistence")
        expect(store.create(name: "Invalid inputs", outcome: "Result", instructions: "", desiredApps: [], referenceFiles: [], inputs: [input, input]) == nil,
               "duplicate setup identifiers are rejected")

        // A failed update stays unpublished; retry must commit exactly the pending operation.
        let beforeFailure = store.customScenes
        let goodBytes = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        expect(!store.update(id, name: "Updated client brief", outcome: "A revised result", instructions: "Keep it short.",
            desiredApps: ["Files"], referenceFiles: [], inputs: [input]), "failed write rejects the custom update")
        expect(store.customScenes == beforeFailure && store.error != nil, "failed update preserves the published Scene and exposes the error")
        try FileManager.default.removeItem(at: file)
        try goodBytes.write(to: file)
        expect(store.retry() && store.customScenes[0].name == "Updated client brief" && store.error == nil,
               "retry persists the retained candidate after storage recovers")
        expect(PipSceneStore(file: file).customScenes.first?.name == "Updated client brief", "successful retry is durable")

        let beforeDiscard = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        expect(!store.update(id, name: "Abandoned edit", outcome: "Do not save", instructions: "", desiredApps: [], referenceFiles: [])
               && store.hasPendingWrite, "a failed editor save exposes a retryable candidate")
        store.discardPendingWrite()
        try FileManager.default.removeItem(at: file)
        try beforeDiscard.write(to: file)
        expect(!store.hasPendingWrite && store.retry() && store.customScenes[0].name == "Updated client brief",
               "discarding failed editor changes prevents later global retry from resurrecting them")

        // Corrupt input must remain byte-for-byte intact until corrected outside the store.
        let updatedBytes = try Data(contentsOf: file)
        let corruptBytes = Data("{ not readable".utf8)
        try corruptBytes.write(to: file)
        let unreadable = PipSceneStore(file: file)
        unreadable.discardPendingWrite()
        expect(unreadable.error != nil && unreadable.customScenes.isEmpty && unreadable.scenes.count == 5,
               "corrupt custom data stays protected when discarding editor state and leaves starters available")
        expect(unreadable.create(name: "Do not replace", outcome: "Result", instructions: "", desiredApps: [], referenceFiles: []) == nil,
               "unreadable originals cannot be overwritten by a new Scene")
        expect(!unreadable.retry(), "retry refuses data that is still corrupt")
        let stillCorrupt = try Data(contentsOf: file)
        expect(stillCorrupt == corruptBytes, "failed recovery never rewrites the damaged original")
        try updatedBytes.write(to: file)
        expect(unreadable.retry() && unreadable.customScenes.first?.id == id && unreadable.error == nil,
               "explicit retry rereads a repaired custom library")
        var spoofed = try JSONSerialization.jsonObject(with: updatedBytes) as! [String: Any]
        var records = spoofed["scenes"] as! [[String: Any]]
        records[0]["id"] = starters[0].id
        spoofed["scenes"] = records
        try JSONSerialization.data(withJSONObject: spoofed).write(to: file)
        expect(PipSceneStore(file: file).error != nil, "persisted custom data cannot replace a starter's reserved identity")
        try updatedBytes.write(to: file)
        expect(unreadable.delete(id) && unreadable.customScenes.isEmpty, "custom deletion is persisted without touching starters")
        expect(PipSceneStore(file: file).scenes == starters, "reopening after deletion restores the exact starter catalog")
        print("Passed \(checks) Scene checks using temporary data; no services or models were contacted.")
    }
}
