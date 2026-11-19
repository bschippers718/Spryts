import AppKit
import SwiftUI

// Joy's own places: the strip in her popup and the arcade she opens into.
// The games themselves are in Arcade.swift; how a desktop becomes a level is in ArcadeLevels.swift.

/// The scores on show. Reloaded when a game ends.
@MainActor
final class ArcadeScores: ObservableObject {
    static let shared = ArcadeScores()
    @Published private(set) var best: [String: Int] = [:]
    @Published private(set) var boards: [String: [ScoreEntry]] = [:]

    static let games = [ArcadeGame.climb.rawValue, ArcadeGame.breaker.rawValue, OrangeSmash.id]

    init() { reload() }

    func reload() {
        var tops: [String: Int] = [:]
        var lists: [String: [ScoreEntry]] = [:]
        for game in ArcadeScores.games {
            let entries = Leaderboard.top(game, count: 8)
            lists[game] = entries
            tops[game] = entries.first?.score ?? 0
        }
        best = tops
        boards = lists
    }
}

/// Joy's strip: the scores to beat, and the way into the arcade.
struct ArcadeStrip: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var scores: ArcadeScores

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gamecontroller.fill").foregroundStyle(.secondary)
            Text(summary)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
            Spacer()
            Button("Arcade") { session.onOpenWorkspace?() }
                .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { scores.reload() }
    }

    private var summary: String {
        let climb = scores.best[ArcadeGame.climb.rawValue] ?? 0
        let breaker = scores.best[ArcadeGame.breaker.rawValue] ?? 0
        if climb == 0 && breaker == 0 { return "No scores yet. Your windows are waiting." }
        return "Climb \(climb.formatted()) · Breaker \(breaker.formatted())"
    }
}

// MARK: - The arcade: Joy's own expanded view

struct ArcadeRoomView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var scores: ArcadeScores
    let name: String
    let tint: Color
    @State private var board = ArcadeGame.climb.rawValue
    @State private var question = ""

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your desktop is the level").font(.system(size: 22, weight: .bold))
                        Text("Games play on top of whatever is open right now. Nothing is moved, closed or changed, and Esc gives the screen straight back.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(ArcadeGame.allCases) { game in
                        card(title: game.title, symbol: game.symbol, blurb: game.blurb, controls: game.controls,
                             best: scores.best[game.rawValue] ?? 0, prominent: true) {
                            session.onArcade?(game.rawValue)
                        }
                    }
                    card(title: "Orange Smash", symbol: "circle.hexagongrid.fill",
                         blurb: "\(name) lobs oranges across the screen. Flick the cursor through them and leave the bombs alone.",
                         controls: "Move or click the mouse · the scoreboard has pause and quit",
                         best: scores.best[OrangeSmash.id] ?? 0, prominent: false) {
                        session.onPlay?()
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity)
            Divider()
            side.frame(width: 300)
        }
        .background(Surface.text)
        .onAppear { scores.reload() }
    }

    private func card(title: String, symbol: String, blurb: String, controls: String, best: Int, prominent: Bool,
                      play: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(blurb).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(controls).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                if prominent {
                    Button("Play", action: play).buttonStyle(.borderedProminent).tint(tint)
                } else {
                    Button("Play", action: play)
                }
                VStack(alignment: .trailing, spacing: 0) {
                    Text("Best").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(best == 0 ? "—" : best.formatted()).font(.system(size: 15, weight: .semibold, design: .monospaced))
                }
            }
        }
        .solidCard()
    }

    /// High scores, and a word with Joy.
    private var side: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("High scores").font(.system(size: 13, weight: .semibold))
            Picker("Game", selection: $board) {
                Text("Climb").tag(ArcadeGame.climb.rawValue)
                Text("Breaker").tag(ArcadeGame.breaker.rawValue)
                Text("Oranges").tag(OrangeSmash.id)
            }
            .pickerStyle(.segmented).labelsHidden()
            let entries = scores.boards[board] ?? []
            if entries.isEmpty {
                Text("No scores yet. First run sets the record.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        HStack {
                            Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
                            Text(entry.score.formatted()).fontWeight(index == 0 ? .bold : .regular)
                            Spacer()
                            Text(entry.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12, design: .monospaced))
                    }
                }
            }
            Spacer(minLength: 8)
            Divider()
            Text(name + " says").font(.system(size: 13, weight: .semibold))
            Text(lastWords)
                .font(.system(size: 13)).foregroundStyle(session.busy ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(6)
            HStack(spacing: 6) {
                TextField("Ask for a tip…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                Button("Ask", action: ask).disabled(session.busy || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
    }

    private var lastWords: String {
        if session.busy { return "Thinking…" }
        let reply = session.messages.last(where: { $0.role == "assistant" && !$0.hidden })?.text ?? ""
        return reply.isEmpty ? "Pick a game. I'll be watching from the stage." : reply
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || session.busy { return }
        question = ""
        session.ask(display: text, prompt: text)
    }
}

@MainActor
final class ArcadeRoomController: NSObject, Expansion {
    let window: NSWindow

    init(session: ChatSession, sheet: CharacterSheet) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = sheet.name + "'s arcade"
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 760, height: 480)
        let view = ArcadeRoomView(session: session, scores: ArcadeScores.shared, name: sheet.name,
                                  tint: Color(nsColor: NSColor(hex: sheet.look.body)))
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
            let width = min(920, area.width - 80)
            let height = min(600, area.height - 220)
            window.setFrame(NSRect(x: area.midX - width / 2, y: area.minY + 40, width: width, height: height), display: true)
        }
        ArcadeScores.shared.reload()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}
