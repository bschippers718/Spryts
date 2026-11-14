import AppKit
import SwiftUI

// MARK: - The popup strip

/// The forecaster's strip in the chat bubble: the weather right now, and the way to the five days.
struct SkyStrip: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var service: WeatherService

    var body: some View {
        HStack(spacing: 8) {
            if let today = service.days.first {
                Image(systemName: WeatherService.symbol(service.nowCode, day: service.isDay))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 15))
                Text("\(service.now)°")
                    .font(.system(size: 15, weight: .heavy))
                Text("H \(today.high)°  L \(today.low)°")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else {
                Image(systemName: "cloud.fill").font(.system(size: 13)).foregroundColor(.secondary)
                Text(service.note.isEmpty ? "No forecast yet" : service.note)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            Spacer()
            Button(action: { session.onOpenWorkspace?() }) {
                Text("5 days")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.14))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .onAppear { service.refresh() }
        .onChange(of: session.busy) { service.refresh() }
    }
}

// MARK: - The forecast room

@MainActor
final class ForecastRoomController: NSObject, Expansion {
    let window: NSWindow

    init(session: ChatSession, sheet: CharacterSheet) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = sheet.name + "'s forecast"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.10, green: 0.12, blue: 0.17, alpha: 1)
        let view = SkyRoomView(session: session, service: WeatherService.of(sheet.id), name: sheet.name)
        window.contentView = NSHostingView(rootView: view)
    }

    var isOpen: Bool { window.isVisible && !window.isMiniaturized }
    var isKey: Bool { window.isKeyWindow }
    var number: Int { window.windowNumber }
    var tethers: Bool { true }

    func show() {
        if !window.isVisible, let screen = NSScreen.screens.first {
            let area = screen.visibleFrame
            let width = min(860, area.width - 80)
            let height = min(600, area.height - 220)
            window.setFrame(NSRect(x: area.midX - width / 2, y: area.minY + 40, width: width, height: height), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}

/// The room is the sky itself: its colour is today's weather, the week is one ribbon across it,
/// and the forecaster answers questions about it underneath.
struct SkyRoomView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var service: WeatherService
    let name: String

    @State private var city = ""
    @State private var editingCity = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if service.days.isEmpty {
                empty
            } else {
                SkyRibbon(days: service.days)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 240, maxHeight: .infinity)
            }
            answer
            asking
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .padding(.bottom, 18)
        .background(LinearGradient(colors: WeatherService.sky(service.nowCode, day: service.isDay), startPoint: .top, endPoint: .bottom))
        .fontDesign(.rounded)
        .environment(\.colorScheme, .dark)
        .onAppear { service.refresh() }
    }

    // MARK: Right now

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            if !service.days.isEmpty {
                Image(systemName: WeatherService.symbol(service.nowCode, day: service.isDay))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 54))
                    .frame(width: 70, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(service.now)°")
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundColor(.white)
                    Text(WeatherService.words(service.nowCode) + " · feels like \(service.feels)° · wind \(service.windNow) " + (service.metric ? "km/h" : "mph"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
            }
            Spacer()
            place
        }
    }

    /// The town, and the way to change it.
    private var place: some View {
        HStack(spacing: 6) {
            if editingCity {
                TextField("City or town", text: $city)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: 150)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.16))
                    .clipShape(Capsule())
                    .onSubmit {
                        service.setPlace(city)
                        editingCity = false
                    }
            } else {
                Button(action: {
                    city = service.wantedPlace
                    editingCity = true
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "location.fill").font(.system(size: 10))
                        Text(service.place.isEmpty ? "Set your city" : service.place)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundColor(.white)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "cloud.fill").font(.system(size: 44)).foregroundColor(.white.opacity(0.7))
            Text(service.note.isEmpty ? "No forecast yet." : service.note)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Text("Set your city at the top right, or just tell \(name) where you are.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Asking the forecaster

    private var lastReply: String {
        session.messages.last(where: { $0.role == "assistant" && !$0.hidden })?.text ?? ""
    }

    /// What the forecaster last said, so an answer stays in view next to the sky it is about.
    @ViewBuilder
    private var answer: some View {
        if session.busy {
            Text("\(name) is reading the sky…")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        } else if !lastReply.isEmpty {
            ScrollView {
                Text(lastReply)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 74)
            .padding(12)
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var asking: some View {
        HStack(spacing: 8) {
            chip("Umbrella today?") { ask("Do I need an umbrella today?") }
            chip("What to wear") { ask("What should I wear today?") }
            chip("Best day outside") { ask("Which of the next five days is best for being outside, and which is worst?") }
            TextField("Ask \(name) about the weather…", text: $session.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .focused($typing)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.14))
                .clipShape(Capsule())
                .onSubmit { session.send() }
        }
    }

    private func ask(_ question: String) {
        session.ask(display: question, prompt: question)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.16))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.busy)
    }
}
