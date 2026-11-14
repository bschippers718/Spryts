import AppKit
import SwiftUI

// MARK: - The coach's journal

/// What the coach has written down about this person: profile, plan and training log.
/// The coach itself keeps these files; this only reads them so the popup and the training room can show them.
final class TrainingJournal: ObservableObject {
    @Published var profile = ""
    @Published var plan = ""
    @Published var log = ""
    @Published var sessionsThisWeek = 0
    @Published var streak = 0
    @Published var lastSession = ""
    let folder: URL

    private static var shared: [String: TrainingJournal] = [:]

    /// One journal per coach, shared by its popup and its training room.
    static func of(_ id: String) -> TrainingJournal {
        if let existing = shared[id] { return existing }
        let journal = TrainingJournal(id: id)
        shared[id] = journal
        return journal
    }

    private init(id: String) {
        folder = Harness.trainingFolder(for: id)
        reload()
    }

    private func read(_ name: String) -> String {
        (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    func reload() {
        profile = read("profile.md")
        plan = read("plan.md")
        log = read("log.md")

        // Every log line starts with its date, which is all the numbers here need.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let calendar = Calendar.current
        var days: Set<Date> = []
        var thisWeek = 0
        var last = ""
        for raw in log.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix(" ") { line.removeFirst() }
            guard line.count >= 10, let date = formatter.date(from: String(line.prefix(10))) else { continue }
            days.insert(calendar.startOfDay(for: date))
            if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) { thisWeek += 1 }
            last = line
        }
        sessionsThisWeek = thisWeek
        lastSession = last

        // A streak counts back from today, or from yesterday if today hasn't happened yet.
        var count = 0
        var day = calendar.startOfDay(for: Date())
        if !days.contains(day), let yesterday = calendar.date(byAdding: .day, value: -1, to: day) { day = yesterday }
        while days.contains(day) {
            count += 1
            guard let before = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = before
        }
        streak = count
    }

    var summary: String {
        if log.isEmpty { return "No sessions logged yet" }
        let sessions = sessionsThisWeek == 1 ? "1 session this week" : "\(sessionsThisWeek) sessions this week"
        return streak >= 2 ? sessions + " · \(streak)-day streak" : sessions
    }
}

// MARK: - The training room: the coach's own expanded view

struct TrainingRoomView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var journal: TrainingJournal
    let name: String
    let teal: Color
    let coral: Color

    @State private var tab = "Today"
    @State private var minutes = 20
    @State private var place = "Home"
    @State private var focus = "Strength"
    @State private var effort = "Steady"
    @State private var activity = ""
    @State private var loggedMinutes = "30"
    @State private var feel = 3
    @FocusState private var typing: Bool

    private let ink = Color(red: 0.05, green: 0.11, blue: 0.13)
    private let card = Color.white.opacity(0.06)

    var body: some View {
        VStack(spacing: 0) {
            scoreboard
            HStack(spacing: 0) {
                conversation
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                board.frame(width: 400)
            }
        }
        .background(ink)
        .fontDesign(.rounded)
        .environment(\.colorScheme, .dark)
        .onAppear { journal.reload() }
        .onChange(of: session.busy) { journal.reload() }
    }

    // MARK: The numbers along the top

    private var scoreboard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 22, weight: .heavy))
                Text("Coach · " + session.modelLabel).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            tile("\(journal.sessionsThisWeek)", "this week", coral)
            tile("\(journal.streak)", journal.streak == 1 ? "day streak" : "day streak", teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("LAST SESSION").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                Text(journal.lastSession.isEmpty ? "Nothing logged yet" : journal.lastSession)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
            }
            .frame(width: 260, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func tile(_ number: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 0) {
            Text(number).font(.system(size: 26, weight: .heavy)).monospacedDigit().foregroundColor(color)
            Text(label.uppercased()).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
        }
        .frame(width: 92)
        .padding(.vertical, 6)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Talking to the coach

    private var visible: [ChatMessage] { session.messages.filter { !$0.hidden } }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if visible.isEmpty {
                            Text("Tell \(name) what you're training for, or build a workout on the right. \(name) remembers your goals, your plan and every session you log.")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .padding(.top, 30)
                        }
                        ForEach(visible) { message in
                            bubble(message).id(message.id)
                        }
                        if session.busy, let step = session.steps.last {
                            Text(step.detail.isEmpty ? step.tool : step.detail)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(18)
                }
                .onChange(of: session.messages) { proxy.scrollTo("end", anchor: .bottom) }
            }
            if let approval = session.approval {
                ApprovalCardView(session: session, approval: approval, name: name)
                    .padding(.horizontal, 14)
            }
            HStack(spacing: 10) {
                TextField("Tell \(name) how it went, or ask for a session…", text: $session.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($typing)
                    .onSubmit { session.send() }
                if session.busy {
                    Button(action: { session.stop() }) {
                        Image(systemName: "stop.circle.fill").font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(14)
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 14))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(coral.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            MarkdownView(text: message.text)
                .font(.system(size: 14))
                .padding(.trailing, 40)
        }
    }

    // MARK: The board on the right

    private var board: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(["Today", "Plan", "Log", "Profile"], id: \.self) { title in
                    Button(action: { tab = title }) {
                        Text(title)
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(tab == title ? teal.opacity(0.9) : Color.clear)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            ScrollView {
                Group {
                    if tab == "Today" {
                        today
                    } else if tab == "Plan" {
                        page(journal.plan, empty: "No plan yet.", ask: "Build me a plan",
                             prompt: "Build me a training plan. Check my profile first and ask me anything you still need to know.")
                    } else if tab == "Log" {
                        page(journal.log, empty: "Nothing logged yet. Log a session from Today.", ask: "How's my training going?",
                             prompt: "Look at my log and tell me how my training is going: what the numbers show first, then what you'd change.")
                    } else {
                        page(journal.profile, empty: "\(name) doesn't know you yet.", ask: "Set up my profile",
                             prompt: "Set up my athlete profile. Ask me the few questions you need, then write it down.")
                    }
                }
                .padding(14)
            }
        }
    }

    private func page(_ text: String, empty: String, ask: String, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(empty).font(.system(size: 13)).foregroundColor(.secondary)
            } else {
                MarkdownView(text: text).font(.system(size: 13))
            }
            bigButton(ask) { session.ask(display: ask, prompt: prompt) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var today: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("WORKOUT RIGHT NOW") {
                picker("Time", [10, 20, 30, 45, 60].map { "\($0)" }, "\(minutes)") { minutes = Int($0) ?? 20 }
                picker("Where", ["Home", "Gym", "Outdoors", "Hotel"], place) { place = $0 }
                picker("Focus", ["Strength", "Cardio", "Mobility", "Mix"], focus) { focus = $0 }
                picker("Effort", ["Easy", "Steady", "Hard"], effort) { effort = $0 }
                bigButton("Build my workout") {
                    let display = "\(minutes) min · \(place) · \(focus) · \(effort)"
                    session.ask(display: display, prompt:
                        "Give me a workout right now: \(minutes) minutes, at \(place.lowercased()), focus \(focus.lowercased()), effort \(effort.lowercased()). "
                        + "Check my profile and recent log so it fits my level and what I did lately. Warm-up, main set, cool-down, with an easier and a harder option.")
                }
            }
            section("LOG A SESSION") {
                TextField("What did you do? (run, lift, yoga…)", text: $activity)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(8)
                    .background(card)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 8) {
                    TextField("30", text: $loggedMinutes)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .frame(width: 44)
                        .padding(8)
                        .background(card)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("min").font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    Text("Felt").font(.system(size: 12)).foregroundColor(.secondary)
                    ForEach(1...5, id: \.self) { value in
                        Button(action: { feel = value }) {
                            Text("\(value)")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 24, height: 24)
                                .background(feel == value ? coral : card)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                bigButton("Log it") {
                    let what = activity.trimmingCharacters(in: .whitespaces)
                    if what.isEmpty { return }
                    let display = "Logged: \(what), \(loggedMinutes) min, felt \(feel)/5"
                    session.ask(display: display, prompt:
                        "Log this session in log.md with today's date: \(what), \(loggedMinutes) minutes, felt \(feel) out of 5. "
                        + "Then give me one or two sentences on how it fits the plan and what's next.")
                    activity = ""
                }
            }
            section("CHECK IN") {
                HStack(spacing: 6) {
                    chip("How's my week?") {
                        session.ask(display: "How's my week?", prompt: "How is my week going against the plan? Numbers first, then what to do with the days left.")
                    }
                    chip("I'm sore") {
                        session.draft = "I'm sore: "
                        typing = true
                    }
                }
                HStack(spacing: 6) {
                    chip("Analyse my data…") { attachData() }
                    chip("Adjust my plan") {
                        session.draft = "Adjust my plan: "
                        typing = true
                    }
                }
            }
        }
    }

    private func attachData() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Analyse"
        panel.message = "Choose exports from Strava, Garmin, Apple Health, Whoop or similar."
        if panel.runModal() == .OK {
            for url in panel.urls { session.attach(url) }
            session.draft = "Analyse this training data. Tell me what it shows before you recommend anything."
            typing = true
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 10, weight: .heavy)).foregroundColor(teal)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func picker(_ label: String, _ options: [String], _ selected: String, choose: @escaping (String) -> Void) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 44, alignment: .leading)
            ForEach(options, id: \.self) { option in
                Button(action: { choose(option) }) {
                    Text(option)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(selected == option ? teal.opacity(0.9) : Color.white.opacity(0.07))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.busy)
    }

    private func bigButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .heavy))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(coral)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(session.busy)
    }
}

@MainActor
final class TrainingRoomController: NSObject, Expansion {
    let window: NSWindow

    init(session: ChatSession, sheet: CharacterSheet) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = sheet.name + "'s training room"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.05, green: 0.11, blue: 0.13, alpha: 1)
        let view = TrainingRoomView(session: session, journal: TrainingJournal.of(sheet.id), name: sheet.name,
                                    teal: Color(nsColor: NSColor(hex: sheet.look.body)),
                                    coral: Color(nsColor: NSColor(hex: sheet.look.trim ?? "#FF5A3C")))
            .padding(.top, 28)
        window.contentView = NSHostingView(rootView: view)
    }

    var isOpen: Bool { window.isVisible && !window.isMiniaturized }
    var isKey: Bool { window.isKeyWindow }
    var number: Int { window.windowNumber }
    var tethers: Bool { true }

    func show() {
        if !window.isVisible, let screen = NSScreen.screens.first {
            let area = screen.visibleFrame
            let width = min(1080, area.width - 80)
            let height = min(680, area.height - 220)
            window.setFrame(NSRect(x: area.midX - width / 2, y: area.minY + 40, width: width, height: height), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}
