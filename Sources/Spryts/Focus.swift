import AppKit

// MARK: - What was open

/// One app as it was: whether it was hidden or in front, and what it had open where we can tell.
struct SavedApp: Codable {
    var id: String          // bundle identifier
    var name: String
    var path: String?       // where the app lives, to relaunch it
    var hidden: Bool
    var front: Bool
    var documents: [String] // file paths, for apps that will say
    var tabs: [String]      // URLs, for browsers
}

/// A whole desk at one moment.
struct SavedContext: Codable {
    var name: String
    var date: Date
    var focus: String?      // bundle id of the app the person was focused on
    var apps: [SavedApp]
}

/// A stretch of time one app spent in front. The app records these so a sweep can guess the focus.
struct FocusSpan: Codable {
    var id: String
    var name: String
    var start: Date
    var end: Date
}

private struct DwellFile: Codable {
    var spans: [FocusSpan]
    var current: FocusSpan?
}

// MARK: - The keeper

/// Pip's focus tools: hide everything but the work, put it all back, and remember what was open.
/// Hiding is used rather than quitting, so nothing unsaved is ever lost. Everything it does can be undone.
@MainActor
final class FocusKeeper: ObservableObject {
    static let shared = FocusKeeper()

    @Published private(set) var sweepActive = false
    @Published private(set) var saved: [String] = []
    @Published private(set) var hasAway = false

    nonisolated static var folder: URL { Harness.support.appendingPathComponent("focus") }
    nonisolated static var dwellFile: URL { folder.appendingPathComponent("recent.json") }
    nonisolated static var sweepFile: URL { folder.appendingPathComponent("before-sweep.json") }
    nonisolated static var awayFile: URL { folder.appendingPathComponent("away.json") }
    nonisolated static var contextsFolder: URL { folder.appendingPathComponent("contexts") }

    /// Browsers whose tabs can be read and reopened.
    nonisolated static let browsers = ["com.apple.Safari", "com.google.Chrome", "com.brave.Browser",
                                       "com.microsoft.edgemac", "company.thebrowser.Browser"]
    /// Apps that will say which documents they have open.
    nonisolated static let documentApps = ["com.apple.TextEdit", "com.apple.Preview", "com.apple.iWork.Pages",
                                           "com.apple.iWork.Numbers", "com.apple.iWork.Keynote",
                                           "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint"]

    private init() {
        reloadState()
    }

    /// Picks up changes made by the command-line tool (which is how Pip acts from chat).
    func reloadState() {
        let fm = FileManager.default
        sweepActive = fm.fileExists(atPath: Self.sweepFile.path)
        hasAway = fm.fileExists(atPath: Self.awayFile.path)
        let files = (try? fm.contentsOfDirectory(at: Self.contextsFolder, includingPropertiesForKeys: nil)) ?? []
        saved = files.filter { $0.pathExtension == "json" }
            .compactMap { Self.read($0)?.name }
            .sorted()
    }

    // MARK: Guessing the focus

    /// Records what has been in front, so a sweep run from anywhere can tell where the person has been working.
    nonisolated static func writeDwell(spans: [FocusSpan], current: FocusSpan?) {
        let cutoff = Date().addingTimeInterval(-1800)
        let kept = spans.filter { $0.end > cutoff }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(DwellFile(spans: kept, current: current)) {
            try? data.write(to: dwellFile, options: .atomic)
        }
    }

    /// The app with the most time in front over the last 20 minutes, among those still running.
    /// Falls back to the frontmost ordinary app.
    nonisolated static func guessFocus(within window: TimeInterval = 1200) -> String? {
        let running = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleIdentifier })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: dwellFile), let dwell = try? decoder.decode(DwellFile.self, from: data) {
            let now = Date()
            let cutoff = now.addingTimeInterval(-window)
            var totals: [String: TimeInterval] = [:]
            var all = dwell.spans
            if var current = dwell.current {
                current.end = now
                all.append(current)
            }
            for span in all {
                let overlap = min(span.end, now).timeIntervalSince(max(span.start, cutoff))
                if overlap > 0 { totals[span.id, default: 0] += overlap }
            }
            if let best = totals.filter({ running.contains($0.key) }).max(by: { $0.value < $1.value }) {
                return best.key
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.activationPolicy == .regular {
            return front.bundleIdentifier
        }
        // Spryts itself may be in front (the person is talking to Pip). Use the topmost ordinary window instead.
        // Window owners need no permission to read; only window titles do.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
                guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                      let app = NSRunningApplication(processIdentifier: pid),
                      app.activationPolicy == .regular, let id = app.bundleIdentifier else { continue }
                return id
            }
        }
        return nil
    }

    /// Looked up in the workspace's list, the same one a capture reads. `runningApplications(withBundleIdentifier:)`
    /// missed running apps (Xcode, Notes) when tested from the command line, so it isn't used.
    private static func runningApp(_ id: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == id })
    }

    private static func ordinaryApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
    }

    /// Finds a running app by its name or bundle id.
    private static func find(_ query: String) -> NSRunningApplication? {
        let q = query.lowercased()
        let apps = ordinaryApps()
        return apps.first(where: { ($0.localizedName ?? "").lowercased() == q || $0.bundleIdentifier?.lowercased() == q })
            ?? apps.first(where: { ($0.localizedName ?? "").lowercased().contains(q) })
    }

    // MARK: Capturing

    /// What is open right now. Deep capture also asks browsers for tabs and document apps for files.
    func capture(name: String, deep: Bool) async -> SavedContext {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var apps: [SavedApp] = Self.ordinaryApps().map { app in
            SavedApp(id: app.bundleIdentifier ?? "", name: app.localizedName ?? app.bundleIdentifier ?? "App",
                     path: app.bundleURL?.path, hidden: app.isHidden, front: app.processIdentifier == frontPID,
                     documents: [], tabs: [])
        }
        if deep {
            for i in apps.indices where !apps[i].hidden {
                let id = apps[i].id
                if Self.browsers.contains(id) {
                    apps[i].tabs = await Self.tabs(of: id)
                } else if Self.documentApps.contains(id) {
                    apps[i].documents = await Self.documents(of: id)
                }
            }
        }
        return SavedContext(name: name, date: Date(), focus: Self.guessFocus(), apps: apps)
    }

    nonisolated static func tabs(of id: String) async -> [String] {
        let script = """
        tell application id "\(id)"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set out to out & (URL of t) & linefeed
                    end try
                end repeat
            end repeat
            return out
        end tell
        """
        return await Task.detached { lines(osascript(script)) }.value
            .filter { $0.hasPrefix("http") || $0.hasPrefix("file:") }
    }

    nonisolated static func documents(of id: String) async -> [String] {
        // Each family has its own words; a term one app doesn't know stops the whole script compiling.
        let lookup = id.hasPrefix("com.microsoft.")
            ? """
                    try
                        set p to POSIX path of (full name of d)
                    end try
              """
            : """
                    try
                        set p to path of d
                    on error
                        try
                            set p to POSIX path of (file of d as alias)
                        end try
                    end try
              """
        let script = """
        tell application id "\(id)"
            set out to ""
            repeat with d in documents
                set p to ""
        \(lookup)
                if p is not missing value and p is not "" then set out to out & p & linefeed
            end repeat
            return out
        end tell
        """
        return await Task.detached { lines(osascript(script)) }.value
            .filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
    }

    /// Runs AppleScript in a child process with a time limit, so a slow or blocked app can't hang Spryts.
    /// The first time, macOS asks the person whether Spryts may control that app; the limit leaves time to answer.
    nonisolated static func osascript(_ source: String, timeout: Double = 20) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func lines(_ text: String?) -> [String] {
        (text ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: The sweep

    /// Hides everything except the focus app. Keeps a record first, so `back()` restores exactly what was showing.
    /// `only` limits the sweep to the named apps; `dryRun` says what would happen and changes nothing.
    func sweep(keep: String? = nil, only: [String]? = nil, dryRun: Bool = false) async -> String {
        let focusApp: NSRunningApplication?
        if let keep {
            focusApp = Self.find(keep)
            if focusApp == nil { return "I can't find \(keep) running." }
        } else {
            focusApp = Self.guessFocus().flatMap(Self.runningApp)
        }
        guard let focusApp, let focusID = focusApp.bundleIdentifier else {
            return "I'm not sure what you're working on. Tell me which app to keep."
        }
        let focusName = focusApp.localizedName ?? focusID
        let wanted = only?.map { $0.lowercased() }
        let others = Self.ordinaryApps().filter { app in
            guard app.bundleIdentifier != focusID, !app.isHidden else { return false }
            guard let wanted else { return true }
            return wanted.contains((app.localizedName ?? "").lowercased()) || wanted.contains((app.bundleIdentifier ?? "").lowercased())
        }
        let names = others.map { $0.localizedName ?? $0.bundleIdentifier ?? "App" }
        if dryRun {
            return names.isEmpty ? "Would keep \(focusName). Nothing else is showing."
                                 : "Would keep \(focusName) and hide \(names.count): \(names.joined(separator: ", "))."
        }
        if names.isEmpty {
            await Self.bringForward(focusApp)
            return "Only \(focusName) is showing already. You're set."
        }

        // Record the desk before touching it. A second sweep on top of the first keeps the original record.
        if !FileManager.default.fileExists(atPath: Self.sweepFile.path) {
            let before = await capture(name: "Before the sweep", deep: false)
            Self.write(before, to: Self.sweepFile)
        }
        for app in others { app.hide() }
        await Self.bringForward(focusApp)
        reloadState()
        let opening = keep == nil ? "Looks like \(focusName) is the work." : "Keeping \(focusName)."
        return opening + " I hid \(names.count): \(names.joined(separator: ", ")). Say \"bring it back\" to undo."
    }

    /// Undoes the sweep: everything that was showing shows again, and the app that was in front goes back in front.
    func back() async -> String {
        guard let before = Self.read(Self.sweepFile) else {
            reloadState()
            return "There's no sweep to undo."
        }
        var shown: [String] = []
        for app in before.apps where !app.hidden {
            if let running = Self.runningApp(app.id), running.isHidden {
                running.unhide()
                shown.append(app.name)
            }
        }
        if let front = before.apps.first(where: { $0.front }), let running = Self.runningApp(front.id) {
            await Self.bringForward(running)
        }
        try? FileManager.default.removeItem(at: Self.sweepFile)
        reloadState()
        return shown.isEmpty ? "Everything was already back." : "Back as it was. Showing \(shown.count) again: \(shown.joined(separator: ", "))."
    }

    /// Activation from a background app is often ignored on recent macOS; asking the system to open the app works.
    private static func bringForward(_ app: NSRunningApplication) async {
        guard let url = app.bundleURL else {
            app.activate()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    // MARK: Saved contexts and "where was I?"

    func save(as name: String) async -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = clean.isEmpty ? Self.defaultName() : clean
        let context = await capture(name: label, deep: true)
        Self.write(context, to: Self.contextFile(label))
        reloadState()
        return "Saved \"\(label)\". " + Self.summary(context, past: false)
    }

    func restore(named name: String) async -> String {
        let match = saved.first(where: { $0.lowercased() == name.lowercased() })
            ?? saved.first(where: { $0.lowercased().contains(name.lowercased()) })
        guard let match, let context = Self.read(Self.contextFile(match)) else {
            return saved.isEmpty ? "There are no saved setups yet." : "I don't have \"\(name)\". Saved: \(saved.joined(separator: ", "))."
        }
        return await restore(context)
    }

    func restoreAway() async -> String {
        guard let context = Self.read(Self.awayFile) else { return "I didn't catch what was open before you left." }
        return await restore(context)
    }

    func forget(_ name: String) -> String {
        guard let match = saved.first(where: { $0.lowercased() == name.lowercased() }) else { return "I don't have \"\(name)\"." }
        try? FileManager.default.removeItem(at: Self.contextFile(match))
        reloadState()
        return "Forgot \"\(match)\"."
    }

    /// Captured when the person steps away, so they can be told where they were, and have it put back, later.
    func snapshotAway() {
        Task { @MainActor in
            let context = await capture(name: "Before you stepped away", deep: true)
            Self.write(context, to: Self.awayFile)
            reloadState()
        }
    }

    /// The last away snapshot in a sentence, if there is a recent one.
    nonisolated static func awaySummary(maxAge: TimeInterval = 7 * 86400) -> String? {
        guard let context = read(awayFile), Date().timeIntervalSince(context.date) < maxAge else { return nil }
        return summary(context, past: true)
    }

    /// Opens what was open: shows hidden apps, relaunches quit ones, reopens documents and tabs that aren't open.
    /// Says plainly what it couldn't bring back.
    func restore(_ context: SavedContext) async -> String {
        var shownNames: [String] = [], launchedNames: [String] = []
        var documents = 0, tabs = 0
        var missing: [String] = []
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        for app in context.apps {
            let appURL = app.path.map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id)
            var wasRunning = false
            if let running = Self.runningApp(app.id) {
                wasRunning = true
                if !app.hidden && running.isHidden {
                    running.unhide()
                    shownNames.append(app.name)
                }
            } else if let appURL {
                let launch = NSWorkspace.OpenConfiguration()
                launch.activates = false
                launch.hides = app.hidden
                if (try? await NSWorkspace.shared.openApplication(at: appURL, configuration: launch)) != nil {
                    launchedNames.append(app.name)
                } else {
                    missing.append(app.name)
                    continue
                }
            } else {
                missing.append(app.name)
                continue
            }

            if let appURL {
                // Only reopen what isn't open already, so the count is what actually came back.
                let alreadyOpen = wasRunning && !app.documents.isEmpty ? Set(await Self.documents(of: app.id)) : []
                for path in app.documents where !alreadyOpen.contains(path) {
                    if FileManager.default.fileExists(atPath: path) {
                        if (try? await NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: config)) != nil {
                            documents += 1
                        }
                    } else {
                        missing.append((path as NSString).lastPathComponent)
                    }
                }
                if !app.tabs.isEmpty {
                    let open = wasRunning ? Set(await Self.tabs(of: app.id)) : []
                    let wanted = app.tabs.filter { !open.contains($0) }.compactMap { URL(string: $0) }
                    if !wanted.isEmpty,
                       (try? await NSWorkspace.shared.open(wanted, withApplicationAt: appURL, configuration: config)) != nil {
                        tabs += wanted.count
                    }
                }
            }
        }
        let frontID = context.apps.first(where: { $0.front })?.id ?? context.focus
        if let frontID, let running = Self.runningApp(frontID) { await Self.bringForward(running) }

        var parts: [String] = []
        if !shownNames.isEmpty { parts.append("showed " + shownNames.joined(separator: ", ")) }
        if !launchedNames.isEmpty { parts.append("reopened " + launchedNames.joined(separator: ", ")) }
        if documents > 0 { parts.append("\(documents) document\(documents == 1 ? "" : "s")") }
        if tabs > 0 { parts.append("\(tabs) tab\(tabs == 1 ? "" : "s")") }
        var text = parts.isEmpty ? "Everything from \"\(context.name)\" was already open." : "Put back \"\(context.name)\": " + parts.joined(separator: ", ") + "."
        if !missing.isEmpty { text += " Couldn't bring back: " + missing.joined(separator: ", ") + "." }
        return text
    }

    // MARK: Words

    /// "You were in Numbers (Budget.numbers), with Safari (3 tabs: apple.com, bbc.co.uk) and Mail open."
    nonisolated static func summary(_ context: SavedContext, past: Bool) -> String {
        let visible = context.apps.filter { !$0.hidden }
        guard !visible.isEmpty else { return past ? "Nothing was open." : "Nothing is open." }
        let lead = visible.first(where: { $0.id == context.focus }) ?? visible.first(where: { $0.front }) ?? visible[0]
        func describe(_ app: SavedApp) -> String {
            if !app.documents.isEmpty {
                let names = app.documents.prefix(2).map { ($0 as NSString).lastPathComponent }
                let more = app.documents.count > 2 ? " and \(app.documents.count - 2) more" : ""
                return app.name + " (" + names.joined(separator: ", ") + more + ")"
            }
            if !app.tabs.isEmpty {
                var hosts: [String] = []
                for tab in app.tabs {
                    if let host = URL(string: tab)?.host?.replacingOccurrences(of: "www.", with: ""), !hosts.contains(host) {
                        hosts.append(host)
                    }
                    if hosts.count == 2 { break }
                }
                let count = "\(app.tabs.count) tab\(app.tabs.count == 1 ? "" : "s")"
                return app.name + " (" + count + (hosts.isEmpty ? "" : ": " + hosts.joined(separator: ", ")) + ")"
            }
            return app.name
        }
        let rest = visible.filter { $0.id != lead.id }
        let shownRest = rest.prefix(4).map(describe)
        var text = (past ? "You were in " : "You're in ") + describe(lead)
        if !shownRest.isEmpty {
            var list = shownRest.count == 1 ? shownRest[0]
                : shownRest.dropLast().joined(separator: ", ") + " and " + shownRest[shownRest.count - 1]
            if rest.count > 4 { list += ", plus \(rest.count - 4) more" }
            text += ", with " + list + " open"
        }
        return text + "."
    }

    /// What Pip is told about this, each turn.
    nonisolated static func contextNote() -> String {
        var note = ""
        if FileManager.default.fileExists(atPath: sweepFile.path) {
            note += " A focus sweep is on: other apps are hidden until they ask to bring them back."
        }
        if let away = awaySummary(maxAge: 12 * 3600) {
            note += " Before they last stepped away: " + away
        }
        return note
    }

    nonisolated private static func defaultName() -> String {
        let focus = guessFocus().flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName } ?? "Desk"
        let stamp = DateFormatter()
        stamp.dateFormat = "EEE d MMM HH:mm"
        return focus + " · " + stamp.string(from: Date())
    }

    // MARK: Files

    nonisolated private static func contextFile(_ name: String) -> URL {
        let safe = name.map { "/:\\".contains($0) ? "-" : $0 }
        return contextsFolder.appendingPathComponent(String(safe) + ".json")
    }

    nonisolated private static func write(_ context: SavedContext, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(context) { try? data.write(to: url, options: .atomic) }
    }

    nonisolated private static func read(_ url: URL) -> SavedContext? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SavedContext.self, from: data)
    }
}

// MARK: - Command line

/// `Spryts focus …`: the same tools from a shell. Pip uses this from chat; it is also how the tools are tested.
enum FocusCLI {
    static let usage = """
    Usage: Spryts focus <command>
      guess                         which app looks like the focus
      sweep [--keep App] [--only A,B] [--dry-run]
                                    hide everything but the focus
      back                          undo the sweep
      save [Name]                   remember what's open
      restore Name                  put a saved setup back
      list                          saved setups
      forget Name                   delete a saved setup
      whereami                      what was open before you last stepped away
      away                          take that snapshot now
      putback                       restore what was open before you stepped away
      show                          what's open now, as a sentence
    """

    @MainActor
    static func run(_ args: [String]) async -> Int32 {
        let keeper = FocusKeeper.shared
        guard let command = args.first else {
            print(usage)
            return 2
        }
        let rest = Array(args.dropFirst())
        func option(_ flag: String) -> String? {
            guard let i = rest.firstIndex(of: flag), i + 1 < rest.count else { return nil }
            return rest[i + 1]
        }
        let words = rest.filter { !$0.hasPrefix("--") }.joined(separator: " ")
        switch command {
        case "guess":
            if let id = FocusKeeper.guessFocus() {
                let name = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName ?? id
                print("\(name) (\(id))")
            } else {
                print("No guess.")
            }
        case "sweep":
            let only = option("--only")?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            print(await keeper.sweep(keep: option("--keep"), only: only, dryRun: rest.contains("--dry-run")))
        case "back":
            print(await keeper.back())
        case "save":
            print(await keeper.save(as: words))
        case "restore":
            guard !words.isEmpty else { print("Which one? Saved: \(keeper.saved.joined(separator: ", "))"); return 2 }
            print(await keeper.restore(named: words))
        case "list":
            print(keeper.saved.isEmpty ? "No saved setups." : keeper.saved.joined(separator: "\n"))
        case "forget":
            print(keeper.forget(words))
        case "whereami":
            print(FocusKeeper.awaySummary() ?? "I didn't catch what was open before you left.")
        case "away":
            let context = await keeper.capture(name: "Before you stepped away", deep: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(context) {
                try? FileManager.default.createDirectory(at: FocusKeeper.folder, withIntermediateDirectories: true)
                try? data.write(to: FocusKeeper.awayFile, options: .atomic)
            }
            print(FocusKeeper.summary(context, past: true))
        case "putback":
            print(await keeper.restoreAway())
        case "show":
            let context = await keeper.capture(name: "Now", deep: true)
            print(FocusKeeper.summary(context, past: false))
        default:
            print(usage)
            return 2
        }
        return 0
    }
}
