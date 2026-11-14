import Foundation

/// Which agent runs behind the characters: Claude Code or Grok. One choice for everyone,
/// unless a character's sheet pins it with "harness": "grok".
enum Engine {
    static var current: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: "engine") { return saved }
            if Harness.claudePath == nil && Harness.grokPath != nil { return "grok" }
            return "claude"
        }
        set { UserDefaults.standard.set(newValue, forKey: "engine") }
    }

    static var name: String { current == "grok" ? "Grok" : "Claude" }
}

extension Harness {
    /// Where the `grok` command lives on this Mac, or nil if it isn't installed.
    static var grokPath: String? = Harness.findGrok()

    static func findGrok() -> String? {
        let home = NSHomeDirectory()
        var folders = [home + "/.grok/bin", home + "/.local/bin"]
        folders += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders += ["/opt/homebrew/bin", "/usr/local/bin", home + "/bin"]
        for folder in folders {
            let path = folder + "/grok"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// True when Grok has a saved sign-in. Only checks that the file is there; never reads it.
    static var grokSignedIn: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.grok/auth.json")
    }

    /// Grok runs in its own empty folder, so it never picks up the Claude Code settings in the other one.
    static var grokWorkspace: URL { support.appendingPathComponent("workspace-grok") }
    static var grokGate: URL { support.appendingPathComponent("approve-grok.sh") }
    static var grokSessions: URL { approvals.appendingPathComponent("grok-sessions") }
    static var grokCanary: URL { approvals.appendingPathComponent("grok-gate-alive") }
    static var grokHookFile: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/hooks/spryts.json")
    }
    /// Set when a run used tools but the gate never fired, so later runs stop auto-approving.
    static var grokGateBroken = false

    /// Grok's tool names, as the names the rest of Spryts already understands.
    static func canonical(_ tool: String) -> String {
        switch tool {
        case "run_terminal_command", "run_terminal_cmd", "bash": return "Bash"
        case "read_file": return "Read"
        case "search_replace", "write_file", "edit_file", "apply_patch": return "Edit"
        case "grep": return "Grep"
        case "list_dir", "glob": return "LS"
        case "web_search": return "WebSearch"
        case "web_fetch": return "WebFetch"
        case "spawn_subagent": return "Task"
        default: return tool
        }
    }

    /// Installs the gate Grok calls before every tool. Grok has no hook that waits on a permission prompt,
    /// so Spryts runs it in always-approve mode and this gate is what asks the person.
    /// The gate does nothing at all for Grok sessions Spryts did not start.
    static func prepareGrok() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: grokSessions, withIntermediateDirectories: true)
        try fm.createDirectory(at: grokWorkspace, withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        # Spryts gate for Grok. Sessions Spryts didn't start are left alone.
        DIR="$HOME/Library/Application Support/Spryts/approvals"
        INPUT="$(cat)"
        SID="$(printf '%s' "$INPUT" | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)"
        if [ -z "$SID" ] || [ ! -f "$DIR/grok-sessions/$SID" ]; then
          printf '{"decision":"defer"}\\n'
          exit 0
        fi
        touch "$DIR/grok-gate-alive"
        TOOL="$(printf '%s' "$INPUT" | sed -n 's/.*"toolName"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)"
        case "$TOOL" in
          read_file|grep|list_dir|web_search|web_fetch)
            printf '{"decision":"allow"}\\n'
            exit 0
            ;;
        esac
        ID="$(uuidgen)"
        printf '%s' "$INPUT" > "$DIR/$ID.tmp" && mv "$DIR/$ID.tmp" "$DIR/$ID.request"
        ANSWER=""
        for i in $(seq 1 2700); do
          if [ -f "$DIR/$ID.decision" ]; then
            ANSWER="$(cat "$DIR/$ID.decision")"
            break
          fi
          sleep 0.2
        done
        rm -f "$DIR/$ID.decision" "$DIR/$ID.request" "$DIR/$ID.tmp"
        if [ "$ANSWER" = "allow" ]; then
          printf '{"decision":"allow"}\\n'
        else
          printf '{"decision":"deny","reason":"The person declined this in Spryts. Do not retry it; tell them briefly."}\\n'
        fi
        exit 0
        """
        try script.write(to: grokGate, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: grokGate.path)

        // The gate gives up and declines after nine minutes; the hook's own limit is ten, so it never times out open.
        let hooks: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["hooks": [["type": "command", "command": "\"" + grokGate.path + "\"", "timeout": 600]]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: hooks, options: [.prettyPrinted])
        try fm.createDirectory(at: grokHookFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? Data(contentsOf: grokHookFile)) != data {
            try data.write(to: grokHookFile, options: .atomic)
        }
    }
}

extension ChatSession {
    /// The agent behind this character.
    var engine: String { sheet.harness == "grok" ? "grok" : Engine.current }

    static let grokModels: [(id: String, label: String)] = [
        ("grok-default", "Grok default"),
        ("grok-4.6", "Grok 4.6"),
        ("grok-4.5", "Grok 4.5"),
    ]

    /// The command line for one turn through Grok.
    func grokArguments(prompt: String) throws -> [String] {
        var gated = false
        if !Harness.grokGateBroken {
            do {
                try Harness.prepareGrok()
                gated = true
            } catch {
                Harness.log("grok: could not install the approval gate: " + String(error.localizedDescription.prefix(200)))
            }
        }
        // A new conversation gets an id chosen here, so the gate can tell it is one of ours from its first tool call.
        try? FileManager.default.createDirectory(at: Harness.grokWorkspace, withIntermediateDirectories: true)
        let fresh = harnessSession == nil
        let id = harnessSession ?? UUID().uuidString.lowercased()
        harnessSession = id
        FileManager.default.createFile(atPath: Harness.grokSessions.appendingPathComponent(id).path, contents: nil)

        var arguments = ["-p", prompt.hasPrefix("-") ? " " + prompt : prompt,
                         "--output-format", "streaming-messages-json", "--include-partial-messages",
                         "--rules", harnessPrompt,
                         "--no-auto-update",
                         "--cwd", (projectFolder ?? Harness.grokWorkspace).path]
        arguments += fresh ? ["-s", id] : ["-r", id]
        if gated {
            // Every tool call goes through the gate, which asks the person in Spryts.
            arguments += ["--always-approve"]
        } else {
            // No gate: reading only. Anything that would need a click is refused by Grok itself.
            arguments += ["--allow", "Read", "--allow", "Grep"]
        }
        if sheet.role == "coach" {
            try FileManager.default.createDirectory(at: Harness.trainingFolder(for: sheet.id), withIntermediateDirectories: true)
        }
        if sheet.role == "forecaster" {
            try FileManager.default.createDirectory(at: Harness.forecastFolder(for: sheet.id), withIntermediateDirectories: true)
        }
        if model.hasPrefix("grok-") && model != "grok-default" { arguments += ["-m", model] }
        return arguments
    }

    /// What Grok may do without a click, matching what the Claude Code setup allows silently.
    func grokAllows(_ item: Approval) -> Bool {
        if item.danger { return false }
        if item.tool == "Edit" {
            if item.path.isEmpty { return false }
            let path = URL(fileURLWithPath: item.path).standardizedFileURL.path
            if sheet.role == "coach" && path.hasPrefix(Harness.trainingFolder(for: sheet.id).standardizedFileURL.path + "/") { return true }
            if sheet.role == "forecaster" && path.hasPrefix(Harness.forecastFolder(for: sheet.id).standardizedFileURL.path + "/") { return true }
            if sheet.role == "coder", let folder = projectFolder, path.hasPrefix(folder.standardizedFileURL.path + "/") { return true }
            return false
        }
        if item.tool == "Bash" {
            // The same few commands Claude Code runs without a click: switching apps, and Pip's focus tools.
            if item.auto { return true }
            if sheet.role != "coder" || projectFolder == nil { return false }
            let command = item.command
            if [";", "|", "&", ">", "<", "$(", "`"].contains(where: { command.contains($0) }) { return false }
            for rule in Harness.coderAllowed {
                // "Bash(swift build *)" allows "swift build" and anything after it.
                var prefix = rule.replacingOccurrences(of: "Bash(", with: "")
                prefix = prefix.replacingOccurrences(of: " *)", with: "").replacingOccurrences(of: ")", with: "")
                if command == prefix || command.hasPrefix(prefix + " ") { return true }
            }
            return false
        }
        // Reading, searching, planning and the like.
        return !item.tool.lowercased().contains("mcp")
    }

    /// After a Grok run: if tools ran but the gate never fired, stop trusting always-approve.
    func checkGrokGate(since start: Date, usedTools: Bool) {
        if !usedTools || Harness.grokGateBroken { return }
        let seen = (try? FileManager.default.attributesOfItem(atPath: Harness.grokCanary.path))?[.modificationDate] as? Date
        if seen == nil || (seen ?? Date.distantPast) < start.addingTimeInterval(-2) {
            Harness.grokGateBroken = true
            Harness.log("grok: tools ran but the approval gate never fired; switching to read-only runs")
        }
    }
}
