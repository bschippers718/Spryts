import Foundation

/// One thing the agent did during a task, shown in the command panel.
struct AgentStep: Identifiable, Equatable {
    let id: String
    var tool: String
    var detail: String
    var state: String   // running, done, failed, denied
    var kind: String = "other"   // read, search, edit, run, build, test, web, other
    var path: String = ""
    var before: String = ""
    var after: String = ""
    var output: String = ""
}

/// A past conversation with the agent in a project folder.
struct Conversation: Identifiable, Equatable {
    let id: String
    let title: String
    let date: Date
    let file: URL
}

/// A risky action the agent wants to take, waiting for the person's answer.
struct Approval: Identifiable, Equatable {
    let id: String
    let sessionID: String
    let tool: String
    let detail: String
    let danger: Bool      // destructive or outbound: always asks, never remembered
    let auto: Bool        // harmless enough to allow without asking
    let grantKey: String  // what "allow for this task" remembers
    let path: String      // the file an edit touches, if any
    let command: String   // the shell command, if any

    /// What "always allow" would cover, in a few words for the button.
    var grantLabel: String {
        if grantKey.hasPrefix("Bash:") { return "`" + String(grantKey.dropFirst(5)) + "` commands" }
        if tool == "Edit" || tool == "Write" || tool == "MultiEdit" { return "file edits" }
        return tool
    }

    init(id: String, sessionID: String, tool: String, input: [String: Any]) {
        self.path = input["file_path"] as? String ?? input["path"] as? String ?? input["target_file"] as? String ?? ""
        self.command = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.sessionID = sessionID
        self.tool = tool
        self.detail = Harness.summarize(tool: tool, input: input, limit: 400)

        var danger = false
        var auto = false
        var key = tool
        if tool == "Bash" {
            let command = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = command.lowercased()
            let first = lower.split(separator: " ").first.map(String.init) ?? ""
            key = "Bash:" + first
            let chained = [";", "|", "&", ">", "<", "$(", "`"].contains(where: { command.contains($0) })
            // Opening or switching to an app is the one shell action that never needs a click.
            // Pip's own focus tools only hide, show and reopen things, and every step can be undone.
            let focusTool = command.hasPrefix(Harness.focusCommand + " ") || command.hasPrefix(Harness.selfPath + " focus ")
            auto = !chained && (lower.hasPrefix("open -a ") || lower.hasPrefix("open -b ") || focusTool)
            let risky = ["rm ", "rm\t", "rmdir", "sudo", "trash", "diskutil", "kill", "shutdown", "reboot", "halt",
                         "dd ", "mkfs", "git push", "curl", "wget", "ssh ", "scp ", "rsync", "mail", "send", "delete",
                         "empty", "erase", "chmod -r", "chown", "defaults write", "launchctl", "pmset", "keystroke",
                         "key code", "format", "purchase", "pay", "post ", "tweet", "> /", "mv "]
            danger = risky.contains(where: { lower.contains($0) })
        } else if tool == "WebFetch" || tool == "WebSearch" {
            auto = true
        } else if tool.hasPrefix("mcp__") {
            let lower = tool.lowercased()
            danger = ["send", "delete", "remove", "trash", "post", "pay", "create", "update", "command"].contains(where: { lower.contains($0) })
        }
        self.danger = danger
        self.auto = auto && !danger
        self.grantKey = key
    }
}

private struct HarnessFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Everything about running Claude Code as the engine behind a character.
enum Harness {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Spryts")
    }()
    static var workspace: URL { support.appendingPathComponent("workspace") }
    static var approvals: URL { support.appendingPathComponent("approvals") }
    static var hookScript: URL { support.appendingPathComponent("approve.sh") }

    /// Where the `claude` command lives on this Mac, or nil if it isn't installed.
    static var claudePath: String? = Harness.findClaude()

    static func findClaude() -> String? {
        let home = NSHomeDirectory()
        // The current installer's locations come first, so an old copy elsewhere on the PATH doesn't win.
        var folders = [home + "/.local/bin", home + "/.claude/local"]
        folders += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders += ["/opt/homebrew/bin", "/usr/local/bin", home + "/.npm-global/bin", home + "/.bun/bin", home + "/bin"]
        for folder in folders {
            let path = folder + "/claude"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Last resort: ask a login shell.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        do {
            try shell.run()
            // Reading to the end waits for the shell without spinning the run loop. Waiting on the process
            // itself would let the interface redraw mid-lookup, ask for this same value, and deadlock.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let found = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if found.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: found) { return found }
        } catch {
            return nil
        }
        return nil
    }

    /// What sort of work a tool call is, so the character can act it out.
    static func kind(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Read", "NotebookRead":
            return "read"
        case "Glob", "Grep", "LS":
            return "search"
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return "edit"
        case "WebSearch", "WebFetch":
            return "web"
        case "Bash":
            let command = (input["command"] as? String ?? "").lowercased()
            if ["test", "pytest", "jest", "vitest", "rspec"].contains(where: { command.contains($0) }) { return "test" }
            if ["build", "compile", "make", "tsc", "cargo check", "lint"].contains(where: { command.contains($0) }) { return "build" }
            return "run"
        default:
            return "other"
        }
    }

    /// The same permission hook as the workspace uses, as a settings file that can be passed to any project.
    static var hookSettings: URL { support.appendingPathComponent("hook-settings.json") }

    /// Commands a coder may run in its project without asking: builds, tests and read-only git.
    static let coderAllowed = [
        "Bash(swift build *)", "Bash(swift test *)", "Bash(swift build)", "Bash(swift test)",
        "Bash(npm test *)", "Bash(npm test)", "Bash(npm run test *)", "Bash(npm run build *)", "Bash(npm run lint *)",
        "Bash(pnpm test *)", "Bash(pnpm test)", "Bash(yarn test *)", "Bash(yarn test)",
        "Bash(pytest *)", "Bash(pytest)", "Bash(python -m pytest *)", "Bash(python3 -m pytest *)",
        "Bash(cargo test *)", "Bash(cargo test)", "Bash(cargo build *)", "Bash(cargo build)", "Bash(cargo check *)",
        "Bash(go test *)", "Bash(go build *)", "Bash(make test)", "Bash(make build)", "Bash(make)",
        "Bash(git status *)", "Bash(git status)", "Bash(git diff *)", "Bash(git diff)", "Bash(git log *)", "Bash(git log)"
    ]

    /// Where Claude Code keeps the conversations for a folder.
    static func transcriptFolder(for folder: URL) -> URL {
        var name = ""
        for ch in folder.path {
            name.append(ch.isLetter || ch.isNumber ? ch : "-")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects").appendingPathComponent(name)
    }

    private static func texts(in line: String) -> (role: String, text: String)? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let obj = object as? [String: Any],
              let type = obj["type"] as? String, type == "user" || type == "assistant",
              (obj["isMeta"] as? Bool) != true,
              (obj["isSidechain"] as? Bool) != true,
              let message = obj["message"] as? [String: Any] else { return nil }
        var text = ""
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks where (block["type"] as? String) == "text" {
                text += (block["text"] as? String ?? "")
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("<") { return nil }
        return (type, text)
    }

    /// Recent conversations in a project folder, newest first, titled by their first message.
    static func conversations(for folder: URL) -> [Conversation] {
        let fm = FileManager.default
        let dir = transcriptFolder(for: folder)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var found: [Conversation] = []
        for file in files where file.pathExtension == "jsonl" {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            found.append(Conversation(id: file.deletingPathExtension().lastPathComponent, title: "", date: date, file: file))
        }
        found.sort(by: { $0.date > $1.date })
        var out: [Conversation] = []
        for item in found.prefix(12) {
            var title = "Untitled"
            if let handle = try? FileHandle(forReadingFrom: item.file) {
                let head = handle.readData(ofLength: 60_000)
                try? handle.close()
                let lines = (String(data: head, encoding: .utf8) ?? "").split(separator: "\n")
                for line in lines {
                    if let entry = texts(in: String(line)), entry.role == "user" {
                        title = String(entry.text.split(separator: "\n").first ?? "")
                        break
                    }
                }
            }
            if title.count > 60 { title = String(title.prefix(60)) + "…" }
            out.append(Conversation(id: item.id, title: title, date: item.date, file: item.file))
        }
        return out
    }

    /// The readable messages of a past conversation, for showing in the chat when it is resumed.
    static func transcript(of conversation: Conversation) -> [ChatMessage] {
        guard let text = try? String(contentsOf: conversation.file, encoding: .utf8) else { return [] }
        var out: [ChatMessage] = []
        for line in text.split(separator: "\n") {
            guard let entry = texts(in: String(line)) else { continue }
            let shown = entry.role == "assistant" ? ChatSession.strip(entry.text).text : entry.text
            if shown.isEmpty { continue }
            out.append(ChatMessage(role: entry.role, text: shown))
        }
        return Array(out.suffix(40))
    }

    /// Environment variables that override the saved Claude Code login when they are set.
    static let credentialVariables = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"]

    /// Appends a line to harness.log in the Spryts folder. Never logs keys or message text.
    static func log(_ line: String) {
        let file = Config.home.appendingPathComponent("harness.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = stamp + "  " + line.replacingOccurrences(of: "\n", with: " ") + "\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 200_000 {
            try? FileManager.default.removeItem(at: file)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    /// Where the forecaster keeps today's forecast and the week's outlook.
    static func forecastFolder(for id: String) -> URL {
        support.appendingPathComponent("forecast").appendingPathComponent(id)
    }

    /// This program, so agents can call its built-in tools.
    static let selfPath: String = Bundle.main.executablePath ?? CommandLine.arguments[0]
    /// Pip's focus tools as a shell command, quoted in case the path has spaces.
    static var focusCommand: String { "'" + selfPath + "' focus" }

    /// Where a coach keeps its profile, log and plan for this person.
    static func trainingFolder(for id: String) -> URL {
        support.appendingPathComponent("training").appendingPathComponent(id)
    }

    /// Folders the agent may read without asking.
    static var sharedFolders: [String] {
        let home = NSHomeDirectory()
        return [home + "/Desktop", home + "/Documents", home + "/Downloads"]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Sets up the folder the agent runs in, with a hook that routes every permission request to Spryts.
    static func prepareWorkspace() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: workspace.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try fm.createDirectory(at: approvals, withIntermediateDirectories: true)

        // The hook writes the request to a file and waits for Spryts to write the answer next to it.
        let script = """
        #!/bin/bash
        DIR="$HOME/Library/Application Support/Spryts/approvals"
        mkdir -p "$DIR"
        ID="$(uuidgen)"
        cat > "$DIR/$ID.tmp" && mv "$DIR/$ID.tmp" "$DIR/$ID.request"
        ANSWER=""
        for i in $(seq 1 1400); do
          if [ -f "$DIR/$ID.decision" ]; then
            ANSWER="$(cat "$DIR/$ID.decision")"
            break
          fi
          sleep 0.2
        done
        rm -f "$DIR/$ID.decision" "$DIR/$ID.request"
        if [ "$ANSWER" = "allow" ]; then
          printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\\n'
        else
          printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"The person declined this in Spryts. Do not retry it; tell them briefly."}}}\\n'
        fi
        """
        try script.write(to: hookScript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScript.path)

        let settings: [String: Any] = [
            "hooks": [
                "PermissionRequest": [
                    [
                        "matcher": "*",
                        "hooks": [
                            ["type": "command", "command": "\"" + hookScript.path + "\"", "timeout": 300]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try data.write(to: workspace.appendingPathComponent(".claude").appendingPathComponent("settings.json"), options: .atomic)
        try data.write(to: hookSettings, options: .atomic)
    }

    /// Permission requests that have arrived since the last look.
    static func newRequests(seen: inout Set<String>) -> [Approval] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: approvals, includingPropertiesForKeys: nil) else { return [] }
        var out: [Approval] = []
        for file in files where file.pathExtension == "request" {
            let id = file.deletingPathExtension().lastPathComponent
            if seen.contains(id) { continue }
            seen.insert(id)
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let obj = object as? [String: Any] else { continue }
            // Claude Code and Grok spell the same three fields differently.
            out.append(Approval(
                id: id,
                sessionID: obj["session_id"] as? String ?? obj["sessionId"] as? String ?? "",
                tool: Harness.canonical(obj["tool_name"] as? String ?? obj["toolName"] as? String ?? "tool"),
                input: obj["tool_input"] as? [String: Any] ?? obj["toolInput"] as? [String: Any] ?? [:]))
        }
        return out
    }

    static func answer(_ id: String, allow: Bool) {
        let file = approvals.appendingPathComponent(id + ".decision")
        try? (allow ? "allow" : "deny").write(to: file, atomically: true, encoding: .utf8)
    }

    /// A one-line description of a tool call.
    static func summarize(tool: String, input: [String: Any], limit: Int) -> String {
        var text = ""
        if let command = input["command"] as? String {
            text = command
        } else if let path = input["file_path"] as? String ?? input["path"] as? String ?? input["target_file"] as? String {
            text = path
        } else if let pattern = input["pattern"] as? String {
            text = pattern
        } else if let url = input["url"] as? String {
            text = url
        } else if let query = input["query"] as? String {
            text = query
        } else if let description = input["description"] as? String {
            text = description
        }
        text = text.replacingOccurrences(of: "\n", with: " ")
        if text.count > limit { text = String(text.prefix(limit)) + "…" }
        return text
    }
}

extension ChatSession {
    /// The harness to use for this character, if it has one and it is installed.
    func harnessBinary() -> String? {
        guard sheet.harness != nil else { return nil }
        return engine == "grok" ? Harness.grokPath : Harness.claudePath
    }

    var harnessPrompt: String {
        var prompt = systemPrompt
        if sheet.role == "writer" {
            prompt += "\n\nYou are the engine behind \(sheet.name), this person's writing partner. You care about clear thinking and sentences that sound like a person. "
            prompt += "When asked to continue, tighten, expand, rewrite or proofread, reply with only the resulting text after the mood tag: no preamble, no quotation marks around it, no commentary. "
            prompt += "Match the requested voice exactly, and never flatten the writer's own voice into something generic. "
            prompt += "For critique, outlines and titles, be brief, specific and honest: say what doesn't work as plainly as what does. "
            prompt += "Do not use tools unless asked to read or save a file."
            return prompt
        }
        if sheet.role == "coder" {
            prompt += "\n\nYou are the engine behind \(sheet.name), this person's coding specialist. You own one repository at a time."
            if let folder = projectFolder {
                prompt += " You are working in " + folder.path + "."
            } else {
                prompt += " No project folder is assigned yet; ask for one before making changes."
            }
            prompt += " Work like a careful senior engineer: read before you edit, keep changes small and focused, match the code's existing style, "
            prompt += "run the build or tests after changing things, and say plainly what you changed and whether it passed. "
            prompt += "Never claim something works unless you ran it. Edits inside the project and builds and tests run without asking; "
            prompt += "commits ask, and pushes always ask. Stay inside the project folder."
            prompt += "\n\nReplies are shown in a workspace with full markdown: use short paragraphs, fenced code blocks with a language, and diffs where they help. "
            prompt += "Keep prose brief; the code and results are what matter. The mood tag goes on the first line of your final reply only."
            return prompt
        }
        if sheet.role == "forecaster" {
            let folder = Harness.forecastFolder(for: sheet.id).path
            prompt += "\n\nYou are the engine behind \(sheet.name), this person's weather forecaster. Weather is your whole job: "
                + "what the sky is doing where they live, today and over the next five days, and what that means for their day. "
                + "The app fetches the real forecast and gives it to you at the end of this message. Answer from those numbers only. "
                + "Never invent a temperature, a chance of rain or a day you were not given, and never use numbers from an earlier reply: the forecast below is the current one."
                + "\nYou keep two files in " + folder + ":"
                + "\n- place.txt: the city or town they are in, the name alone on one line. When they tell you where they are, or travel, write it here; the app then fetches that place."
                + "\n- notes.md: what matters to them about weather. For example they run cold, cycle to work, have a dog to walk, or hate wind."
                + "\nWrite to those two without asking. Don't touch files anywhere else."
                + "\n\nHow to forecast:"
                + "\n- Lead with the answer, then the one number behind it. 'Yes, take an umbrella: 70% chance of rain this afternoon.'"
                + "\n- Turn numbers into decisions: what to wear, whether to carry a layer, the best window for a walk or a run, which day to pick for something outdoors."
                + "\n- Use their notes. Someone who runs cold gets the extra layer suggested sooner."
                + "\n- Be honest about distance: today and tomorrow are firm, days four and five are a lean, not a promise."
                + "\n- Past five days, or for another place, say you only have five days for the place on file, and offer to switch place."
                + "\n- Severe weather (storms, extreme heat or cold, anything that sounds dangerous): say so plainly and point them to their official weather service for warnings. You are not a warning service."
                + "\n- You only do weather. If asked to plan their work or their week, say that's not your sky, and give the weather for it instead."
                + "\n\nReplies appear in a small chat bubble. Keep chat to one to three sentences; a five-day rundown can be one short line a day. "
                + "The mood tag goes on the first line of your final reply only."
            prompt += SkyState.briefing.isEmpty
                ? "\n\nThe forecast right now: none yet, because no place is set. Ask which city or town they are in, then write place.txt."
                : "\n\nThe forecast right now:\n" + SkyState.briefing
            return prompt
        }
        if sheet.role == "coach" {
            let journal = Harness.trainingFolder(for: sheet.id).path
            prompt += "\n\nYou are the engine behind \(sheet.name), this person's fitness coach. You keep a training journal in " + journal + ":"
                + "\n- profile.md: who they are as an athlete. Goals, experience, sports they like and hate, schedule, equipment, injuries and limits, and how they like to be coached."
                + "\n- log.md: one line per session, newest last. Every line starts with the date as YYYY-MM-DD, then what was done, for how long, and how it felt. The app counts these lines for the weekly total and the streak, so log only real sessions here."
                + "\n- plan.md: the current plan, with the reasoning behind it and the date it was set."
                + "\n- strava.md, if it exists: their real Strava activities for the last 60 days with weekly totals, refreshed by the app before each conversation. Read it, never edit it, and trust it over memory. Don't copy Strava sessions into log.md unless they ask."
                + "\n- health.md, if it exists: your summary of their Apple Health export (see below)."
                + "\nRead all of these at the start of any conversation about training, and keep your own files up to date. They are your memory between conversations. "
                + "Write to them without asking. Don't touch files anywhere else unless asked."
                + "\n\nHow to coach:"
                + "\n- Find their level before prescribing. If profile.md is thin, ask two or three quick questions (goal, current week of activity, time and equipment, anything that hurts), never a questionnaire."
                + "\n- Workouts on the fly: when they say what they have (\"20 minutes, hotel room, no kit\"), give a workout straight away, set out as warm-up, main set and cool-down, with reps or times, rest, and an easier and a harder option for each move."
                + "\n- Their data: they may paste numbers or attach exports (CSV, GPX, FIT, TCX, screenshots, notes from Strava, Garmin, Apple Health, Whoop, Peloton and the like). "
                + "Read them, and use python3 for anything bigger than a glance. Report what the data actually shows (volume, intensity, consistency, trends, gaps) before recommending anything, and log the summary."
                + "\n- Apple Health: a Mac has no Health data, so it arrives as the iPhone export (Health app, profile picture, Export All Health Data), a zip with export.xml inside. "
                + "When they attach it, unzip it to a temporary folder, stream export.xml with python3 xml.etree.ElementTree.iterparse (it can be hundreds of megabytes; never read it whole), "
                + "and write health.md in your journal folder: the last 90 days of workouts (date, type, duration, distance, energy), daily steps as weekly averages, and the latest resting heart rate, HRV, VO2 max and body weight if present. "
                + "Then delete the unzipped copy. If they haven't connected Strava or sent a Health export and their history matters, tell them once how to do it, in one line."
                + "\n- Plans: progressive overload of roughly 10% or less a week in volume, a lighter week every three to five, hard days separated by easy ones, at least one full rest day, and strength work two or three times a week for nearly everyone. "
                + "Tie every plan to their stated goal and the time they really have, and say what you'll judge it by and when you'll review it."
                + "\n- Fat loss: a modest deficit (about 300 to 500 kcal a day, or 0.5 to 1% of body weight a week), enough protein (about 1.6 g per kg of body weight), strength work to keep muscle, sleep and steps. "
                + "Focus on habits over numbers if they prefer. Never suggest crash diets, fasting extremes, or eating below roughly 1200 kcal a day for women or 1500 for men."
                + "\n- Meet them where they are. A beginner gets small wins and no jargon. A serious athlete gets zones, paces, RPE, periodisation and blunt feedback. Ask which they want if it's unclear."
                + "\n- Safety: you're a coach, not a doctor. Sharp or worsening pain, chest pain, dizziness, fainting, or a recent injury, pregnancy or medical condition means you scale back and tell them to see a professional. "
                + "If talk about food or weight sounds like disordered eating, drop the numbers, be kind, and point them gently to support."
                + "\n\nReplies appear in a chat bubble. Keep chat to one to four sentences. Workouts and plans may use short lists, never tables. "
                + "The mood tag goes on the first line of your final reply only."
            return prompt
        }
        prompt += "\n\nYou are the engine behind \(sheet.name), who acts as this person's command center for their Mac. "
            + "Replies appear in a small chat bubble: one to four short sentences of plain text, no headings, tables or code blocks unless asked. "
            + "The mood tag goes on the first line of your final reply only."
        prompt += "\n\nYou can control this Mac with the Bash tool:"
            + "\n- `open -a \"App Name\"` launches or switches to an app; `open <file or url>` opens things."
            + "\n- `osascript -e '...'` scripts apps (Finder, Safari, Mail, Calendar, Music, Notes, Reminders, System Events)."
            + "\n- `shortcuts list` and `shortcuts run \"Name\"` use the person's Shortcuts."
            + "\n- `screencapture -x /tmp/spryts-screen.png`, then read that file, to see what is on screen."
            + "\n\nFocus tools, for when they're overwhelmed, distracted, or coming back to something. Run them as `" + Harness.focusCommand + " <command>`; each prints one line to pass on:"
            + "\n- `sweep` hides every app except the one they've been working in over the last 20 minutes. It guesses; don't ask first. Add `--keep \"App\"` if they named what to focus on. Never quit apps to declutter: hiding loses nothing."
            + "\n- `back` undoes the sweep exactly. `show` says what's open now."
            + "\n- `save \"Name\"` remembers what's open (apps, browser tabs, documents); `restore \"Name\"`, `list` and `forget \"Name\"` use those."
            + "\n- `whereami` says what was open before they last stepped away; `putback` reopens it."
            + "\nThese never need a click. Say what was done in one sentence, using the tool's words, and never claim more than the tool reported."
            + "\nThe person approves risky actions by clicking a button, so act directly instead of asking in text first. "
            + "If an action is declined, do not retry it; say so in a few words. "
            + "Never delete, send, post or pay for anything unless that is clearly what was asked."
        if let context = contextProvider?(), !context.isEmpty {
            prompt += "\n\nRight now: " + context
        }
        return prompt
    }

    /// Runs one turn through Claude Code and returns the final reply text.
    @MainActor
    func runHarness(binary: String, prompt: String) async throws -> String {
        // The coach sees fresh Strava data on either engine. Does nothing when Strava isn't connected.
        if sheet.role == "coach" { await Strava.shared.sync(for: sheet.id) }
        if engine == "grok" {
            do {
                return try await runOnce(binary: binary, prompt: prompt, dropKeys: false)
            } catch {
                let text = error.localizedDescription.lowercased()
                if text.contains("401") || text.contains("authentication") || text.contains("login") || text.contains("sign in") {
                    throw HarnessFailure(message: "Grok's sign-in has expired. Use Connect in the ✦ menu to sign in again, then ask me again.")
                }
                throw error
            }
        }
        let environment = ProcessInfo.processInfo.environment
        let hasKey = Harness.credentialVariables.contains(where: { environment[$0] != nil })
        do {
            return try await runOnce(binary: binary, prompt: prompt, dropKeys: false)
        } catch {
            let text = error.localizedDescription.lowercased()
            let signIn = text.contains("401") || text.contains("authentication") || text.contains("invalid api key")
                || text.contains("/login") || text.contains("oauth")
            if !signIn { throw error }
            if hasKey {
                // A stale key or token in the shell environment overrides the saved Claude Code login. Try again without it.
                Harness.log("sign-in failed with a credential in the environment; retrying with the saved Claude Code login")
                steps = []
                do {
                    return try await runOnce(binary: binary, prompt: prompt, dropKeys: true)
                } catch {
                    Harness.log("retry without the key also failed: " + String(error.localizedDescription.prefix(300)))
                }
            }
            throw HarnessFailure(message: "Claude Code's saved sign-in has expired. Open Terminal, run `claude`, type /login and finish signing in, then ask me again.")
        }
    }

    @MainActor
    private func runOnce(binary: String, prompt: String, dropKeys: Bool) async throws -> String {
        try Harness.prepareWorkspace()

        let grok = engine == "grok"
        let began = Date()
        var arguments: [String] = []
        if grok {
            arguments = try grokArguments(prompt: prompt)
        } else {
        arguments = ["-p", prompt.hasPrefix("-") ? " " + prompt : prompt,
                         "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--append-system-prompt", harnessPrompt]
        if projectFolder != nil {
            // An assigned project: the hook comes in as extra settings, since we don't write into the project.
            arguments += ["--settings", Harness.hookSettings.path]
            if sheet.role == "coder" {
                arguments += ["--permission-mode", "acceptEdits", "--allowedTools", Harness.coderAllowed.joined(separator: ",")]
            }
        } else {
            for folder in Harness.sharedFolders { arguments += ["--add-dir", folder] }
            if sheet.role == "coach" {
                // The coach's journal is its own: it may write there without a click. A leading // is an absolute path.
                let journal = Harness.trainingFolder(for: sheet.id)
                try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
                arguments += ["--add-dir", journal.path, "--allowedTools", "Edit(/" + journal.path + "/**)"]
            }
            if sheet.role == "forecaster" {
                // The forecaster's two files are its own, so it may write there without a click.
                let folder = Harness.forecastFolder(for: sheet.id)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                arguments += ["--add-dir", folder.path, "--allowedTools", "Edit(/" + folder.path + "/**)"]
            }
        }
        if !model.isEmpty && !model.hasPrefix("grok") { arguments += ["--model", model] }
        if let id = harnessSession { arguments += ["--resume", id] }
        }

        let run = Process()
        run.executableURL = URL(fileURLWithPath: binary)
        run.arguments = arguments
        run.currentDirectoryURL = projectFolder ?? (grok ? Harness.grokWorkspace : Harness.workspace)
        var environment = ProcessInfo.processInfo.environment
environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin:" + NSHomeDirectory() + "/.grok/bin"
        if grok && !Harness.grokSignedIn, let key = Config.key("XAI_API_KEY") { environment["XAI_API_KEY"] = key }
        let keyInEnvironment = Harness.credentialVariables.contains(where: { environment[$0] != nil })
        if dropKeys {
            for name in Harness.credentialVariables { environment.removeValue(forKey: name) }
        }
        run.environment = environment
        let output = Pipe()
        run.standardOutput = output
        // Keep whatever Claude Code prints as errors, for the log.
        let errorFile = Harness.support.appendingPathComponent("last-stderr.txt")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        let errorHandle = try? FileHandle(forWritingTo: errorFile)
        run.standardError = errorHandle ?? FileHandle.nullDevice
        run.standardInput = FileHandle.nullDevice
        Harness.log("run: binary=\(binary) resume=\(harnessSession != nil) apiKeyInEnv=\(keyInEnvironment) dropKeys=\(dropKeys)")

        stopped = false
        try run.run()
        process = run

        var current = ""
        var final = ""
        var failure: String?
        var announced = false

        for try await line in output.fileHandleForReading.bytes.lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let obj = object as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if let id = obj["session_id"] as? String, !id.isEmpty { harnessSession = id }

            switch type {
            case "stream_event":
                guard let event = obj["event"] as? [String: Any] else { break }
                let kind = event["type"] as? String ?? ""
                if kind == "message_start" {
                    current = ""
                } else if let delta = event["delta"] as? [String: Any],
                          (delta["type"] as? String) == "text_delta",
                          let text = delta["text"] as? String {
                    current += text
                    announced = show(current, announced: announced)
                }

            case "assistant":
                guard let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { break }
                for block in content where (block["type"] as? String) == "tool_use" {
                    let name = Harness.canonical(block["name"] as? String ?? "tool")
                    let input = block["input"] as? [String: Any] ?? [:]
                    let id = block["id"] as? String ?? UUID().uuidString
                    let kind = Harness.kind(tool: name, input: input)
                    if !steps.contains(where: { $0.id == id }) {
                        var step = AgentStep(id: id, tool: name, detail: Harness.summarize(tool: name, input: input, limit: 90), state: "running")
                        step.kind = kind
                        step.path = input["file_path"] as? String ?? input["path"] as? String ?? input["target_file"] as? String ?? ""
                        step.before = String((input["old_string"] as? String ?? "").prefix(6000))
                        step.after = String((input["new_string"] as? String ?? input["content"] as? String ?? "").prefix(6000))
                        if kind == "run" || kind == "build" || kind == "test" {
                            step.detail = Harness.summarize(tool: name, input: input, limit: 400)
                        }
                        steps.append(step)
                        if !step.path.isEmpty { touchedFile = URL(fileURLWithPath: step.path) }
                    }
                    announced = false
                    lastEvent = Date()
                    onEvent?(.tool(kind))
                }

            case "user":
                guard let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { break }
                for block in content where (block["type"] as? String) == "tool_result" {
                    let id = block["tool_use_id"] as? String ?? ""
                    if let i = steps.firstIndex(where: { $0.id == id }), steps[i].state == "running" {
                        let failed = (block["is_error"] as? Bool) == true
                        steps[i].state = failed ? "failed" : "done"
                        var output = ""
                        if let string = block["content"] as? String {
                            output = string
                        } else if let parts = block["content"] as? [[String: Any]] {
                            for part in parts where (part["type"] as? String) == "text" {
                                output += (part["text"] as? String ?? "")
                            }
                        }
                        let kind = steps[i].kind
                        if kind == "run" || kind == "build" || kind == "test" {
                            steps[i].output = String(output.suffix(12_000))
                        }
                        if kind == "test" || kind == "build" { lastTest = (failed ? "failed: " : "passed: ") + kind }
                        if kind == "edit" && !failed && !steps[i].path.isEmpty {
                            touchedFile = URL(fileURLWithPath: steps[i].path)
                            editCount += 1
                        }
                        onEvent?(.toolResult(kind: kind, ok: !failed))
                    }
                }
                lastEvent = Date()

            case "result":
                final = obj["result"] as? String ?? ""
                if let denials = obj["permission_denials"] as? [Any], !denials.isEmpty {
                    Harness.log("permission denials this run: \(denials.count)")
                }
                if (obj["is_error"] as? Bool) == true {
                    failure = final.isEmpty ? "The run ended with an error." : final
                }

            default:
                break
            }
        }
        run.waitUntilExit()
        process = nil
        try? errorHandle?.close()
        let errorText = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
        Harness.log("exit=\(run.terminationStatus) steps=\(steps.count) stopped=\(stopped) error=\(String((failure ?? "").prefix(400))) stderr=\(String(errorText.suffix(400)))")
        for i in steps.indices where steps[i].state == "running" { steps[i].state = stopped ? "denied" : "done" }
        if grok { checkGrokGate(since: began, usedTools: steps.contains(where: { $0.kind == "edit" || $0.kind == "run" || $0.kind == "build" || $0.kind == "test" })) }

        if stopped {
            stopped = false
            return "[mood=calm gesture=nod]\nStopped."
        }
        if let failure {
            harnessSession = nil   // start a fresh conversation next time
            throw HarnessFailure(message: String(failure.prefix(300)))
        }
        if final.isEmpty && current.isEmpty {
            harnessSession = nil
throw HarnessFailure(message: grok
                ? "Grok returned nothing (exit code \(run.terminationStatus)). Try running `grok` in Terminal to check it is signed in."
                : "Claude Code returned nothing (exit code \(run.terminationStatus)). Try running `claude` in Terminal to check it is signed in.")
        }
        return final.isEmpty ? current : final
    }

    /// Stops the run in progress. Called from the stop button and when the character is picked up.
    func stop() {
        guard let run = process, run.isRunning else { return }
        stopped = true
        clearApprovals()
        run.interrupt()
    }

    // MARK: Approvals

    func request(_ item: Approval) {
if item.auto || (!item.danger && (taskGrants.contains(item.grantKey) || alwaysGrants.contains(item.grantKey)))
            || (engine == "grok" && grokAllows(item)) {
            Harness.answer(item.id, allow: true)
            return
        }
        approvalQueue.append(item)
        if approval == nil { nextApproval() }
    }

    private func nextApproval() {
        if approvalQueue.isEmpty {
            approval = nil
            return
        }
        approval = approvalQueue.removeFirst()
        lastEvent = Date()
        onEvent?(.needsApproval)
    }

    /// Kinds of action this character may always take without asking, kept between launches.
    /// Risky actions (deleting, sending, pushing and the like) are never remembered, whatever is clicked.
    var alwaysGrants: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "alwaysAllow." + sheet.id) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "alwaysAllow." + sheet.id) }
    }

    func decide(allow: Bool, forTask: Bool, always: Bool = false) {
        guard let item = approval else { return }
        Harness.answer(item.id, allow: allow)
        if allow && forTask && !item.danger { taskGrants.insert(item.grantKey) }
        if allow && always && !item.danger {
            alwaysGrants.insert(item.grantKey)
            Harness.log("always allow: \(sheet.id) \(item.grantKey)")
            // Anything of the same kind already waiting goes through too.
            let waiting = approvalQueue.filter { !$0.danger && $0.grantKey == item.grantKey }
            for other in waiting { Harness.answer(other.id, allow: true) }
            approvalQueue.removeAll(where: { !$0.danger && $0.grantKey == item.grantKey })
        }
        lastEvent = Date()
        onEvent?(allow ? .tool(item.tool) : .thinking)
        nextApproval()
    }

    func clearApprovals() {
        if let item = approval { Harness.answer(item.id, allow: false) }
        for item in approvalQueue { Harness.answer(item.id, allow: false) }
        approvalQueue = []
        approval = nil
    }

    /// Points this character at a project folder. A new folder means a new conversation.
    func assign(folder: URL?) {
        if busy || folder == projectFolder { return }
        projectFolder = folder
        harnessSession = nil
        steps = []
        lastTest = ""
        touchedFile = nil
        save()
    }

    /// Picks up a past conversation in the project, with its messages shown for context.
    func resume(_ conversation: Conversation) {
        if busy { return }
        harnessSession = conversation.id
        messages = Harness.transcript(of: conversation)
        steps = []
        save()
    }

    func newConversation() {
        if busy { return }
        harnessSession = nil
        messages = []
        steps = []
        save()
    }

    func attach(_ url: URL) {
        if !attachments.contains(url) && attachments.count < 8 { attachments.append(url) }
        lastEvent = Date()
    }
}
