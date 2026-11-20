import AppKit
import Combine
import SwiftUI

// Rally's movement breaks: pick a starter pack and how often, and he reminds you, then does it with you.
// Nothing here needs the AI: the timer, the reminder and the exercise all run in the app.

/// Which break is on, how often, and when the next one is due. Kept per coach.
@MainActor
final class MoveBreaks: ObservableObject {
    /// The pack that is on: an exercise id, "mix", or empty for none.
    @Published private(set) var pack: String
    /// Minutes between breaks: 30 or 60.
    @Published private(set) var every: Int
    @Published private(set) var due: Date?
    @Published private(set) var doneToday: Int
    /// Asks the coach on the stage to lead one. Returns false if he can't just now.
    var lead: ((Exercise) -> Bool)?

    private let id: String
    private var turn = 0
    private var retryAt = Date.distantPast
    private static var shared: [String: MoveBreaks] = [:]

    static func of(_ id: String) -> MoveBreaks {
        if let existing = shared[id] { return existing }
        let made = MoveBreaks(id: id)
        shared[id] = made
        return made
    }

    private var defaults: UserDefaults { .standard }

    init(id: String) {
        self.id = id
        let saved = UserDefaults.standard.string(forKey: "breaks.pack." + id) ?? ""
        pack = saved == Exercises.mix || Exercises.find(saved) != nil ? saved : ""
        every = UserDefaults.standard.integer(forKey: "breaks.every." + id) == 60 ? 60 : 30
        let day = UserDefaults.standard.string(forKey: "breaks.day." + id) ?? ""
        doneToday = day == MoveBreaks.today ? UserDefaults.standard.integer(forKey: "breaks.done." + id) : 0
        due = pack.isEmpty ? nil : Date().addingTimeInterval(TimeInterval(every * 60))
    }

    private static var today: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    var isOn: Bool { !pack.isEmpty }

    var packName: String {
        pack == Exercises.mix ? "Mix" : (Exercises.find(pack)?.name ?? "Off")
    }

    /// One line for the popup strip and the menu.
    var summary: String {
        guard isOn, let due else { return "Move breaks off" }
        let minutes = max(1, Int((due.timeIntervalSinceNow / 60).rounded(.up)))
        return "\(packName) in \(minutes) min"
    }

    /// Choosing a pack turns breaks on and starts with one straight away, so you know what you signed up for.
    func choose(_ id: String) {
        guard id == Exercises.mix || Exercises.find(id) != nil else { return }
        pack = id
        defaults.set(id, forKey: "breaks.pack." + self.id)
        due = Date().addingTimeInterval(TimeInterval(every * 60))
        doOneNow()
    }

    func setEvery(_ minutes: Int) {
        every = minutes == 60 ? 60 : 30
        defaults.set(every, forKey: "breaks.every." + id)
        if isOn { due = Date().addingTimeInterval(TimeInterval(every * 60)) }
    }

    func turnOff() {
        pack = ""
        due = nil
        defaults.set("", forKey: "breaks.pack." + id)
    }

    /// The exercise for the next break. A mix takes each in turn.
    private func next() -> Exercise? {
        if pack == Exercises.mix {
            let exercise = Exercises.all[turn % Exercises.all.count]
            turn += 1
            return exercise
        }
        return Exercises.find(pack)
    }

    func doOneNow() {
        guard let exercise = next() else { return }
        if lead?(exercise) == true { count() }
    }

    private func count() {
        doneToday += 1
        defaults.set(doneToday, forKey: "breaks.done." + id)
        defaults.set(MoveBreaks.today, forKey: "breaks.day." + id)
    }

    /// Called often. `away` is true when nobody has touched the Mac for a while: no point reminding an empty chair.
    func tick(away: Bool) {
        guard isOn, let due else { return }
        let now = Date()
        if now < due || now < retryAt { return }
        if away {
            // Hold it until they are back, then give them a couple of minutes to settle.
            retryAt = now.addingTimeInterval(120)
            return
        }
        if UserDefaults.standard.string(forKey: "breaks.day." + id) != MoveBreaks.today { doneToday = 0 }
        guard let exercise = next() else { return }
        if lead?(exercise) == true {
            count()
            self.due = now.addingTimeInterval(TimeInterval(every * 60))
            NSSound(named: "Glass")?.play()
        } else {
            // He is mid-jump or busy: try again shortly, with the same exercise.
            if pack == Exercises.mix { turn -= 1 }
            retryAt = now.addingTimeInterval(20)
        }
    }
}

/// The one control in Rally's popup: what the break is, how often, and a way to do one now.
struct MoveBreaksMenu: View {
    @ObservedObject var breaks: MoveBreaks

    var body: some View {
        Menu {
            Section("Starter packs") {
                ForEach(Exercises.all) { exercise in
                    Button { breaks.choose(exercise.id) } label: {
                        Label(exercise.name, systemImage: breaks.pack == exercise.id ? "checkmark" : exercise.symbol)
                    }
                }
                Button { breaks.choose(Exercises.mix) } label: {
                    Label("Mix It Up", systemImage: breaks.pack == Exercises.mix ? "checkmark" : "shuffle")
                }
            }
            Section("Remind me") {
                Button { breaks.setEvery(30) } label: {
                    Label("Every 30 Minutes", systemImage: breaks.every == 30 ? "checkmark" : "clock")
                }
                Button { breaks.setEvery(60) } label: {
                    Label("Every Hour", systemImage: breaks.every == 60 ? "checkmark" : "clock")
                }
            }
            if breaks.isOn {
                Divider()
                Button("Do One Now") { breaks.doOneNow() }
                Button("Turn Off") { breaks.turnOff() }
            }
        } label: {
            Label(breaks.isOn ? breaks.packName + " · " + (breaks.every == 60 ? "hourly" : "30 min") : "Move breaks",
                  systemImage: "figure.stand")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Rally reminds you to move, and does it with you")
    }
}

/// The same choice as cards, for the training room.
struct MoveBreaksCard: View {
    @ObservedObject var breaks: MoveBreaks
    let name: String
    let tint: Color
    @State private var now = Date()
    private let clock = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MOVE BREAKS").font(.system(size: 10, weight: .heavy)).foregroundColor(tint)
                Spacer()
                Text(status).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            Text("Pick one. \(name) reminds you, then does it with you.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Exercises.all) { exercise in
                    tile(exercise.id, exercise.name, exercise.symbol, exercise.ask)
                }
            }
            tile(Exercises.mix, "Mix It Up", "shuffle", "A different one each time.")
            HStack(spacing: 8) {
                Picker("Remind me", selection: Binding(get: { breaks.every }, set: { breaks.setEvery($0) })) {
                    Text("Every 30 min").tag(30)
                    Text("Every hour").tag(60)
                }
                .pickerStyle(.segmented).labelsHidden()
                if breaks.isOn {
                    Button("Do one now") { breaks.doOneNow() }
                    Button("Off") { breaks.turnOff() }
                }
            }
        }
        .onReceive(clock) { now = $0 }
    }

    private var status: String {
        _ = now
        let done = breaks.doneToday == 1 ? "1 today" : "\(breaks.doneToday) today"
        return breaks.isOn ? breaks.summary + " · " + done : "Off"
    }

    private func tile(_ id: String, _ title: String, _ symbol: String, _ detail: String) -> some View {
        let on = breaks.pack == id
        return Button { breaks.choose(id) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18)).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .bold))
                    Text(detail).font(.system(size: 11)).opacity(0.75).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if on { Image(systemName: "checkmark.circle.fill") }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? tint.opacity(0.9) : Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "On" : "Off")
    }
}
