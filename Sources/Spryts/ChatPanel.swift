import AppKit
import SwiftUI
import UniformTypeIdentifiers

let chatPanelSize = CGSize(width: 384, height: 548)

/// The command panel: apps, what the agent is doing, approvals, and the conversation.
struct ChatView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var shelf: AppShelf
    @ObservedObject private var focus = FocusKeeper.shared
    let name: String
    let tint: Color
    let role: String
    @FocusState private var typing: Bool
    @State private var branch = ""
    @State private var speaks = false
    @Environment(\.colorScheme) private var systemScheme

    private var visibleMessages: [ChatMessage] {
        session.messages.filter { !$0.hidden }
    }

    private var isCoder: Bool { role == "coder" }
    private var isWriter: Bool { role == "writer" }
    private var isCoach: Bool { role == "coach" }
    private var isGeneralist: Bool { role == "generalist" }
    private var isForecaster: Bool { role == "forecaster" }

    private var emptyHint: String {
        if isCoach { return "\(name) is your coach. Ask for a workout, log a session, or click to open the training room." }
        if isForecaster { return "\(name) is your weather. Click the cloud for the next five days, or ask what to wear." }
        if !isCoder && !isWriter && !isGeneralist { return "Ask \(name) anything." }
        if isCoder { return "\(name) is the programmer. Click to open the IDE, or ask a quick question about the code here." }
        if isWriter { return "\(name) is the writer. Click to open the studio, or ask for a word, a line or a fix here." }
        return "\(name) runs your day: your calendar, mail, follow-ups and this Mac. Ask for a brief, tell \(name) what you promised, or click for your desk."
    }
    private var theme: RoleTheme { RoleTheme.of(role) }

    /// Glass needs no rules between its parts; the painted papers keep theirs.
    @ViewBuilder
    private var rule: some View {
        if !theme.glass { Divider() }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            rule
            roleStrip
            rule
            transcript
            if let approval = session.approval {
                ApprovalCardView(session: session, approval: approval, name: name)
                    .padding(.horizontal, 10)
            }
            rule
            if !session.attachments.isEmpty {
                attachmentRow
            }
            quickActions
            inputRow
        }
        .frame(width: chatPanelSize.width, height: chatPanelSize.height)
        .modifier(PanelSurface(theme: theme, tint: tint))
        .fontDesign(theme.design)
        .environment(\.colorScheme, theme.scheme ?? systemScheme)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in session.attach(url) }
                }
            }
            return true
        }
        .onChange(of: session.focusTick) {
            typing = true
        }
        .onAppear { speaks = SpeechOut.isOn(session.sheet.id) }
    }

    // MARK: Pieces

    /// One line of context: what is being worked on now, or what was asked last.
    private var contextLine: String? {
        guard let last = visibleMessages.last(where: { $0.role == "user" }) else { return nil }
        var ask = last.text.split(separator: "\n").first.map(String.init) ?? ""
        if ask.count > 70 { ask = String(ask.prefix(70)) + "…" }
        if ask.isEmpty { return nil }
        if session.approval != nil { return "Waiting for your OK: " + ask }
        return session.busy ? "Working on: " + ask : nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            headerRow
            if let line = contextLine {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The header stays quiet: who this is, a stop button while it works, and one menu for everything else.
    private var headerRow: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 10, height: 10)
            Text(name).font(.system(size: 13, weight: .semibold))
            Spacer()
            if session.busy {
                Button(action: { session.stop() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.glass ? Color.red : Color.primary)
                }
                .buttonStyle(.plain)
                .help("Stop")
            }
            if session.pinned {
                Button(action: { session.pinned = false }) {
                    Image(systemName: "pin.fill")
                }
                .buttonStyle(.plain)
                .help("Unpin")
            }
            moreMenu
        }
    }

    /// Things you reach for now and then: the big window, pinning, a game, the model, a fresh start.
    private var moreMenu: some View {
        Menu {
            if session.onOpenWorkspace != nil {
                Button("Open the " + AppDelegate.placeName(role)) { session.onOpenWorkspace?() }
            }
            Button(session.pinned ? "Unpin" : "Keep this open") { session.pinned.toggle() }
            if session.onPlay != nil {
                Button("Play Orange Smash") { session.onPlay?() }
            }
            Divider()
            EngineModelMenu(session: session)
            Button("New conversation") { session.newConversation() }
                .disabled(session.busy)
            Button(speaks ? "Stop reading replies aloud" : "Read replies aloud") {
                speaks.toggle()
                SpeechOut.set(speaks, for: session.sheet.id)
            }
            Divider()
            Text(session.providerLabel)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    /// The strip under the header is where each role differs: the day for the chief of staff, the project for the programmer.
    private var roleStrip: some View {
        Group {
            if isCoder {
                projectStrip
            } else if isWriter {
                writerStrip
            } else if isForecaster {
                SkyStrip(session: session, service: WeatherService.of(session.sheet.id))
            } else if isCoach {
                CoachStrip(session: session, journal: TrainingJournal.of(session.sheet.id), tint: tint)
            } else if isGeneralist {
                OfficeStrip(session: session, office: Office.of(session.sheet.id), tint: tint)
            } else {
                // A role with no strip of its own shows nothing here. It never borrows another character's.
                EmptyView()
            }
        }
    }

    /// The writer's strip: where the drafts live, the voice in use, and the way into the studio.
    private var writerStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.book.closed").font(.system(size: 13)).foregroundColor(.secondary)
            Text(session.projectFolder?.lastPathComponent ?? "Spryts Writing")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text((UserDefaults.standard.string(forKey: "studio.voice") ?? "Plain") + " voice")
                .font(.system(size: 11))
                .italic()
                .foregroundColor(.secondary)
            Spacer()
            Button(action: { session.onOpenWorkspace?() }) {
                Text("Open studio")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(tint.opacity(0.25))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var projectStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 12)).foregroundColor(.secondary)
            Text(session.projectFolder?.lastPathComponent ?? "No project yet")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if !branch.isEmpty {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            if !session.lastTest.isEmpty {
                Circle()
                    .fill(session.lastTest.hasPrefix("passed") ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                    .help(session.lastTest)
            }
            Spacer()
            Button("Open IDE") { session.onOpenWorkspace?() }
                .capsuleButton(tint: tint, prominent: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Surface.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 10)
        .onAppear { refreshBranch() }
        .onChange(of: session.showTick) { refreshBranch() }
        .onChange(of: session.projectFolder) { refreshBranch() }
    }

    private func refreshBranch() {
        if let folder = session.projectFolder {
            branch = WorkspaceModel.git(["rev-parse", "--abbrev-ref", "HEAD"], in: folder)
        } else {
            branch = ""
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if visibleMessages.isEmpty {
                        Text(emptyHint)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                    ForEach(visibleMessages) { message in
                        bubble(message).id(message.id)
                    }
                    if session.busy, let step = session.steps.last {
                        liveStep(step, count: session.steps.count).id("steps")
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            .onAppear {
                proxy.scrollTo("end", anchor: .bottom)
            }
            .onChange(of: session.showTick) {
                // The panel was just opened: jump to the most recent message.
                Task { @MainActor in proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: session.messages) {
                proxy.scrollTo("end", anchor: .bottom)
            }
            .onChange(of: session.steps) {
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
    }

    /// What the agent is doing right now, in one line.
    private func liveStep(_ step: AgentStep, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: stepIcon(step.state))
                .font(.system(size: 10))
                .foregroundColor(stepColor(step.state))
                .frame(width: 12)
            Text(step.detail.isEmpty ? step.tool : step.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if isCoder && !session.plan.isEmpty {
                Text("\(session.plan.filter { $0.status == "done" }.count) of \(session.plan.count)")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .help(session.plan.first(where: { $0.status == "active" })?.active ?? "")
            } else if count > 1 {
                Text("step \(count)").font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// What the agent has done so far in this task.
    private var stepList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(session.steps) { step in
                HStack(spacing: 6) {
                    Image(systemName: stepIcon(step.state))
                        .font(.system(size: 10))
                        .foregroundColor(stepColor(step.state))
                        .frame(width: 12)
                    Text(step.tool)
                        .font(.system(size: 11, weight: .semibold))
                    Text(step.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func stepIcon(_ state: String) -> String {
        switch state {
        case "done": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "denied": return "xmark.circle.fill"
        default: return "circle.dotted"
        }
    }

    private func stepColor(_ state: String) -> Color {
        switch state {
        case "done": return .green
        case "failed": return .orange
        case "denied": return .red
        default: return .secondary
        }
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(session.attachments, id: \.self) { url in
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                        Text(url.lastPathComponent).lineLimit(1)
                        Button(action: { session.attachments.removeAll(where: { $0 == url }) }) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    /// Shown while the agent is working: something to do while you wait.
    private var playRow: some View {
        Button(action: { session.onPlay?() }) {
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller.fill")
                Text("Play Orange Smash while you wait")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(tint.opacity(0.25))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var quickActions: some View {
        Group {
            if session.sheet.harness != nil {
                ConnectCard(connector: Connector.of(session.engine), name: name, tint: tint)
            }
            if session.busy {
                // Shortcuts are no use mid-task. On a long task, offer the game instead.
                if session.onPlay != nil && session.steps.count >= 2 && session.approval == nil {
                    playRow
                }
            } else if session.approval == nil {
                if isCoder {
                    coderActions
                } else if isWriter {
                    writerActions
                } else if isCoach {
                    coachActions
                } else if isForecaster {
                    forecasterActions
                } else if isGeneralist {
                    generalActions
                }
            }
        }
    }

    private var forecasterActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("Umbrella today?") {
                    session.ask(display: "Do I need an umbrella today?", prompt: "Do I need an umbrella today?")
                }
                chip("What to wear") {
                    session.ask(display: "What should I wear today?", prompt: "What should I wear today?")
                }
                chip("The next 5 days") {
                    session.ask(display: "The next five days", prompt: "Give me the next five days, one short line each, and say which is the best one.")
                }
                chip("This weekend") {
                    session.ask(display: "How's the weekend looking?", prompt: "How does the coming weekend look? If it is beyond your five days, say so.")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
    }

    private var coachActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("20-minute workout") {
                    session.ask(display: "A 20-minute workout, no kit",
                                prompt: "Give me a 20-minute workout I can do right now with no equipment. Check my profile and recent log so it fits. Warm-up, main set, cool-down.")
                }
                chip("Log a session") {
                    session.draft = "Log it: "
                    session.focusTick += 1
                }
                chip("How's my week?") {
                    session.ask(display: "How's my week?",
                                prompt: "How is my week going against the plan? Numbers first, then what to do with the days left.")
                }
                chip("What's today?") {
                    session.ask(display: "What's today's session?",
                                prompt: "What does my plan say for today? If there is no plan, suggest one session that fits my recent log.")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private var writerActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("Tighten my clipboard") {
                    let text = NSPasteboard.general.string(forType: .string) ?? ""
                    session.ask(display: "Tighten what's on my clipboard",
                                prompt: "Tighten this: cut filler and repetition, keep the meaning. Reply with only the text.\n\n" + String(text.prefix(8000)))
                }
                chip("An opening line") {
                    session.draft = "Give me five opening lines for a piece about "
                    session.focusTick += 1
                }
                chip("A better word for…") {
                    session.draft = "Give me better words for: "
                    session.focusTick += 1
                }
                chip("Fix this sentence") {
                    session.draft = "Fix this sentence: "
                    session.focusTick += 1
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private var coderActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("Run the tests") {
                    session.draft = "Run the tests and tell me what failed, if anything."
                    session.send()
                }
                chip("What changed?") {
                    session.draft = "Summarise the uncommitted changes in this repo."
                    session.send()
                }
                chip("Explain this repo") {
                    session.draft = "Give me a short tour of this repo: what it does and where the important code lives."
                    session.send()
                }
                chip("Find loose ends") {
                    session.draft = "Find the TODOs, FIXMEs and obviously unfinished code, most important first."
                    session.send()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    /// The chief of staff's four: the day, the next thing, getting something off your mind, and clearing the screen.
    private var generalActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(Office.of(session.sheet.id).isCurrent ? "Refresh brief" : "Brief me") {
                    session.ask(display: "Brief me", prompt: Office.briefPrompt)
                }
                chip("What's next?") {
                    session.ask(display: "What's next?", prompt: Office.nextPrompt)
                }
                chip("Capture…") {
                    session.draft = "Remember for me: "
                    session.focusTick += 1
                }
                if focus.sweepActive {
                    chip("Bring it all back") { runFocus("Bring it all back") { await FocusKeeper.shared.back() } }
                } else {
                    chip("I'm overwhelmed") { runFocus("I'm overwhelmed") { await FocusKeeper.shared.sweep() } }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .onAppear { focus.reloadState() }
        .onChange(of: session.busy) { focus.reloadState() }
    }

    /// Runs one of Pip's focus tools straight away, no model call, and leaves the result in the chat.
    private func runFocus(_ display: String, _ work: @escaping @MainActor () async -> String) {
        session.messages.append(ChatMessage(role: "user", text: display))
        Task { @MainActor in
            let line = await work()
            session.messages.append(ChatMessage(role: "assistant", text: line))
            session.save()
        }
    }

    @ViewBuilder
    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        if theme.glass {
            Button(title, action: action)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(session.busy)
        } else {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 11))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.18))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(session.busy)
        }
    }

    private var placeholder: String {
        if isCoder { return "Ask \(name) about the code…" }
        if isWriter { return "Ask \(name) about words…" }
        if isCoach { return "Tell \(name) how it went, or ask for a session…" }
        if isForecaster { return "Ask \(name) about the weather…" }
        if isGeneralist { return "Ask \(name), or say what's on your plate…" }
        return "Ask \(name)…"
    }

    @ViewBuilder
    private var inputRow: some View {
        let field = HStack(spacing: 8) {
            TextField(placeholder, text: $session.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($typing)
                .onSubmit { session.send() }
            if session.busy {
                ProgressView().controlSize(.small)
            } else {
                Button(action: {
                    typing = true
                    SpeechOut.dictate()
                }) {
                    Image(systemName: "mic").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Dictate (macOS Dictation)")
                if theme.glass {
                    Button(action: { session.send() }) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(session.draft.isEmpty ? Color.secondary : tint)
                    .disabled(session.draft.isEmpty)
                }
            }
        }
        if theme.glass {
            field
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .frame(minHeight: 34)
                .background(Surface.text.opacity(0.7), in: Capsule())
                .overlay(Capsule().strokeBorder(Surface.separator, lineWidth: 0.5))
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
        } else {
            field
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let mine = message.role == "user"
        return HStack {
            if mine { Spacer(minLength: 40) }
            Group {
                if mine || message.text.isEmpty {
                    Text(message.text.isEmpty ? "…" : message.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                } else {
                    MarkdownView(text: message.text)
                }
            }
            .padding(.horizontal, theme.glass ? 12 : 10)
            .padding(.vertical, 7)
            .foregroundStyle(mine && theme.glass ? Color.white : Color.primary)
            .background(bubbleFill(mine), in: RoundedRectangle(cornerRadius: theme.glass ? 17 : 11, style: .continuous))
            if !mine { Spacer(minLength: 24) }
        }
    }

    /// Messages-style on glass: yours filled with the character's colour, theirs on a solid card.
    private func bubbleFill(_ mine: Bool) -> AnyShapeStyle {
        if theme.glass { return mine ? AnyShapeStyle(tint) : AnyShapeStyle(Surface.card) }
        return mine ? AnyShapeStyle(tint.opacity(0.28)) : AnyShapeStyle(Color.primary.opacity(0.07))
    }
}

/// The popup's surface: Liquid Glass for the native characters, the character's own paper for the rest.
private struct PanelSurface: ViewModifier {
    let theme: RoleTheme
    let tint: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.corner, style: .continuous)
        if let paper = theme.paper {
            content
                .background(paper)
                .clipShape(shape)
                .overlay(shape.stroke(tint.opacity(0.5), lineWidth: 1.5))
        } else {
            content
                .clipShape(shape)
                .glassEffect(.regular.tint(tint.opacity(0.06)), in: shape)
        }
    }
}

/// A borderless panel that can still take typing, without activating the app.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ChatPanelController {
    private let panel: KeyPanel
    private let session: ChatSession

    init(session: ChatSession, sheet: CharacterSheet, shelf: AppShelf) {
        self.session = session
        let rect = NSRect(origin: .zero, size: chatPanelSize)
        panel = KeyPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = ChatView(session: session, shelf: shelf, name: sheet.name,
                            tint: Color(nsColor: NSColor(hex: sheet.look.body)), role: sheet.role ?? "generalist")
        let host = NSHostingView(rootView: view)
        host.frame = rect
        panel.contentView = host
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }
    var frame: NSRect { panel.frame }

    func show() {
        if !panel.isVisible { session.showTick += 1 }
        panel.orderFrontRegardless()
    }

    /// Shows the panel and puts the cursor in the text field, without switching apps.
    func focus() {
        if !panel.isVisible { session.showTick += 1 }
        panel.makeKeyAndOrderFront(nil)
        session.focusTick += 1
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Keeps the panel above the character, or beside it when there is no room.
    func follow(anchor: CGRect, screen: CGRect) {
        let size = chatPanelSize
        var x = anchor.midX - size.width / 2
        var y = anchor.maxY + 12
        if y + size.height > screen.maxY - 30 {
            y = min(anchor.minY, screen.maxY - 30 - size.height)
            x = anchor.maxX + 12
            if x + size.width > screen.maxX - 8 { x = anchor.minX - 12 - size.width }
        }
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        y = max(y, screen.minY + 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// A small bubble for the moments a character speaks first. It never takes clicks.
struct SpeechView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 210)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

@MainActor
final class SpeechBubbleController {
    private let panel: NSPanel
    private let host: NSHostingView<SpeechView>
    private var remaining: CGFloat = 0

    init() {
        let rect = NSRect(x: 0, y: 0, width: 234, height: 40)
        panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host = NSHostingView(rootView: SpeechView(text: ""))
        host.frame = rect
        panel.contentView = host
    }

    var isVisible: Bool { panel.isVisible }

    func say(_ text: String) {
        host.rootView = SpeechView(text: text)
        let size = host.fittingSize
        panel.setContentSize(NSSize(width: max(size.width, 120), height: max(size.height, 30)))
        remaining = min(9, max(3.5, 2.5 + CGFloat(text.count) * 0.06))
        panel.orderFrontRegardless()
    }

    func hide() {
        remaining = 0
        panel.orderOut(nil)
    }

    func tick(dt: CGFloat, anchor: CGRect, screen: CGRect) {
        if !panel.isVisible { return }
        remaining -= dt
        if remaining <= 0 {
            panel.orderOut(nil)
            return
        }
        let size = panel.frame.size
        var x = anchor.midX - size.width / 2
        var y = anchor.maxY + 10
        if y + size.height > screen.maxY - 30 { y = anchor.minY - size.height - 10 }
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        y = max(y, screen.minY + 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}


/// The coach's strip: this week at a glance, and the way into the training room.
struct CoachStrip: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var journal: TrainingJournal
    let tint: Color
    @ObservedObject private var strava = Strava.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill").font(.system(size: 13)).foregroundColor(.orange)
            Text(journal.summary)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
            Spacer()
            stravaButton
            Button(action: { session.onOpenWorkspace?() }) {
                Text("Training room")
                    .font(.system(size: 11, weight: .heavy))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(tint.opacity(0.35))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .onAppear { journal.reload() }
        .onChange(of: session.busy) { journal.reload() }
        .onChange(of: session.showTick) { journal.reload() }
    }

    /// Strava's own orange, so it reads as Strava at a glance. Right-click to disconnect.
    private var stravaButton: some View {
        let orange = Color(red: 0.99, green: 0.30, blue: 0.01)
        return Button(action: {
            if !strava.connected && !strava.connecting { strava.connect(for: session.sheet.id) }
        }) {
            HStack(spacing: 4) {
                Image(systemName: strava.connected ? "checkmark.circle.fill" : "link")
                Text(strava.connected ? "Strava" : (strava.connecting ? "Connecting…" : "Connect Strava"))
            }
            .font(.system(size: 11, weight: .heavy))
            .foregroundColor(strava.connected ? orange : .white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(strava.connected ? orange.opacity(0.15) : orange.opacity(0.85))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(strava.status.isEmpty
              ? (strava.connected ? "Connected as \(strava.athlete). Rally sees your last 60 days." : "Let Rally see your Strava activities")
              : strava.status)
        .contextMenu {
            if strava.connected {
                Button("Disconnect Strava") { strava.disconnect(for: session.sheet.id) }
            }
        }
    }
}
