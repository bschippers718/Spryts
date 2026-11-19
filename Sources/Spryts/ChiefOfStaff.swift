import AppKit
import SwiftUI

// Pip's job: running the person's day. He keeps an office folder of plain files, and today.json in it
// is what his popup strip and his desk show. The app never reads the calendar or mail itself;
// Pip does, through his tools (Apple's apps, and Google if connected), and writes down what he found.

struct OfficeEvent: Codable, Identifiable {
    var id: String { (start ?? "") + (title ?? "") }
    let start: String?
    let end: String?
    let title: String?
    let place: String?
    let source: String?     // apple or google
}

struct FollowUp: Codable, Identifiable {
    var id: String { (what ?? "") + (who ?? "") }
    let what: String?
    let who: String?
    let due: String?
    let mine: Bool?         // true: the person owes it. false: they are waiting on someone.
}

struct InboxItem: Codable, Identifiable {
    var id: String { (from ?? "") + (subject ?? "") }
    let from: String?
    let subject: String?
    let why: String?
    let source: String?
}

struct TodayFile: Codable {
    let date: String?
    let updated: String?
    let events: [OfficeEvent]?
    let focus: [String]?
    let followups: [FollowUp]?
    let inbox: [InboxItem]?
}

final class Office: ObservableObject {
    @Published private(set) var today: TodayFile?
    @Published private(set) var loadedAt: Date?
    let folder: URL
    private var stamp: Date?

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

    static var dayKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Reads today.json again if it changed on disk.
    func reload() {
        let changed = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        if changed == stamp && today != nil { return }
        stamp = changed
        guard let data = try? Data(contentsOf: file) else {
            today = nil
            return
        }
        today = try? JSONDecoder().decode(TodayFile.self, from: data)
        loadedAt = changed
    }

    /// True when the file is about today, not a leftover from yesterday.
    var isCurrent: Bool { today?.date == Office.dayKey }

    var events: [OfficeEvent] { isCurrent ? (today?.events ?? []) : [] }
    var focus: [String] { today?.focus ?? [] }
    var followups: [FollowUp] { today?.followups ?? [] }
    var inbox: [InboxItem] { isCurrent ? (today?.inbox ?? []) : [] }

    static func time(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["HH:mm", "H:mm", "h:mm a", "h:mma", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: text.uppercased()) {
                if format.hasPrefix("yyyy") { return parsed }
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
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
        + "and your own files: priorities.md, commitments.md and people/. Then write today.json and add a short entry to today's daily note. "
        + "Reply with the brief in at most five short lines: what's first on the calendar, the one thing that matters most today, "
        + "anything overdue, and who is waiting on me. If a source can't be reached, say so in a few words and carry on."

    static let wrapPrompt = "Wrap up my day. From today's calendar, your notes and what I asked you today: what got done, what's still open, "
        + "and what tomorrow starts with. Update commitments.md, today's daily note, and the followups in today.json. Reply in at most five short lines."

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
            let open = office.followups.count
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

struct TodayView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var office: Office
    let name: String
    let tint: Color
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var dateLine: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Today").font(.system(size: 22, weight: .bold))
                Text(dateLine).font(.system(size: 13)).foregroundColor(.secondary)
                Spacer()
                if office.isCurrent, let at = office.loadedAt {
                    Text("Brief at " + at.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Button(office.isCurrent ? "Refresh" : "Brief Me", systemImage: "sun.max", action: brief)
                    .buttonStyle(.glassProminent)
                    .tint(tint)
                    .disabled(session.busy)
            }
            if !office.isCurrent {
                card {
                    Text("No brief yet today. \(name) will read your calendar, mail and reminders, Apple's and Google's, and lay out the day here.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                schedule.frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 14) {
                    if !office.focus.isEmpty { focusCard }
                    followCard
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if !office.inbox.isEmpty { inboxCard }
        }
        .onAppear { office.reload() }
        .onReceive(clock) { value in
            now = value
            office.reload()
        }
        .onChange(of: session.busy) { office.reload() }
    }

    private func brief() {
        session.ask(display: office.isCurrent ? "Refresh my brief" : "Brief me", prompt: Office.briefPrompt)
    }

    private func card<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SectionTitle(text: title) }
            content()
        }
        .solidCard(corner: 18, padding: 14)
    }

    private var schedule: some View {
        let next = office.next(after: now)
        return card("Schedule") {
            if office.events.isEmpty {
                Text(office.isCurrent ? "A clear day." : "—").font(.system(size: 13)).foregroundColor(.secondary)
            }
            ForEach(office.events) { event in
                let end = Office.time(event.end) ?? Office.time(event.start)?.addingTimeInterval(1800)
                let past = (end ?? now) <= now
                let isNext = event.id == next?.id
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Office.shortTime(event.start))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 66, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title ?? "").font(.system(size: 13, weight: isNext ? .bold : .regular))
                        if let place = event.place, !place.isEmpty {
                            Text(place).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if isNext {
                        Text(Office.countdown(event, now: now))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(tint)
                    }
                    if let source = event.source {
                        Circle().fill(source == "google" ? Color.blue.opacity(0.7) : Color.red.opacity(0.7))
                            .frame(width: 6, height: 6)
                            .help(source == "google" ? "Google Calendar" : "Apple Calendar")
                    }
                }
                .opacity(past ? 0.45 : 1)
                .padding(.vertical, 3)
                .padding(.horizontal, isNext ? 8 : 0)
                .background(isNext ? tint.opacity(0.14) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var focusCard: some View {
        card("What matters today") {
            ForEach(Array(office.focus.enumerated()), id: \.offset) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(item.offset + 1)").font(.system(size: 12, weight: .bold)).foregroundColor(tint)
                    Text(item.element).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var followCard: some View {
        let mine = office.followups.filter { $0.mine != false }
        let theirs = office.followups.filter { $0.mine == false }
        return card("Follow-ups") {
            if office.followups.isEmpty {
                Text("Nothing open. Tell \(name) \"remind me to…\" or \"I'm waiting on…\" and it lands here.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !mine.isEmpty {
                Text("You owe").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                ForEach(mine) { item in followRow(item, owed: true) }
            }
            if !theirs.isEmpty {
                Text("Waiting on").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).padding(.top, 4)
                ForEach(theirs) { item in followRow(item, owed: false) }
            }
        }
    }

    private func followRow(_ item: FollowUp, owed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.what ?? "").font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                let meta = [item.who, item.due.map { "due " + $0 }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !meta.isEmpty { Text(meta).font(.system(size: 11)).foregroundColor(.secondary) }
            }
            Spacer(minLength: 4)
            if owed {
                rowButton("Done") {
                    session.ask(display: "Done: " + (item.what ?? ""),
                                prompt: "I've done this: \(item.what ?? ""). Take it off my follow-ups in commitments.md and today.json. One line back.")
                }
            } else {
                rowButton("Nudge") {
                    session.ask(display: "Nudge \(item.who ?? "them") about \(item.what ?? "")",
                                prompt: "Draft a short, friendly nudge to \(item.who ?? "them") about: \(item.what ?? ""). Show me the draft here. Don't send it.")
                }
            }
        }
    }

    private var inboxCard: some View {
        card("Needs you") {
            ForEach(office.inbox) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.subject ?? "").font(.system(size: 13, weight: .medium)).lineLimit(1)
                        let meta = [item.from, item.why].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        if !meta.isEmpty { Text(meta).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2) }
                    }
                    Spacer(minLength: 4)
                    rowButton("Draft reply") {
                        session.ask(display: "Draft a reply to \(item.from ?? "this"): \(item.subject ?? "")",
                                    prompt: "Draft a reply to the email from \(item.from ?? "them") about \"\(item.subject ?? "")\" (\(item.source ?? "mail")). "
                                        + "Read the thread first. Show me the draft here and don't send it.")
                    }
                }
            }
        }
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

