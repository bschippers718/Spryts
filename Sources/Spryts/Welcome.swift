import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

// First-run welcome and setup guide for Spryts Studio.
// Native macOS surfaces, zero forced permissions, and live connections to the real characters on stage.

enum Onboarding {
    private static let completedKey = "onboarding.completed"

    static var isCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }
}

enum WelcomeLaunchAction {
    case pipToday
    case novaIDE
    case drizzleWeather
    case joyClimb
    case justDesktop
}

struct WelcomeCastItem: Identifiable {
    let id: String
    let name: String
    let role: String
    let title: String
    let summary: String
    let symbol: String
    let tint: Color
}

@MainActor
final class WelcomeModel: ObservableObject {
    @Published var step: Int = 0
    @Published var selectedEngine: String = Engine.current
    @Published var highlightedID: String?
    @Published var accessibilityAllowed = false
    @Published var screenRecordingAllowed = false

    let cast: [WelcomeCastItem]
    let onWave: (String) -> Void
    let onEngineChanged: (String) -> Void
    let onFinish: (WelcomeLaunchAction) -> Void

    static let stepTitles = ["Meet Your Team", "AI Engine", "Controls & Privacy", "Get Started"]

    init(
        cast: [WelcomeCastItem],
        onWave: @escaping (String) -> Void,
        onEngineChanged: @escaping (String) -> Void,
        onFinish: @escaping (WelcomeLaunchAction) -> Void
    ) {
        self.cast = cast
        self.onWave = onWave
        self.onEngineChanged = onEngineChanged
        self.onFinish = onFinish
        refreshPermissions()
    }

    func chooseEngine(_ engine: String) {
        selectedEngine = engine
        Engine.current = engine
        onEngineChanged(engine)
        Connector.of(engine).refresh()
    }

    func refreshPermissions() {
        accessibilityAllowed = AXIsProcessTrusted()
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
    }

    func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) else { return }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel
    @ObservedObject private var claude = Connector.of("claude")
    @ObservedObject private var grok = Connector.of("grok")

    private var accent: Color {
        model.cast.first(where: { $0.role == "generalist" })?.tint ?? .accentColor
    }

    var body: some View {
        VStack(spacing: 0) {
            stepHeader
            Divider()
            ScrollView {
                Group {
                    switch model.step {
                    case 0: teamStep
                    case 1: engineStep
                    case 2: controlsStep
                    default: launchStep
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footerBar
        }
        .background(Surface.text)
        .tint(accent)
        .onAppear {
            model.refreshPermissions()
            claude.refresh()
            grok.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    // MARK: Header with step pills

    private var stepHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                Text("Welcome to Spryts")
                    .font(.system(size: 15, weight: .semibold))
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<WelcomeModel.stepTitles.count, id: \.self) { index in
                    let active = index == model.step
                    let done = index < model.step
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) { model.step = index }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: done ? "checkmark.circle.fill" : "\(index + 1).circle.fill")
                                .font(.system(size: 11))
                            Text(WelcomeModel.stepTitles[index])
                                .font(.system(size: 11, weight: active ? .semibold : .regular))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(active ? accent.opacity(0.15) : Color.clear, in: Capsule())
                        .foregroundStyle(active ? accent : (done ? .primary : .secondary))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 14)
    }

    // MARK: Step 1 — Meet the team

    private var teamStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Meet your desktop specialists")
                    .font(.system(size: 24, weight: .bold))
                Text("Each Spryt has one real job, its own workspace, and its own habits. Click any card below to see them wave on your screen.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(model.cast) { item in
                    let selected = model.highlightedID == item.id
                    Button {
                        model.highlightedID = item.id
                        model.onWave(item.id)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(item.tint)
                                .frame(width: 36, height: 36)
                                .background(item.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(item.name).font(.system(size: 14, weight: .semibold))
                                    Text(item.title).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Text(item.summary)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .solidCard(corner: 14, padding: 13)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(selected ? item.tint : Color.clear, lineWidth: 1.5)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Step 2 — Connect an AI engine

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect your AI engine")
                    .font(.system(size: 24, weight: .bold))
                Text("Spryts runs through the command-line AI agent installed on your Mac. Pick a default below — you can switch engines per character anytime.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                engineCard(
                    id: "claude",
                    title: "Claude Code",
                    subtitle: "Anthropic's local agent — great default for Pip, Nova, Ember, Rally, and Drizzle.",
                    connector: claude
                )
                engineCard(
                    id: "grok",
                    title: "Grok CLI",
                    subtitle: "xAI's local agent — fast runs with Spryts' built-in approval gate.",
                    connector: grok
                )
            }

            HStack(spacing: 8) {
                Image(systemName: claude.state == .connected || grok.state == .connected ? "checkmark.seal.fill" : "info.circle")
                    .foregroundStyle(claude.state == .connected || grok.state == .connected ? .green : .secondary)
                Text(
                    claude.state == .connected || grok.state == .connected
                        ? "You’re connected and ready to go. Nova also supports OpenAI Codex inside her IDE toolbar."
                        : "No CLI installed yet? You can skip this for now — Drizzle’s weather, Rally’s move breaks, and Joy’s arcade work right away, and you can connect anytime from a Spryt’s popup."
                )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    private func engineCard(id: String, title: String, subtitle: String, connector: Connector) -> some View {
        let selected = model.selectedEngine == id
        let status = engineStatus(connector)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? accent : .secondary)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        Text(status.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(status.color)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(status.color.opacity(0.13), in: Capsule())
                    }
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if connector.working.isEmpty {
                    if connector.state == .connected {
                        Button("Check") { connector.refresh() }
                            .controlSize(.small)
                    } else {
                        Button(connector.state == .missing ? "Install & Connect" : "Connect") {
                            model.chooseEngine(id)
                            connector.connect()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                        .controlSize(.small)
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { connector.cancel() }.controlSize(.small)
                    }
                }
            }

            if !connector.working.isEmpty {
                Text(connector.working)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)
            }
            if !connector.problem.isEmpty {
                Text(connector.problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30)
            }
        }
        .solidCard(corner: 14, padding: 14)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? accent : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { model.chooseEngine(id) }
    }

    private func engineStatus(_ connector: Connector) -> (label: String, color: Color) {
        switch connector.state {
        case .checking: return ("Checking…", .secondary)
        case .missing: return ("Not installed", .orange)
        case .signedOut: return ("Sign in needed", .orange)
        case .connected: return ("Connected", .green)
        }
    }

    // MARK: Step 3 — Controls & privacy

    private var controlsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Calm on screen, always under your control")
                    .font(.system(size: 24, weight: .bold))
                Text("Spryts stay out of your way until you reach for them — and ask before taking risky actions.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                tipCard(
                    symbol: "cursorarrow.click.2",
                    title: "Hover for chat, click for workspace",
                    detail: "Rest your pointer over a Spryt for a quick popup. Click once to open its full desk, IDE, studio, or arcade."
                )
                tipCard(
                    symbol: "hand.draw",
                    title: "Drag, drop files, or flick aside",
                    detail: "Set a Spryt on any window edge, drop files onto it to attach them, or flick it off the edge when you want a clear screen."
                )
                tipCard(
                    symbol: "command",
                    title: "Summon anywhere with ⌃⌥Space",
                    detail: "Bring Pip straight to your cursor from any app. Use the ✦ icon in the menu bar for Quiet Mode or to make your own Spryt."
                )
                tipCard(
                    symbol: "hand.raised.fill",
                    title: "Nothing risky without your click",
                    detail: "Sending mail, posting, deleting files, or running sensitive commands always pause for your approval button."
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(text: "Optional Mac access")
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refreshPermissions() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
                Text("Spryts never asks for these until you need them. You can enable them later in Pip → Connections.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    permissionPill("Accessibility", allowed: model.accessibilityAllowed, pane: "Privacy_Accessibility")
                    permissionPill("Screen Recording", allowed: model.screenRecordingAllowed, pane: "Privacy_ScreenCapture")
                    Spacer()
                }
            }
            .solidCard(corner: 14, padding: 14)
        }
    }

    private func tipCard(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .solidCard(corner: 14, padding: 13)
    }

    private func permissionPill(_ name: String, allowed: Bool, pane: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(allowed ? .green : .secondary)
            Text(name).font(.system(size: 12, weight: .medium))
            if !allowed {
                Button("Settings") { model.openPrivacyPane(pane) }
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Surface.text.opacity(0.7), in: Capsule())
    }

    // MARK: Step 4 — Pick a first action

    private var launchStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("You’re ready — pick a place to start")
                    .font(.system(size: 24, weight: .bold))
                Text("Jump straight into one of these, or close this window to explore your Spryts on the desktop.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                if model.cast.contains(where: { $0.role == "generalist" }) {
                    actionCard(
                        symbol: "sun.max.fill",
                        tint: color(for: "generalist"),
                        title: "Open Pip’s Today Desk",
                        detail: "See your daily brief, priorities, schedule, follow-ups, and X Feed in one calm workspace.",
                        button: "Open Today"
                    ) { model.onFinish(.pipToday) }
                }
                if model.cast.contains(where: { $0.role == "coder" }) {
                    actionCard(
                        symbol: "chevron.left.forwardslash.chevron.right",
                        tint: color(for: "coder"),
                        title: "Open Nova’s Coding Workspace",
                        detail: "Assign a repository folder, inspect diffs, and pair-program with live file previews.",
                        button: "Open IDE"
                    ) { model.onFinish(.novaIDE) }
                }
                if model.cast.contains(where: { $0.role == "forecaster" }) {
                    actionCard(
                        symbol: "cloud.sun.fill",
                        tint: color(for: "forecaster"),
                        title: "Check Local Weather with Drizzle",
                        detail: "Set your city once for real 5-day forecasts straight on your desktop.",
                        button: "Check Sky"
                    ) { model.onFinish(.drizzleWeather) }
                }
                if model.cast.contains(where: { $0.role == "gamer" }) {
                    actionCard(
                        symbol: "gamecontroller.fill",
                        tint: color(for: "gamer"),
                        title: "Play Window Climb with Joy",
                        detail: "Turn your open windows into a playable arcade level. Press Esc anytime to return.",
                        button: "Play Now"
                    ) { model.onFinish(.joyClimb) }
                }
            }
        }
    }

    private func color(for role: String) -> Color {
        model.cast.first(where: { $0.role == role })?.tint ?? accent
    }

    private func actionCard(symbol: String, tint: Color, title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .controlSize(.small)
        }
        .solidCard(corner: 14, padding: 14)
    }

    // MARK: Footer

    private var footerBar: some View {
        HStack {
            if model.step > 0 {
                Button("Back") {
                    withAnimation(.easeOut(duration: 0.16)) { model.step -= 1 }
                }
            } else {
                Button("Skip for Now") { model.onFinish(.justDesktop) }
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.step < WelcomeModel.stepTitles.count - 1 {
                Button("Continue") {
                    withAnimation(.easeOut(duration: 0.16)) { model.step += 1 }
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Finish & Explore Desktop") {
                    model.onFinish(.justDesktop)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}

@MainActor
final class WelcomeController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: WelcomeModel

    init(
        characters: [SprytCharacter],
        onWave: @escaping (String) -> Void,
        onEngineChanged: @escaping (String) -> Void,
        onFinish: @escaping (WelcomeLaunchAction) -> Void
    ) {
        let cast = characters.map { WelcomeController.describe($0) }
        var dismiss: (() -> Void)?
        let model = WelcomeModel(
            cast: cast,
            onWave: onWave,
            onEngineChanged: onEngineChanged,
            onFinish: { action in
                Onboarding.isCompleted = true
                dismiss?()
                onFinish(action)
            }
        )
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 550),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Spryts"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.contentView = NSHostingView(rootView: WelcomeView(model: model))
        dismiss = { [weak self] in self?.window.orderOut(nil) }
    }

    func show(fromStart: Bool = true) {
        if fromStart { model.step = 0 }
        model.refreshPermissions()
        if let screen = NSScreen.screens.first {
            let area = screen.visibleFrame
            let frame = window.frame
            window.setFrameOrigin(NSPoint(
                x: area.midX - frame.width / 2,
                y: area.midY - frame.height / 2 + 20
            ))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window.isVisible }

    func close() {
        window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Onboarding.isCompleted = true
    }

    private static func describe(_ character: SprytCharacter) -> WelcomeCastItem {
        let role = character.sheet.role ?? "generalist"
        let tint = Color(nsColor: NSColor(hex: character.sheet.look.body))
        switch role {
        case "generalist":
            return WelcomeCastItem(
                id: character.sheet.id, name: character.sheet.name, role: role,
                title: "Chief of Staff",
                summary: "Runs your Today brief, calendar, follow-ups, X Feed, and coordinates the rest of the team.",
                symbol: "sun.max.fill", tint: tint
            )
        case "coder":
            return WelcomeCastItem(
                id: character.sheet.id, name: character.sheet.name, role: role,
                title: "Programmer",
                summary: "Works inside your code repo with live diffs, undoable edits, builds, and tests.",
                symbol: "chevron.left.forwardslash.chevron.right", tint: tint
            )
        case "writer":
            return WelcomeCastItem(
                id: character.sheet.id, name: character.sheet.name, role: role,
                title: "Writing Partner",
                summary: "Drafts, tightens, and edits in your studio without flattening your voice.",
                symbol: "pencil.and.outline", tint: tint
            )
        case "coach":
            return WelcomeCastItem(
                id: character.sheet.id, name: character.sheet.name, role: role,
                title: "Fitness Coach",
                summary: "Tracks workouts, syncs Strava, and leads quick desk movement breaks.",
                symbol: "figure.run", tint: tint
            )
        case "forecaster":
            return WelcomeCastItem(
                id: character.sheet.id, name: character.sheet.name, role: role,
                title: "Forecaster",
                summary: "Real 5-day local weather and practical calls on layers, rain, and outdoor windows.",
                symbol: "cloud.sun.fill", tint: tint
            )
        case "gamer":
            return WelcomeCastItem(
                id: character.sheet.id, name: character.sheet.name, role: role,
                title: "Arcade",
                summary: "Turns your open desktop windows into playable levels — nothing real is ever touched.",
                symbol: "gamecontroller.fill", tint: tint
            )
        default:
            return WelcomeCastItem(
                id: character.sheet.id, name: character.sheet.name, role: role,
                title: "Companion",
                summary: "A custom desktop companion for conversation and company.",
                symbol: "sparkles", tint: tint
            )
        }
    }
}
