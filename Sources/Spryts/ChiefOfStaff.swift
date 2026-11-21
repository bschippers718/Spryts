import AppKit
import SwiftUI

// Pip's job: running the person's day. He keeps an office folder of plain files, and today.json in it
// is what his popup strip and his Today desk show. The app never reads the calendar or mail itself;
// Pip does, through his tools (Apple's apps, and Google if connected), and writes down what he found.

struct OfficeEvent: Codable, Identifiable, Equatable {
    var id: String { [start ?? "", end ?? "", title ?? ""].joined(separator: "|") }
    var start: String?
    var end: String?
    var title: String?
    var place: String?
    var source: String?     // apple or google
    var prep: String?       // short prep cue, optional
}

struct FocusItem: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var why: String?
    var done: Bool

    init(id: String? = nil, text: String, why: String? = nil, done: Bool = false) {
        self.text = text
        self.why = why
        self.done = done
        self.id = id ?? FocusItem.makeID(text)
    }

    static func makeID(_ text: String) -> String {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? UUID().uuidString : normalized
    }
}

struct FollowUp: Codable, Identifiable, Equatable {
    var id: String
    var what: String?
    var who: String?
    var due: String?
    var mine: Bool?         // true: the person owes it. false: they are waiting on someone.
    var overdue: Bool?
    var done: Bool?

    init(id: String? = nil, what: String?, who: String? = nil, due: String? = nil,
         mine: Bool? = true, overdue: Bool? = nil, done: Bool? = nil) {
        self.what = what
        self.who = who
        self.due = due
        self.mine = mine
        self.overdue = overdue
        self.done = done
        self.id = id ?? FollowUp.makeID(what: what, who: who)
    }

    static func makeID(what: String?, who: String?) -> String {
        let key = ((what ?? "") + "|" + (who ?? "")).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? UUID().uuidString : key
    }

    var isDone: Bool { done == true }

    var isOverdue: Bool {
        if isDone { return false }
        if overdue == true { return true }
        guard let due = due?.trimmingCharacters(in: .whitespacesAndNewlines),
              due.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return false }
        return due < Office.dayKey
    }
}

struct InboxItem: Codable, Identifiable, Equatable {
    var id: String
    var from: String?
    var subject: String?
    var why: String?
    var source: String?
    var done: Bool?

    init(id: String? = nil, from: String?, subject: String?, why: String? = nil,
         source: String? = nil, done: Bool? = nil) {
        self.from = from
        self.subject = subject
        self.why = why
        self.source = source
        self.done = done
        let key = ((from ?? "") + "|" + (subject ?? "")).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id ?? (key.isEmpty ? UUID().uuidString : key)
    }

    var isDone: Bool { done == true }
}

struct XBriefTheme: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var summary: String
    var sources: [String]

    init(id: String? = nil, title: String, summary: String, sources: [String] = []) {
        self.title = title
        self.summary = summary
        self.sources = sources.filter(XBriefTheme.isSafeXURL)
        let key = (title + "|" + summary.prefix(40)).lowercased()
        self.id = id ?? (key.isEmpty ? UUID().uuidString : key)
    }

    static func isSafeXURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 512,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(host),
              url.user == nil else { return false }
        return true
    }

    static func linkLabel(_ raw: String) -> String {
        guard let url = URL(string: raw) else { return "Post" }
        let parts = url.path.split(separator: "/").map(String.init)
        if let first = parts.first, !first.isEmpty, first.lowercased() != "i" {
            return "@" + first
        }
        return "x.com"
    }
}

struct XFeedBrief: Codable, Equatable {
    var feed: String?
    var updated: String?
    var summary: String?
    var themes: [XBriefTheme]
    var actions: [String]

    var isEmpty: Bool {
        (summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && themes.isEmpty && actions.isEmpty
    }
}

struct TodayFile: Equatable {
    var date: String?
    var updated: String?
    var summary: String?
    var notes: [String]
    var events: [OfficeEvent]
    var focus: [FocusItem]
    var followups: [FollowUp]
    var inbox: [InboxItem]
    var xBrief: XFeedBrief?

    /// Tolerant parser so a single unexpected field shape from an agent never wipes out the brief.
    static func parse(_ data: Data) -> TodayFile? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let date = cleanString(raw["date"])
        let updated = cleanString(raw["updated"])
        var summary = cleanString(raw["summary"])
        var notes = stringList(raw["notes"])

        // Events
        var events: [OfficeEvent] = []
        if let list = raw["events"] as? [[String: Any]] {
            for item in list {
                let title = cleanString(item["title"]) ?? cleanString(item["summary"]) ?? cleanString(item["name"])
                let start = cleanString(item["start"])
                if title == nil && start == nil { continue }
                events.append(OfficeEvent(
                    start: start,
                    end: cleanString(item["end"]),
                    title: title,
                    place: cleanString(item["place"]) ?? cleanString(item["location"]),
                    source: cleanString(item["source"]),
                    prep: cleanString(item["prep"])
                ))
            }
        }

        // Focus / priorities (accepts strings OR structured objects)
        var focus: [FocusItem] = []
        var seenFocus: Set<String> = []
        func appendFocus(_ text: String, why: String? = nil, done: Bool = false) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard seenFocus.insert(key).inserted else { return }
            focus.append(FocusItem(text: trimmed, why: why, done: done))
        }
        if let list = raw["focus"] as? [Any] {
            for entry in list {
                if let text = entry as? String {
                    appendFocus(text)
                } else if let dict = entry as? [String: Any],
                          let text = cleanString(dict["text"]) ?? cleanString(dict["title"]) ?? cleanString(dict["what"]) {
                    appendFocus(text, why: cleanString(dict["why"]), done: boolValue(dict["done"]) ?? false)
                }
            }
        }

        // Follow-ups (accepts structured objects OR plain strings)
        var followups: [FollowUp] = []
        var seenFollow: Set<String> = []
        func appendFollowUp(_ item: FollowUp) {
            let key = (item.what ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            if let existingIndex = followups.firstIndex(where: { ($0.what ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == key }) {
                if item.overdue == true { followups[existingIndex].overdue = true }
                if followups[existingIndex].who == nil, let who = item.who { followups[existingIndex].who = who }
                if followups[existingIndex].due == nil, let due = item.due { followups[existingIndex].due = due }
                return
            }
            seenFollow.insert(key)
            followups.append(item)
        }
        if let list = raw["followups"] as? [Any] {
            for entry in list {
                if let text = entry as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        appendFollowUp(FollowUp(what: trimmed, mine: true))
                    }
                } else if let dict = entry as? [String: Any] {
                    let what = cleanString(dict["what"]) ?? cleanString(dict["text"]) ?? cleanString(dict["title"])
                    if let what {
                        appendFollowUp(FollowUp(
                            what: what,
                            who: cleanString(dict["who"]),
                            due: cleanString(dict["due"]),
                            mine: boolValue(dict["mine"]) ?? true,
                            overdue: boolValue(dict["overdue"]),
                            done: boolValue(dict["done"])
                        ))
                    }
                }
            }
        }

        // Absorb nested `brief` shape if an engine wrote one (e.g. {first, matters_most, overdue, waiting_on_me})
        if let briefText = cleanString(raw["brief"]) {
            if summary == nil { summary = briefText }
        } else if let brief = raw["brief"] as? [String: Any] {
            if summary == nil {
                let parts = [cleanString(brief["summary"]), cleanString(brief["first"]), cleanString(brief["matters_most"])]
                    .compactMap { $0 }
                if !parts.isEmpty { summary = parts.joined(separator: " ") }
            }
            if let matters = cleanString(brief["matters_most"]) {
                appendFocus(matters)
            }
            for item in stringList(brief["overdue"]) {
                appendFollowUp(FollowUp(what: item, mine: true, overdue: true))
            }
            for item in stringList(brief["waiting_on_me"]) {
                appendFollowUp(FollowUp(what: item, mine: true))
            }
            for item in stringList(brief["waiting_on"]) {
                appendFollowUp(FollowUp(what: item, mine: false))
            }
            for note in stringList(brief["notes"]) where !notes.contains(note) {
                notes.append(note)
            }
        }

        // Inbox
        var inbox: [InboxItem] = []
        if let list = raw["inbox"] as? [[String: Any]] {
            for dict in list {
                let subject = cleanString(dict["subject"]) ?? cleanString(dict["title"])
                let from = cleanString(dict["from"])
                if subject == nil && from == nil { continue }
                inbox.append(InboxItem(
                    from: from,
                    subject: subject,
                    why: cleanString(dict["why"]),
                    source: cleanString(dict["source"]),
                    done: boolValue(dict["done"])
                ))
            }
        }

        // Optional X Feed Brief
        var xBrief: XFeedBrief?
        if let xDict = (raw["xBrief"] ?? raw["x_brief"] ?? raw["feedBrief"]) as? [String: Any] {
            var themes: [XBriefTheme] = []
            if let list = xDict["themes"] as? [Any] {
                for entry in list {
                    if let dict = entry as? [String: Any] {
                        let title = cleanString(dict["title"]) ?? cleanString(dict["topic"]) ?? "Highlight"
                        let body = cleanString(dict["summary"]) ?? cleanString(dict["text"]) ?? ""
                        let sources = stringList(dict["sources"]) + (cleanString(dict["source"]).map { [$0] } ?? []) + (cleanString(dict["url"]).map { [$0] } ?? [])
                        if !body.isEmpty || !title.isEmpty {
                            themes.append(XBriefTheme(title: title, summary: body, sources: sources))
                        }
                    } else if let text = entry as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        themes.append(XBriefTheme(title: "Theme", summary: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                }
            }
            let parsed = XFeedBrief(
                feed: cleanString(xDict["feed"]),
                updated: cleanString(xDict["updated"]),
                summary: cleanString(xDict["summary"]),
                themes: themes,
                actions: stringList(xDict["actions"])
            )
            if !parsed.isEmpty { xBrief = parsed }
        }

        return TodayFile(
            date: date,
            updated: updated,
            summary: summary,
            notes: notes,
            events: events,
            focus: focus,
            followups: followups,
            inbox: inbox,
            xBrief: xBrief
        )
    }

    func encodeJSON() -> Data? {
        var root: [String: Any] = [:]
        if let date { root["date"] = date }
        if let updated { root["updated"] = updated }
        if let summary, !summary.isEmpty { root["summary"] = summary }
        if !notes.isEmpty { root["notes"] = notes }

        root["events"] = events.map { event -> [String: Any] in
            var dict: [String: Any] = [:]
            if let v = event.start { dict["start"] = v }
            if let v = event.end { dict["end"] = v }
            if let v = event.title { dict["title"] = v }
            if let v = event.place { dict["place"] = v }
            if let v = event.source { dict["source"] = v }
            if let v = event.prep { dict["prep"] = v }
            return dict
        }

        root["focus"] = focus.map { item -> [String: Any] in
            var dict: [String: Any] = ["text": item.text, "done": item.done]
            if let why = item.why, !why.isEmpty { dict["why"] = why }
            return dict
        }

        root["followups"] = followups.map { item -> [String: Any] in
            var dict: [String: Any] = [:]
            if let v = item.what { dict["what"] = v }
            if let v = item.who { dict["who"] = v }
            if let v = item.due { dict["due"] = v }
            if let v = item.mine { dict["mine"] = v }
            if item.overdue == true { dict["overdue"] = true }
            if item.done == true { dict["done"] = true }
            return dict
        }

        root["inbox"] = inbox.map { item -> [String: Any] in
            var dict: [String: Any] = [:]
            if let v = item.from { dict["from"] = v }
            if let v = item.subject { dict["subject"] = v }
            if let v = item.why { dict["why"] = v }
            if let v = item.source { dict["source"] = v }
            if item.done == true { dict["done"] = true }
            return dict
        }

        if let xBrief, !xBrief.isEmpty {
            var xDict: [String: Any] = [:]
            if let v = xBrief.feed { xDict["feed"] = v }
            if let v = xBrief.updated { xDict["updated"] = v }
            if let v = xBrief.summary { xDict["summary"] = v }
            if !xBrief.themes.isEmpty {
                xDict["themes"] = xBrief.themes.map { theme -> [String: Any] in
                    var d: [String: Any] = ["title": theme.title, "summary": theme.summary]
                    if !theme.sources.isEmpty { d["sources"] = theme.sources }
                    return d
                }
            }
            if !xBrief.actions.isEmpty { xDict["actions"] = xBrief.actions }
            root["xBrief"] = xDict
        }

        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func cleanString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        guard let num = value as? NSNumber, CFGetTypeID(num) == CFBooleanGetTypeID() else { return nil }
        return num.boolValue
    }

    private static func stringList(_ value: Any?) -> [String] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { cleanString($0) }
    }
}

final class Office: ObservableObject {
    @Published private(set) var today: TodayFile?
    @Published private(set) var loadedAt: Date?
    let folder: URL
    private var stamp: Date?
    private var fileSize: Int?

    private static var all: [String: Office] = [:]

    static func of(_ id: String) -> Office {
        if let office = all[id] { return office }
        let office = Office(folder: Harness.officeFolder(for: id))
        all[id] = office
        return office
    }

    init(folder: URL) {
        self.folder = folder
        reload()
    }

    var file: URL { folder.appendingPathComponent("today.json") }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let isoFormatter = ISO8601DateFormatter()

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let timeParsers: [(format: String, formatter: DateFormatter)] = {
        let formats = ["HH:mm", "H:mm", "h:mm a", "h:mma", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"]
        return formats.map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            return (format, f)
        }
    }()

    static var dayKey: String { dayFormatter.string(from: Date()) }

    private static var timeKey: String { timeFormatter.string(from: Date()) }

    /// Reads today.json again if it changed on disk.
    func reload() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let changed = attrs?[.modificationDate] as? Date
        let size = attrs?[.size] as? Int
        if changed == stamp && size == fileSize && today != nil { return }
        stamp = changed
        fileSize = size
        guard let data = try? Data(contentsOf: file) else {
            today = nil
            loadedAt = nil
            return
        }
        today = TodayFile.parse(data)
        loadedAt = changed
    }

    /// True when the file is about today, not a leftover from yesterday.
    var isCurrent: Bool { today?.date == Office.dayKey }

    var summary: String? { isCurrent ? today?.summary : nil }
    var notes: [String] { isCurrent ? (today?.notes ?? []) : [] }
    var events: [OfficeEvent] { isCurrent ? (today?.events ?? []) : [] }
    var focus: [FocusItem] { today?.focus ?? [] }
    var followups: [FollowUp] { today?.followups ?? [] }
    var openFollowUps: [FollowUp] { followups.filter { !$0.isDone } }
    var inbox: [InboxItem] { isCurrent ? (today?.inbox ?? []).filter { !$0.isDone } : [] }
    var xBrief: XFeedBrief? { isCurrent ? today?.xBrief : nil }

    // MARK: Direct local updates (saved atomically to today.json so Pip sees them on the next turn)

    func toggleFocus(_ id: String) {
        mutate { file in
            if let index = file.focus.firstIndex(where: { $0.id == id }) {
                file.focus[index].done.toggle()
            }
        }
    }

    func addFocus(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate { file in
            file.focus.append(FocusItem(text: trimmed))
        }
    }

    func removeFocus(_ id: String) {
        mutate { file in
            file.focus.removeAll { $0.id == id }
        }
    }

    func toggleFollowUp(_ id: String) {
        mutate { file in
            if let index = file.followups.firstIndex(where: { $0.id == id }) {
                file.followups[index].done = !(file.followups[index].done == true)
            }
        }
    }

    func addFollowUp(what: String, who: String? = nil, mine: Bool = true) {
        let trimmed = what.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let cleanWho = who?.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate { file in
            file.followups.append(FollowUp(what: trimmed, who: (cleanWho?.isEmpty == false) ? cleanWho : nil, mine: mine))
        }
    }

    func dismissInbox(_ id: String) {
        mutate { file in
            if let index = file.inbox.firstIndex(where: { $0.id == id }) {
                file.inbox[index].done = true
            }
        }
    }

    func clearXBrief() {
        mutate { file in
            file.xBrief = nil
        }
    }

    private func mutate(_ edit: (inout TodayFile) -> Void) {
        var current = today ?? TodayFile(
            date: Office.dayKey, updated: Office.timeKey, summary: nil,
            notes: [], events: [], focus: [], followups: [], inbox: [], xBrief: nil
        )
        if current.date == nil { current.date = Office.dayKey }
        edit(&current)
        current.updated = Office.timeKey
        guard let data = current.encodeJSON() else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
            stamp = attrs?[.modificationDate] as? Date
            fileSize = attrs?[.size] as? Int
            loadedAt = stamp ?? Date()
            today = current
        } catch {
            // Keep UI consistent with disk if write failed.
            reload()
        }
    }

    static func time(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = isoFormatter.date(from: text) { return date }
        let upper = text.uppercased()
        for entry in timeParsers {
            if let parsed = entry.formatter.date(from: upper) {
                if entry.format.hasPrefix("yyyy") { return parsed }
                let parts = Calendar.current.dateComponents([.hour, .minute], from: parsed)
                return Calendar.current.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: Date())
            }
        }
        return nil
    }

    /// What's on now, or next: the first event that hasn't finished.
    func next(after now: Date = Date()) -> OfficeEvent? {
        events.first { event in
            guard let start = Office.time(event.start) else { return false }
            let end = Office.time(event.end) ?? start.addingTimeInterval(30 * 60)
            return end > now
        }
    }

    static func shortTime(_ text: String?) -> String {
        guard let date = time(text) else { return text ?? "" }
        return shortTimeFormatter.string(from: date)
    }

    /// "in 25 min", "now", "at 3:00 PM".
    static func countdown(_ event: OfficeEvent, now: Date = Date()) -> String {
        guard let start = time(event.start) else { return "" }
        let minutes = Int(start.timeIntervalSince(now) / 60)
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        return "at " + shortTime(event.start)
    }

    // MARK: What Pip is asked to do

    static let briefPrompt = "Build my brief for today. Check today's calendar (Apple Calendar, and Google Calendar if it's connected), "
        + "mail from the last day that needs me (Apple Mail, and Gmail if it's connected), Reminders due today or overdue, "
        + "and your own files: priorities.md, commitments.md and people/. "
        + "Then write today.json using the exact top-level schema (date, updated, summary, events, focus as [{text,why,done}], "
        + "followups as [{what,who,due,mine,overdue,done}], inbox, notes) while preserving any existing xBrief, "
        + "and add a short entry to today's daily note. "
        + "The Today screen shows today.json directly; keep your chat reply to 2-4 crisp lines summarizing what's new or needs attention so we can discuss or refine it here. "
        + "If a source can't be reached, include a short note in today.json's notes array and carry on."

    static let wrapPrompt = "Wrap up my day. From today's calendar, your notes and what I asked you today: what got done, what's still open, "
        + "and what tomorrow starts with. Update commitments.md, today's daily note, and today.json (summary and followups). Reply in at most four short lines."

    static let nextPrompt = "What's next for me? Use today.json if it's from today, or check the calendar if it isn't. "
        + "One or two lines: the next thing, when, and anything I should have ready for it."
}

// MARK: - The popup strip

/// Pip's strip: the next thing on the calendar and how many follow-ups are open. Clicking it opens the desk.
struct OfficeStrip: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var office: Office
    let tint: Color
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar").font(.system(size: 12)).foregroundColor(tint)
            if let event = office.next(after: now) {
                Text(Office.countdown(event, now: now))
                    .font(.system(size: 12, weight: .bold))
                Text(event.title ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            } else {
                Text(office.isCurrent ? "Nothing else on the calendar today" : "No brief yet today")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            let open = office.openFollowUps.count
            if open > 0 {
                Text("\(open) open")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.fill.tertiary, in: Capsule())
                    .help("Follow-ups: things you owe and things you're waiting on")
            }
            Button("Desk") { session.onOpenWorkspace?() }
                .capsuleButton(tint: tint, prominent: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Surface.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 10)
        .onAppear { office.reload() }
        .onReceive(clock) { value in
            now = value
            office.reload()
        }
        .onChange(of: session.busy) { office.reload() }
        .onChange(of: session.showTick) { office.reload() }
    }
}

// MARK: - The desk's Today view

private enum FollowUpFilter: String, CaseIterable {
    case all = "All"
    case mine = "You owe"
    case waiting = "Waiting"
}

struct TodayView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var office: Office
    let name: String
    let tint: Color
    var railOpen: Bool = false
    var onToggleRail: (() -> Void)? = nil
    var onFocusRail: ((String?) -> Void)? = nil
    var onOpenFeed: (() -> Void)? = nil

    @State private var now = Date()
    @State private var followFilter: FollowUpFilter = .all
    @State private var showDoneFollowUps = false
    @State private var addingFocus = false
    @State private var newFocusText = ""
    @State private var addingFollowUp = false
    @State private var newFollowText = ""
    @State private var newFollowWho = ""
    @State private var newFollowMine = true
    @FocusState private var focusInputFocused: Bool
    @FocusState private var followInputFocused: Bool

    private static let headerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var dateLine: String {
        Self.headerDateFormatter.string(from: now)
    }

    private var hasAnyBriefContent: Bool {
        office.isCurrent || !office.focus.isEmpty || !office.followups.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerBar

            if session.busy {
                workingBanner
            }

            if !office.isCurrent && !session.busy {
                emptyBriefCard
            } else if office.isCurrent {
                briefHeroCard
            }

            if hasAnyBriefContent || session.busy {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 14) {
                            focusCard
                            scheduleCard
                        }
                        .frame(minWidth: 310, maxWidth: .infinity, alignment: .topLeading)

                        VStack(alignment: .leading, spacing: 14) {
                            followCard
                            if !office.inbox.isEmpty { inboxCard }
                        }
                        .frame(minWidth: 310, maxWidth: .infinity, alignment: .topLeading)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        focusCard
                        scheduleCard
                        followCard
                        if !office.inbox.isEmpty { inboxCard }
                    }
                }
            }

            if let xBrief = office.xBrief {
                xBriefCard(xBrief)
            }
        }
        .onAppear { office.reload() }
        .onReceive(clock) { value in
            now = value
            office.reload()
        }
        .task(id: session.busy) {
            office.reload()
            guard session.busy else { return }
            while !Task.isCancelled && session.busy {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { break }
                office.reload()
            }
        }
        .onChange(of: session.steps.count) { office.reload() }
        .onChange(of: session.messages.count) { office.reload() }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Today").font(.system(size: 24, weight: .bold))
            Text(dateLine).font(.system(size: 13)).foregroundStyle(.secondary)
            if office.isCurrent, let at = office.loadedAt {
                Text("· Updated " + at.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if office.isCurrent {
                Button("Wrap Day", systemImage: "moon.stars") {
                    askInRail(display: "Wrap up my day", prompt: Office.wrapPrompt)
                }
                .controlSize(.small)
                .disabled(session.busy)
                .help("Review what got done and roll open loops to tomorrow")
            }
            if let onToggleRail {
                Button {
                    onToggleRail()
                } label: {
                    Label(railOpen ? "Hide Chat" : "Ask \(name)", systemImage: "sidebar.right")
                }
                .controlSize(.small)
                .help(railOpen ? "Hide the conversation rail" : "Open the right rail to ask questions or modify your brief")
            }
            Button(office.isCurrent ? "Refresh" : "Brief Me", systemImage: "sun.max", action: runBrief)
                .buttonStyle(.glassProminent)
                .tint(tint)
                .disabled(session.busy)
        }
    }

    // MARK: Live working state & empty state

    private var workingBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(liveWorkingTitle)
                    .font(.system(size: 13, weight: .medium))
                Text("Updates appear right here as \(name) writes your brief.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !railOpen, let onFocusRail {
                Button("Show Rail") { onFocusRail(nil) }.controlSize(.small)
            }
            Button("Stop") { session.stop() }.controlSize(.small)
        }
        .solidCard(corner: 16, padding: 14)
    }

    private var liveWorkingTitle: String {
        if let active = session.plan.first(where: { $0.status == "active" }) { return active.active }
        if let step = session.steps.last, !step.detail.isEmpty { return "\(name): " + step.detail }
        return "\(name) is building your brief…"
    }

    private var emptyBriefCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill").foregroundStyle(tint)
                Text("Your daily brief lives here").font(.system(size: 15, weight: .semibold))
            }
            Text("\(name) checks your calendar, mail, reminders, and notes — then lays out your schedule, priorities, follow-ups, and inbox right here. Use the right rail anytime to ask questions or make changes.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Build Today’s Brief", systemImage: "sun.max", action: runBrief)
                    .buttonStyle(.borderedProminent).tint(tint).controlSize(.small)
                if let onFocusRail {
                    Button("Ask \(name)…", systemImage: "bubble.left") {
                        onFocusRail("Build my brief for today, focusing on: ")
                    }
                    .controlSize(.small)
                }
            }
        }
        .solidCard(corner: 18, padding: 18)
    }

    // MARK: Executive Brief Hero

    private var briefHeroCard: some View {
        let nextEvent = office.next(after: now)
        let openFocusCount = office.focus.filter { !$0.done }.count
        let openFollowCount = office.openFollowUps.count
        let overdueCount = office.openFollowUps.filter(\.isOverdue).count
        let inboxCount = office.inbox.count

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Daily Brief", systemImage: "sun.max.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer()
                Button {
                    prefillRail("Update today's brief: ")
                } label: {
                    Label("Modify in Rail", systemImage: "pencil")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .help("Ask \(name) in the right rail to adjust priorities, schedule, or follow-ups")
            }

            if let summary = office.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(defaultSummaryLine(nextEvent: nextEvent, openFocus: openFocusCount, openFollow: openFollowCount, overdue: overdueCount))
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FlowRow(spacing: 8) {
                if let nextEvent {
                    metricPill(icon: "calendar",
                               text: "\(nextEvent.title ?? "Next event") · \(Office.countdown(nextEvent, now: now))",
                               accent: tint)
                } else {
                    metricPill(icon: "calendar", text: office.events.isEmpty ? "Clear calendar" : "Done with meetings", accent: nil)
                }
                if !office.focus.isEmpty {
                    metricPill(icon: "target",
                               text: openFocusCount == 0 ? "All priorities done" : "\(openFocusCount) of \(office.focus.count) priorities left",
                               accent: openFocusCount == 0 ? .green : nil)
                }
                if openFollowCount > 0 {
                    metricPill(icon: "checklist", text: "\(openFollowCount) follow-up\(openFollowCount == 1 ? "" : "s")", accent: nil)
                }
                if overdueCount > 0 {
                    metricPill(icon: "exclamationmark.circle.fill", text: "\(overdueCount) overdue", accent: .orange)
                }
                if inboxCount > 0 {
                    metricPill(icon: "envelope.badge", text: "\(inboxCount) in inbox", accent: nil)
                }
                if office.xBrief != nil {
                    metricPill(icon: "line.3.horizontal.decrease.circle", text: "X Brief included", accent: tint)
                }
            }

            if !office.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(office.notes, id: \.self) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                            Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .solidCard(corner: 18, padding: 16)
    }

    private func defaultSummaryLine(nextEvent: OfficeEvent?, openFocus: Int, openFollow: Int, overdue: Int) -> String {
        var bits: [String] = []
        if let nextEvent {
            bits.append("Next up is \(nextEvent.title ?? "an event") \(Office.countdown(nextEvent, now: now)).")
        } else if office.events.isEmpty {
            bits.append("Your calendar is clear today.")
        }
        if openFocus > 0 {
            bits.append("\(openFocus) priorit\(openFocus == 1 ? "y" : "ies") in focus.")
        }
        if overdue > 0 {
            bits.append("\(overdue) overdue item\(overdue == 1 ? "" : "s") need attention.")
        } else if openFollow > 0 {
            bits.append("\(openFollow) open follow-up\(openFollow == 1 ? "" : "s") tracked.")
        }
        return bits.isEmpty ? "Today's brief is ready. Ask \(name) in the right rail to add or adjust anything." : bits.joined(separator: " ")
    }

    private func metricPill(icon: String, text: String, accent: Color?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent ?? .secondary)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accent == .orange ? .orange : .primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background((accent ?? .secondary).opacity(accent == nil ? 0.10 : 0.13), in: Capsule())
    }

    // MARK: Priorities (Focus)

    private var focusCard: some View {
        let openCount = office.focus.filter { !$0.done }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionTitle(text: "Priorities")
                if !office.focus.isEmpty {
                    countBadge("\(openCount)/\(office.focus.count)")
                }
                Spacer()
                Button {
                    addingFocus.toggle()
                    if addingFocus { focusInputFocused = true }
                } label: {
                    Image(systemName: addingFocus ? "xmark" : "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(addingFocus ? "Cancel" : "Add a priority")

                Button {
                    prefillRail("Help me refine today's priorities: ")
                } label: {
                    Image(systemName: "bubble.left")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Ask \(name) to adjust priorities")
            }

            if office.focus.isEmpty && !addingFocus {
                Text("No priorities set yet. Add one here or ask \(name) to pick the top three for today.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(office.focus) { item in
                HStack(alignment: .top, spacing: 9) {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { office.toggleFocus(item.id) }
                    } label: {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(item.done ? tint : .secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 1)
                    .help(item.done ? "Mark not done" : "Mark done")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text)
                            .font(.system(size: 13, weight: item.done ? .regular : .medium))
                            .strikethrough(item.done, color: .secondary)
                            .foregroundStyle(item.done ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let why = item.why, !why.isEmpty {
                            Text(why)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    Button {
                        prefillRail("About today's priority \"\(item.text)\": ")
                    } label: {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Ask \(name) about this priority")
                }
                .padding(.vertical, 2)
            }

            if addingFocus {
                HStack(spacing: 8) {
                    TextField("Add a priority for today…", text: $newFocusText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($focusInputFocused)
                        .onSubmit(commitNewFocus)
                    Button("Add", action: commitNewFocus)
                        .controlSize(.small)
                        .disabled(newFocusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 2)
            }
        }
        .solidCard(corner: 18, padding: 15)
    }

    private func commitNewFocus() {
        let text = newFocusText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        office.addFocus(text)
        newFocusText = ""
        addingFocus = false
    }

    // MARK: Schedule

    private var scheduleCard: some View {
        let next = office.next(after: now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionTitle(text: "Schedule")
                if !office.events.isEmpty { countBadge("\(office.events.count)") }
                Spacer()
                Button {
                    prefillRail("About my schedule today: ")
                } label: {
                    Image(systemName: "bubble.left")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Ask \(name) about your schedule")
            }

            if office.events.isEmpty {
                Text(office.isCurrent ? "A clear calendar today." : "—")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            ForEach(office.events) { event in
                let end = Office.time(event.end) ?? Office.time(event.start)?.addingTimeInterval(1800)
                let past = (end ?? now) <= now
                let isNext = event.id == next?.id

                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isNext ? tint : (past ? Color.secondary.opacity(0.25) : Surface.separator))
                        .frame(width: 3)
                        .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(Office.shortTime(event.start))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        if let endText = event.end, !endText.isEmpty {
                            Text(Office.shortTime(endText))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 62, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(event.title ?? "")
                                .font(.system(size: 13, weight: isNext ? .semibold : .regular))
                                .fixedSize(horizontal: false, vertical: true)
                            if let source = event.source {
                                Circle()
                                    .fill(source == "google" ? Color.blue.opacity(0.75) : Color.red.opacity(0.75))
                                    .frame(width: 6, height: 6)
                                    .help(source == "google" ? "Google Calendar" : "Apple Calendar")
                            }
                        }
                        if let place = event.place, !place.isEmpty {
                            Text(place).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let prep = event.prep, !prep.isEmpty {
                            Text(prep).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }

                    Spacer(minLength: 4)

                    VStack(alignment: .trailing, spacing: 4) {
                        if isNext {
                            Text(Office.countdown(event, now: now))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(tint)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(tint.opacity(0.14), in: Capsule())
                        }
                        if !past {
                            rowButton("Prep") {
                                let title = event.title ?? "this meeting"
                                askInRail(display: "Prep me for \(title)",
                                          prompt: "Prepare me for my meeting today: \"\(title)\" at \(Office.shortTime(event.start)). "
                                            + "Check people/, recent mail, and notes for context, open items, and 2-3 things to have ready. Keep it crisp.")
                            }
                        }
                    }
                }
                .opacity(past ? 0.45 : 1)
                .padding(.vertical, 5)
                .padding(.horizontal, isNext ? 8 : 2)
                .background(isNext ? tint.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .solidCard(corner: 18, padding: 15)
    }

    // MARK: Follow-ups

    private var followCard: some View {
        let openAll = office.openFollowUps
        let doneAll = office.followups.filter(\.isDone)
        let mine = openAll.filter { $0.mine != false }
        let theirs = openAll.filter { $0.mine == false }
        let showFilterBar = !mine.isEmpty && !theirs.isEmpty

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionTitle(text: "Follow-ups")
                if !openAll.isEmpty { countBadge("\(openAll.count)") }
                Spacer()
                if showFilterBar {
                    HStack(spacing: 3) {
                        ForEach(FollowUpFilter.allCases, id: \.self) { option in
                            Button(option.rawValue) { followFilter = option }
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: followFilter == option ? .semibold : .regular))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(followFilter == option ? tint.opacity(0.16) : Color.clear, in: Capsule())
                                .foregroundStyle(followFilter == option ? tint : .secondary)
                        }
                    }
                }
                Button {
                    addingFollowUp.toggle()
                    if addingFollowUp { followInputFocused = true }
                } label: {
                    Image(systemName: addingFollowUp ? "xmark" : "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(addingFollowUp ? "Cancel" : "Add a follow-up")
            }

            if openAll.isEmpty && doneAll.isEmpty && !addingFollowUp {
                Text("Nothing open. Add one here or tell \(name) \"remind me to…\" or \"I'm waiting on…\".")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if (followFilter == .all || followFilter == .mine) && !mine.isEmpty {
                if followFilter == .all && !theirs.isEmpty {
                    Text("You owe").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                ForEach(mine) { item in followRow(item, owed: true) }
            }

            if (followFilter == .all || followFilter == .waiting) && !theirs.isEmpty {
                if followFilter == .all && !mine.isEmpty {
                    Text("Waiting on").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                }
                ForEach(theirs) { item in followRow(item, owed: false) }
            }

            if !doneAll.isEmpty {
                DisclosureGroup(isExpanded: $showDoneFollowUps) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(doneAll) { item in
                            HStack(spacing: 8) {
                                Button {
                                    withAnimation(.easeOut(duration: 0.15)) { office.toggleFollowUp(item.id) }
                                } label: {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(tint)
                                }
                                .buttonStyle(.plain)
                                Text(item.what ?? "")
                                    .font(.system(size: 12))
                                    .strikethrough(true, color: .secondary)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("\(doneAll.count) completed today")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }

            if addingFollowUp {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("What needs to happen?", text: $newFollowText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($followInputFocused)
                        .onSubmit(commitNewFollowUp)
                    HStack(spacing: 8) {
                        TextField("Who (optional)", text: $newFollowWho)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(maxWidth: 160)
                            .onSubmit(commitNewFollowUp)
                        Picker("", selection: $newFollowMine) {
                            Text("You owe").tag(true)
                            Text("Waiting on").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 150)
                        Spacer()
                        Button("Add", action: commitNewFollowUp)
                            .controlSize(.small)
                            .disabled(newFollowText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.top, 4)
            }
        }
        .solidCard(corner: 18, padding: 15)
    }

    private func commitNewFollowUp() {
        let text = newFollowText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        office.addFollowUp(what: text, who: newFollowWho, mine: newFollowMine)
        newFollowText = ""
        newFollowWho = ""
        addingFollowUp = false
    }

    private func followRow(_ item: FollowUp, owed: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if owed {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { office.toggleFollowUp(item.id) }
                } label: {
                    Image(systemName: "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(item.isOverdue ? Color.orange : Color.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .help("Mark done")
            } else {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(item.isOverdue ? Color.orange : Color.secondary)
                    .padding(.top, 3)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.what ?? "")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if item.isOverdue {
                        Text("Overdue")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                    }
                    let meta = [item.who, item.due.map { "due " + $0 }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !meta.isEmpty { Text(meta).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 4)
            if !owed {
                rowButton("Nudge") {
                    askInRail(display: "Nudge \(item.who ?? "them") about \(item.what ?? "")",
                              prompt: "Draft a short, friendly nudge to \(item.who ?? "them") about: \(item.what ?? ""). Show me the draft here. Don't send it.")
                }
            }
            Button {
                prefillRail("About this follow-up (\"\(item.what ?? "")\"): ")
            } label: {
                Image(systemName: "bubble.left")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, 3)
            .help("Ask \(name) or modify this item")
        }
        .padding(.vertical, 2)
    }

    // MARK: Needs You (Inbox)

    private var inboxCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionTitle(text: "Needs you")
                countBadge("\(office.inbox.count)")
                Spacer()
            }
            ForEach(office.inbox) { item in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.subject ?? "")
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(2)
                        let meta = [item.from, item.why].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        if !meta.isEmpty {
                            Text(meta)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 4)
                    rowButton("Draft reply") {
                        askInRail(display: "Draft a reply to \(item.from ?? "this"): \(item.subject ?? "")",
                                  prompt: "Draft a reply to the email from \(item.from ?? "them") about \"\(item.subject ?? "")\" (\(item.source ?? "mail")). "
                                    + "Read the thread first. Show me the draft here and don't send it.")
                    }
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { office.dismissInbox(item.id) }
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 3)
                    .help("Dismiss from Today")
                }
                .padding(.vertical, 2)
            }
        }
        .solidCard(corner: 18, padding: 15)
    }

    // MARK: X Feed Brief

    private func xBriefCard(_ brief: XFeedBrief) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("X Feed Brief", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                if let feed = brief.feed, !feed.isEmpty {
                    countBadge(feed)
                }
                if let updated = brief.updated, !updated.isEmpty {
                    Text(updated).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    prefillRail("About my X Feed brief: ")
                } label: {
                    Label("Ask \(name)", systemImage: "bubble.left")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

                if let onOpenFeed {
                    Button("Open Feed", action: onOpenFeed)
                        .controlSize(.small)
                }
                Menu {
                    if let onOpenFeed {
                        Button("Open X Feed", action: onOpenFeed)
                    }
                    Button("Dismiss from Today") {
                        withAnimation(.easeOut(duration: 0.15)) { office.clearXBrief() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }

            if let summary = brief.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !brief.themes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(brief.themes) { theme in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(theme.title)
                                .font(.system(size: 13, weight: .semibold))
                            if !theme.summary.isEmpty {
                                Text(theme.summary)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(2)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !theme.sources.isEmpty {
                                FlowRow(spacing: 6) {
                                    ForEach(theme.sources, id: \.self) { raw in
                                        if let url = URL(string: raw) {
                                            Button {
                                                NSWorkspace.shared.open(url)
                                            } label: {
                                                Label(XBriefTheme.linkLabel(raw), systemImage: "arrow.up.right")
                                                    .font(.system(size: 10, weight: .medium))
                                            }
                                            .buttonStyle(.bordered)
                                            .buttonBorderShape(.capsule)
                                            .controlSize(.mini)
                                            .help(raw)
                                        }
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Surface.text.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            if !brief.actions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Worth replying to or reading")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(brief.actions, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(tint)
                            Text(line).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .solidCard(corner: 18, padding: 16)
    }

    // MARK: Actions & helpers

    private func runBrief() {
        askInRail(display: office.isCurrent ? "Refresh my brief" : "Brief me", prompt: Office.briefPrompt)
    }

    private func askInRail(display: String, prompt: String) {
        onFocusRail?(nil)
        session.ask(display: display, prompt: prompt)
    }

    private func prefillRail(_ text: String) {
        if let onFocusRail {
            onFocusRail(text)
        } else {
            session.prefillDraft(text)
            session.focusTick += 1
        }
    }

    private func countBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.fill.tertiary, in: Capsule())
    }

    private func rowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .capsuleButton(tint: tint)
            .disabled(session.busy)
    }
}

// MARK: - Scheduled briefings and handing work to Nova

enum Briefings {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "briefings") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "briefings") }
    }

    /// The briefing that's due now and hasn't been given today: the morning brief, or the end-of-day wrap.
    static func due(now: Date = Date()) -> (display: String, prompt: String, key: String)? {
        if !enabled { return nil }
        let hour = Calendar.current.component(.hour, from: now)
        let day = Office.dayKey
        if hour >= 6 && hour < 12 && UserDefaults.standard.string(forKey: "brief.morning") != day {
            return ("Morning brief", Office.briefPrompt, "brief.morning")
        }
        if hour >= 17 && hour < 21 && UserDefaults.standard.string(forKey: "brief.evening") != day {
            return ("End-of-day wrap", Office.wrapPrompt, "brief.evening")
        }
        return nil
    }

    static func mark(_ key: String) {
        UserDefaults.standard.set(Office.dayKey, forKey: key)
    }
}
