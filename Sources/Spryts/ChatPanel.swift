import AppKit
import SwiftUI
import UniformTypeIdentifiers

let chatPanelSize = CGSize(width: 384, height: 548)

/// The command panel: apps, what the agent is doing, approvals, and the conversation.
struct ChatView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var shelf: AppShelf
    let name: String
    let tint: Color
    @ObservedObject private var connector = Connector.shared
    let role: String
    @FocusState private var typing: Bool
    @State private var branch = ""
    @Environment(\.colorScheme) private var systemScheme

    private var visibleMessages: [ChatMessage] {
        session.messages.filter { !$0.hidden }
    }

    private var isCoder: Bool { role == "coder" }
    private var isWriter: Bool { role == "writer" }

    private var emptyHint: String {
        if isCoder { return "\(name) is the programmer. Click to open the IDE, or ask a quick question about the code here." }
        if isWriter { return "\(name) is the writer. Click to open the studio, or ask for a word, a line or a fix here." }
        return "Ask \(name) to do something on this Mac. Click to open the desk with all your apps."
    }
    private var theme: RoleTheme { RoleTheme.of(role) }

    @ViewBuilder
    private var panelBackground: some View {
        if let paper = theme.paper {
            paper
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            roleStrip
            Divider()
            transcript
            if let approval = session.approval {
                approvalCard(approval)
            }
            Divider()
            if !session.attachments.isEmpty {
                attachmentRow
            }
            quickActions
            inputRow
        }
        .frame(width: chatPanelSize.width, height: chatPanelSize.height)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.corner, style: .continuous).stroke(tint.opacity(0.5), lineWidth: 1.5))
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
    }

    // MARK: Pieces

    /// One line of context: what is being worked on now, or what was asked last.
    private var contextLine: String? {
        guard let last = visibleMessages.last(where: { $0.role == "user" }) else { return nil }
        var ask = last.text.split(separator: "\n").first.map(String.init) ?? ""
        if ask.count > 70 { ask = String(ask.prefix(70)) + "…" }
        if ask.isEmpty { return nil }
        if session.approval != nil { return "Waiting for your OK: " + ask }
        return (session.busy ? "Working on: " : "Last asked: ") + ask
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

    private var headerRow: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 10, height: 10)
            Text(name).font(.system(size: 13, weight: .semibold))
            Text(session.providerLabel + " · " + session.modelLabel).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            if session.busy {
                Button(action: { session.stop() }) {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Stop")
            }
            if session.onPlay != nil {
                Button(action: { session.onPlay?() }) {
                    Image(systemName: "gamecontroller.fill")
                }
                .buttonStyle(.plain)
                .help("Play Orange Smash")
            }
            if session.onOpenWorkspace != nil {
                Button(action: { session.onOpenWorkspace?() }) {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.plain)
                .help("Open the workspace")
            }
            Button(action: { session.pinned.toggle() }) {
                Image(systemName: session.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.plain)
            .help(session.pinned ? "Unpin" : "Keep open")
        }
    }

    /// The strip under the header is where each role differs: apps for the generalist, the project for the programmer.
    private var roleStrip: some View {
        Group {
            if isCoder {
                projectStrip
            } else if isWriter {
                writerStrip
            } else {
                appStrip
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
            Button(action: { session.onOpenWorkspace?() }) {
                Text("Open workspace")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(tint.opacity(0.3))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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

    /// Open apps, most recently used first, then apps that were recently quit.
    private var appStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(shelf.running) { app in
                    appButton(app)
                }
                if !shelf.recent.isEmpty {
                    Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 26)
                    ForEach(shelf.recent) { app in
                        appButton(app).opacity(0.5)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func appButton(_ app: AppItem) -> some View {
        Button(action: { shelf.open(app) }) {
            VStack(spacing: 2) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 30, height: 30)
                Circle()
                    .fill(app.front ? tint : Color.clear)
                    .frame(width: 4, height: 4)
            }
        }
        .buttonStyle(.plain)
        .help(app.running ? app.name : app.name + " (recently quit)")
        .contextMenu {
            Button("Ask \(name) about \(app.name)") {
                session.draft = "In \(app.name): "
                session.focusTick += 1
            }
            if app.running {
                Button("Hide") { shelf.hide(app) }
                Button("Quit") { shelf.quit(app) }
            } else {
                Button("Open") { shelf.open(app) }
            }
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
                    if !session.steps.isEmpty {
                        stepList.id("steps")
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

    private func approvalCard(_ approval: Approval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: approval.danger ? "exclamationmark.shield.fill" : "hand.raised.fill")
                    .foregroundColor(approval.danger ? .red : .orange)
                Text("\(name) wants to use \(approval.tool)")
                    .font(.system(size: 12, weight: .semibold))
            }
            if !approval.detail.isEmpty {
                Text(approval.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(7)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            HStack(spacing: 8) {
                Button("Deny") { session.decide(allow: false, forTask: false) }
                Spacer()
                if !approval.danger {
                    Button("Allow for this task") { session.decide(allow: true, forTask: true) }
                }
                Button("Allow once") { session.decide(allow: true, forTask: false) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background((approval.danger ? Color.red : Color.orange).opacity(0.12))
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
            if session.sheet.harness == "claude-code" && connector.needsConnecting {
                ConnectCard(name: name, tint: tint)
            }
            if session.busy && session.onPlay != nil {
                playRow
            }
            if isCoder {
                coderActions
            } else if isWriter {
                writerActions
            } else {
                generalActions
            }
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

    private var generalActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("What's on my screen?") {
                    session.draft = "Take a screenshot and tell me what's on my screen."
                    session.send()
                }
                chip("Use clipboard") {
                    let text = NSPasteboard.general.string(forType: .string) ?? ""
                    session.draft = "Here is what's on my clipboard:\n" + String(text.prefix(4000)) + "\n\n"
                    session.focusTick += 1
                }
                chip("Tidy windows") {
                    session.draft = "Arrange my open windows neatly so I can see the ones I'm using."
                    session.send()
                }
                chip("What can you do?") {
                    session.draft = "What can you do on this Mac? Give me five concrete examples."
                    session.send()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
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

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField(isCoder ? "Ask \(name) about the code…" : (isWriter ? "Ask \(name) about words…" : "Ask \(name) or give a command…"), text: $session.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($typing)
                .onSubmit { session.send() }
            if session.busy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let mine = message.role == "user"
        return HStack {
            if mine { Spacer(minLength: 40) }
            Text(message.text.isEmpty ? "…" : message.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(mine ? tint.opacity(0.28) : Color.primary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            if !mine { Spacer(minLength: 40) }
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
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 1))
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
