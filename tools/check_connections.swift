import Foundation

@main
struct ConnectionChecks {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func application(_ root: URL, _ path: String, id: String, name: String) throws {
        let contents = root.appendingPathComponent(path).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spryts-connections-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications")
        try application(applications, "One.app", id: "test.one", name: "One")
        try application(applications, "Utilities/Two.app", id: "test.two", name: "Two")
        try application(applications, "Duplicate.app", id: "test.one", name: "Duplicate")
        try application(applications, ".Hidden.app", id: "test.hidden", name: "Hidden")
        try application(applications, "One.app/Contents/Helpers/Nested.app", id: "test.nested", name: "Nested")
        let outside = root.appendingPathComponent("Outside")
        try application(outside, "External.app", id: "test.external", name: "External")
        try FileManager.default.createSymbolicLink(at: applications.appendingPathComponent("LinkedDirectory"), withDestinationURL: outside)
        let scan = PipAppCatalog.scan(roots: [applications])
        expect(scan.apps.count == 2, "deduplicates bundle IDs and excludes hidden/nested/symlink-directory apps")
        expect(scan.apps.contains(where: { $0.name == "Two" }), "finds applications in utility folders")
        expect(!scan.limited, "ordinary scan is complete within its bounds")
        let shallow = PipAppCatalog.scan(roots: [applications], maximumDepth: 0)
        expect(shallow.apps.count == 1, "depth bound excludes utility folders")
        let limited = PipAppCatalog.scan(roots: [applications], maximumApps: 1)
        expect(limited.apps.count == 1 && limited.limited, "app cap is visible")
        let entries = PipAppCatalog.scan(roots: [applications], maximumEntries: 1)
        expect(entries.limited, "entry traversal is bounded")
        expect(PipAppCatalog.scan(roots: [root.appendingPathComponent("Missing")]).apps.isEmpty, "missing application folder is harmless")
        try FileManager.default.createSymbolicLink(at: applications.appendingPathComponent("External.app"),
                                                  withDestinationURL: outside.appendingPathComponent("External.app"))
        let appLink = PipAppCatalog.scan(roots: [applications])
        expect(appLink.apps.contains(where: { $0.bundleID == "test.external" }), "application symlinks are read as one bundle without traversing unrelated directories")

        let output = """
        Checking MCP server health...
        \u{001B}[32mcalendar: https://example.test/mcp?token=SECRET - ✓ Connected\u{001B}[0m
        mail: node server.js --header Authorization=SECRET - ! Needs authentication
        notes: https://example.test - ⏸ Pending approval (run claude to approve)
        disabled: command --api-key SECRET - ⊘ Disabled for this project
        broken: https://example.test/private - ✘ Failed to connect - HTTP 403 SECRET
        plugin:work:tasks: node --token SECRET - ✔ Connected
        odd: https://example.test - Disconnected
        Warning: Authorization=SECRET
        """
        let claude = PipConnectionParser.claude(output)
        expect(claude.recognized && claude.services.count == 6, "recognizes documented Claude statuses and plugin names")
        expect(claude.services.first(where: { $0.name == "calendar" })?.status == .connected, "ANSI output is parsed")
        expect(claude.services.first(where: { $0.name == "mail" })?.status == .needsSignIn, "sign-in is never reported connected")
        expect(claude.services.first(where: { $0.name == "notes" })?.status == .needsApproval, "approval status remains explicit")
        expect(claude.services.first(where: { $0.name == "broken" })?.status == .unavailable, "failed connection survives additional error delimiters")
        expect(!String(describing: claude.services).contains("SECRET"), "command arguments, endpoints and credentials never survive parsing")
        expect(!String(describing: claude.services).contains("https"), "endpoint URLs are omitted")
        expect(PipConnectionParser.claude("No MCP servers configured.").recognized, "recognized empty list is distinct from parser failure")
        expect(!PipConnectionParser.claude("unexpected private error text").recognized, "unknown output is not an empty-success result")
        expect(PipConnectionParser.safeName("https://user:secret@host") == nil, "URLs cannot be service names")
        expect(PipConnectionParser.safeName("Authorization: Bearer SECRET") == nil, "credential headers cannot be service names")
        expect(PipConnectionParser.safeName("name\nforged") == nil, "control characters cannot alter service labels")

        let grok = PipConnectionParser.grok(Data("""
        [{"name":"tasks","url":"https://example.test?token=SECRET","status":"connected"},
         {"name":"disabled","enabled":false,"env":{"TOKEN":"SECRET"}}]
        """.utf8))
        expect(grok.services.first(where: { $0.name == "tasks" })?.status == .configured, "Grok config listing never invents a healthy connection")
        expect(grok.services.first(where: { $0.name == "disabled" })?.status == .disabled, "disabled configuration is represented")
        expect(!String(describing: grok.services).contains("SECRET"), "Grok metadata is discarded")
        expect(PipConnectionParser.grok(Data("[]".utf8)).recognized, "installed Grok empty array format is recognized")
        expect(!PipConnectionParser.grok(Data("{\"error\":\"SECRET\"}".utf8)).recognized, "unrecognized JSON cannot become successful discovery")

        let service = try PipRemoteService(name: "work-notes", address: "https://example.test/mcp")
        expect(service.addArguments == ["mcp", "add", "--transport", "http", "--scope", "user", "work-notes", "https://example.test/mcp"],
               "setup uses verified structured arguments and explicit personal scope")
        for address in ["http://example.test/mcp", "file:///tmp/service", "https://user:password@example.test/mcp",
                        "https://example.test/mcp?token=SECRET", "https://example.test/mcp#SECRET", "https://example.test/sk-abcdefghijklmnop",
                        "https://example.test/mcp\n--header", "https://example.test:99999/mcp"] {
            expect((try? PipRemoteService(name: "notes", address: address)) == nil, "unsafe or credential-bearing address rejected")
        }
        for name in ["-flags", "x; rm -rf x", "bad name", "$(command)", String(repeating: "a", count: 65)] {
            expect((try? PipRemoteService(name: name, address: service.address)) == nil, "service name cannot become flags or shell syntax")
        }
        let saved = PipServiceSetup.save(service, engine: "claude", binary: "/fixture/claude", directory: root) { binary, args, _ in
            expect(binary == "/fixture/claude" && args == service.addArguments, "only requested engine receives add arguments")
            return PipConnectionCommand.Result(output: Data("Added HTTP MCP server work-notes with URL https://example.test/mcp to user config".utf8), exitCode: 0)
        }
        expect(saved.saved, "explicit successful Claude configuration is acknowledged")
        let unconfirmed = PipServiceSetup.save(service, engine: "claude", binary: "/fixture/claude", directory: root) { _, _, _ in
            PipConnectionCommand.Result(output: Data("The configuration may not have been saved".utf8), exitCode: 0)
        }
        expect(!unconfirmed.saved, "zero exit without save confirmation is not reported saved")
        let timeoutSave = PipServiceSetup.save(service, engine: "claude", binary: "/fixture/claude", directory: root) { _, _, _ in
            PipConnectionCommand.Result(timedOut: true)
        }
        expect(!timeoutSave.saved && timeoutSave.message.contains("may have been saved"), "timeout is explicitly uncertain and never automatically retried")
        var duplicateCalls = 0
        let duplicate = PipServiceSetup.save(service, engine: "grok", binary: "/fixture/grok", directory: root) { _, args, _ in
            duplicateCalls += 1
            expect(args == ["mcp", "list", "--json"], "duplicate protection only reads configuration")
            return PipConnectionCommand.Result(output: Data("[{\"name\":\"work-notes\",\"url\":\"https://private.test\"}]".utf8), exitCode: 0)
        }
        expect(!duplicate.saved && duplicateCalls == 1, "Grok's add-or-update never replaces a visible existing service")
        var grokCalls = 0
        let grokSave = PipServiceSetup.save(service, engine: "grok", binary: "/fixture/grok", directory: root) { _, args, _ in
            grokCalls += 1
            if grokCalls == 1 { return PipConnectionCommand.Result(output: Data("[]".utf8), exitCode: 0) }
            if grokCalls == 2 {
                expect(args == service.addArguments, "Grok uses the documented http and user flags")
                return PipConnectionCommand.Result(exitCode: 0)
            }
            return PipConnectionCommand.Result(output: Data("[{\"name\":\"work-notes\",\"url\":\"https://example.test/mcp\",\"scope\":\"user\"}]".utf8), exitCode: 0)
        }
        expect(grokSave.saved && grokCalls == 3, "Grok configuration is verified without a health check or sign-in")

        let command = PipConnectionCommand.run(binary: "/bin/echo", arguments: ["fixture"], directory: root)
        expect(command.exitCode == 0 && String(data: command.output, encoding: .utf8)?.contains("fixture") == true,
               "bounded process captures final output without logging")
        let timeout = PipConnectionCommand.run(binary: "/bin/sleep", arguments: ["5"], directory: root, timeout: 0.05)
        expect(timeout.timedOut, "hung listing is interrupted by deadline")
        print("Passed \(checks) connection catalog and parser checks.")
    }
}
