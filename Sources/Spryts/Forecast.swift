import AppKit
import SwiftUI

// MARK: - The forecast, as the forecaster wrote it

/// What the forecaster has written: today's condition and forecast, and the week's outlook.
/// The forecaster keeps these files; this only reads them so the popup and the forecast room can show them.
final class ForecastModel: ObservableObject {
    @Published var condition = ""      // "Clear", "Showers", "Storm", or "" before the first forecast
    @Published var today = ""
    @Published var week = ""
    let folder: URL

    private static var shared: [String: ForecastModel] = [:]

    /// One model per forecaster, shared by its popup and its forecast room.
    static func of(_ id: String) -> ForecastModel {
        if let existing = shared[id] { return existing }
        let model = ForecastModel(id: id)
        shared[id] = model
        return model
    }

    private init(id: String) {
        folder = Harness.forecastFolder(for: id)
        reload()
    }

    func reload() {
        today = (try? String(contentsOf: folder.appendingPathComponent("forecast.md"), encoding: .utf8)) ?? ""
        week = (try? String(contentsOf: folder.appendingPathComponent("week.md"), encoding: .utf8)) ?? ""
        // The first line is always "Condition: X", so the popup and the room agree on what the sky is.
        let first = today.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let word = first.replacingOccurrences(of: "Condition:", with: "").trimmingCharacters(in: .whitespaces)
        condition = ["Clear", "Showers", "Storm"].contains(word) ? word : ""
    }

    /// The symbol and colour for a condition. Nothing forecast yet is a plain grey sky.
    static func look(_ condition: String) -> (symbol: String, label: String, tint: Color) {
        switch condition {
        case "Clear": return ("sun.max.fill", "Clear", .yellow)
        case "Showers": return ("cloud.drizzle.fill", "Showers", .blue)
        case "Storm": return ("cloud.bolt.rain.fill", "Storm", .purple)
        default: return ("cloud.fill", "No forecast yet", .gray)
        }
    }
}

// MARK: - The popup strip

/// The forecaster's strip in the chat bubble: the sky right now, and the way into the room.
struct ForecastStrip: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var model: ForecastModel

    var body: some View {
        let sky = ForecastModel.look(model.condition)
        HStack(spacing: 8) {
            Image(systemName: sky.symbol)
                .font(.system(size: 13))
                .foregroundColor(sky.tint)
            Text(sky.label)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer()
            Button(action: { session.onOpenWorkspace?() }) {
                Text("Forecast room")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(sky.tint.opacity(0.25))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .onAppear { model.reload() }
        .onChange(of: session.busy) { model.reload() }
    }
}

// MARK: - The forecast room

@MainActor
final class ForecastRoomController: NSObject, Expansion {
    let window: NSWindow

    init(session: ChatSession, sheet: CharacterSheet) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = sheet.name + "'s forecast room"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.10, green: 0.12, blue: 0.17, alpha: 1)
        let view = ForecastRoomView(session: session, model: ForecastModel.of(sheet.id), name: sheet.name)
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
            let width = min(960, area.width - 80)
            let height = min(640, area.height - 220)
            window.setFrame(NSRect(x: area.midX - width / 2, y: area.minY + 40, width: width, height: height), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}

/// The room itself: today's sky large on the left, the week's outlook on the right, and the ways to ask for more.
struct ForecastRoomView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var model: ForecastModel
    let name: String

    var body: some View {
        let sky = ForecastModel.look(model.condition)
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: sky.symbol)
                    .font(.system(size: 64))
                    .foregroundColor(sky.tint)
                Text(sky.label)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(model.today.isEmpty ? "\(name) hasn't looked at the sky yet. Ask for a forecast." : model.today)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    chip("Today's forecast") {
                        session.ask(display: "Today's forecast",
                                    prompt: "Give me today's forecast. Read my files and anything I've given you, then write forecast.md with the condition on its first line, and tell me the condition in one sentence.")
                    }
                    chip("Plan my week") {
                        session.ask(display: "Plan my week",
                                    prompt: "Give me the outlook for the next five to seven days. Write week.md, name the heaviest day, and say what to move if it's a storm.")
                    }
                    chip("It's a storm") {
                        session.ask(display: "It's a storm",
                                    prompt: "I'm overloaded. Re-forecast today as a storm if it is one, name the one or two things to move, shrink or drop, and suggest what to say to whoever is waiting.")
                    }
                }
            }
            .frame(width: 320, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 10) {
                Text("The week ahead")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                ScrollView {
                    Text(model.week.isEmpty ? "No outlook yet." : model.week)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(22)
        .onAppear { model.reload() }
        .onChange(of: session.busy) { model.reload() }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.busy)
    }
}
