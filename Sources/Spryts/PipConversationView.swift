import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pip's conversation surface, shared by the main chat and the desk inspector.
/// Engine selection and conversation navigation belong to the containing window.
struct PipConversationView: View {
    @ObservedObject var session: ChatSession
    let name: String
    let tint: Color
    var compact = false

    @FocusState private var typing: Bool
    @State private var showActivity = false
    @State private var followsLatest = true
    @State private var atBottom = true
    @State private var userScrolling = false
    @State private var dropTargeted = false
    @State private var attachmentNotice = ""
    @State private var copiedMessage: UUID?

    private var messages: [ChatMessage] { session.messages.filter { !$0.hidden } }
    private var contentWidth: CGFloat { compact ? .infinity : 760 }
    private var margin: CGFloat { compact ? 14 : 28 }
    private var canSend: Bool {
        !session.busy && (!session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.attachments.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            VStack(spacing: 10) {
                if let approval = session.approval {
                    ApprovalCardView(session: session, approval: approval, name: name)
                }
                if !session.steps.isEmpty { activity }
                composer
            }
            .frame(maxWidth: contentWidth)
            .padding(.horizontal, margin)
            .padding(.top, 8)
            .padding(.bottom, compact ? 12 : 20)
            .frame(maxWidth: .infinity)
        }
        .background(Surface.text)
        .tint(tint)
        .defaultFocus($typing, true)
        .task(id: session.focusTick) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            typing = true
        }
        .onChange(of: session.busy) { if session.busy { showActivity = false } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: receiveDrop)
        .overlay {
            if dropTargeted && !session.busy {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .task(id: copiedMessage) {
            guard copiedMessage != nil else { return }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if !Task.isCancelled { copiedMessage = nil }
        }
    }

    private var transcript: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: compact ? 22 : 30) {
                        if messages.isEmpty {
                            emptyState
                                .frame(maxWidth: .infinity, minHeight: max(geometry.size.height - 48, 180))
                        }
                        ForEach(messages) { message in messageRow(message).id(message.id) }
                        Color.clear.frame(height: 1).id("pip-conversation-end")
                    }
                    .frame(maxWidth: contentWidth)
                    .padding(.horizontal, margin)
                    .padding(.top, compact ? 16 : 28)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 72
                } action: { _, nearBottom in
                    atBottom = nearBottom
                    if userScrolling { followsLatest = nearBottom }
                }
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                    if phase == .idle && atBottom { followsLatest = true }
                }
                .onChange(of: session.messages) {
                    if followsLatest { proxy.scrollTo("pip-conversation-end", anchor: .bottom) }
                }
                .onChange(of: messages.first?.id, initial: true) {
                    followsLatest = true
                    showActivity = false
                    attachmentNotice = ""
                    proxy.scrollTo("pip-conversation-end", anchor: .bottom)
                }
                .overlay(alignment: .bottom) {
                    if !followsLatest && !atBottom && !messages.isEmpty {
                        Button("Latest reply", systemImage: "arrow.down") {
                            followsLatest = true
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("pip-conversation-end", anchor: .bottom)
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .padding(.bottom, 8)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: compact ? .leading : .center, spacing: compact ? 12 : 18) {
            Image(systemName: "sparkles")
                .font(.system(size: compact ? 24 : 34, weight: .light))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(compact ? "What needs your attention?" : "What would you like to get done?")
                .font(.system(size: compact ? 19 : 27, weight: .semibold))
            Text("Ask \(name) to work with your files, help with your day, or bring in the right Spryt.")
                .font(.system(size: compact ? 13 : 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(compact ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 450)
            if !compact {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { starters }
                    VStack(alignment: .leading, spacing: 8) { starters }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, compact ? 16 : 32)
    }

    private var starters: some View {
        Group {
            starter("Plan my day", symbol: "sun.max", prompt: "Help me plan my day and choose the three most important things to focus on.")
            starter("Find a file", symbol: "doc.text.magnifyingglass", prompt: "Help me find a file on my Mac: ")
            starter("Bring in the team", symbol: "person.2", prompt: "Help me break this project into clear tasks and coordinate the right Spryts: ")
        }
    }

    private func starter(_ title: String, symbol: String, prompt: String) -> some View {
        Button {
            if session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                session.draft = prompt
            } else {
                session.draft += "\n\n" + prompt
            }
            typing = true
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
                .padding(.horizontal, 3)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 10))
        .help("Start a request you can edit before sending")
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.role == "user" {
            let content = sentContent(message.text)
            HStack {
                Spacer(minLength: compact ? 24 : 72)
                VStack(alignment: .leading, spacing: 9) {
                    if !content.text.isEmpty {
                        Text(content.text)
                            .font(.system(size: compact ? 13 : 14))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    ForEach(content.files, id: \.self) { file in
                        Label(file.lastPathComponent, systemImage: "doc")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(file.path)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(Surface.card, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(Surface.separator.opacity(0.45), lineWidth: 0.5))
            }
        } else if !message.text.isEmpty || !session.busy || session.steps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if !message.text.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                            copiedMessage = message.id
                        } label: {
                            Image(systemName: copiedMessage == message.id ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(copiedMessage == message.id ? "Copied" : "Copy reply")
                        .accessibilityLabel("Copy reply from \(name)")
                    }
                }
                if message.text.isEmpty {
                    HStack(spacing: 8) {
                        if session.busy { ProgressView().controlSize(.mini) }
                        Text(session.busy ? "Thinking…" : "No reply yet")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                } else {
                    MarkdownView(text: message.text).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// ChatSession stores local attachments as trailing path references. Present
    /// them as filenames while leaving the stored/sent request unchanged.
    private func sentContent(_ text: String) -> (text: String, files: [URL]) {
        var lines = text.components(separatedBy: "\n")
        var files: [URL] = []
        while let last = lines.last, last.hasPrefix("[attached: /"), last.hasSuffix("]") {
            let path = String(last.dropFirst("[attached: ".count).dropLast())
            files.insert(URL(fileURLWithPath: path), at: 0)
            lines.removeLast()
        }
        return (lines.joined(separator: "\n"), files)
    }

    private var activityLabel: String {
        if session.approval != nil { return "Waiting for your approval" }
        if session.busy {
            if let item = session.plan.first(where: { $0.status == "active" }) { return item.active }
            if let step = session.steps.last { return step.detail.isEmpty ? step.tool : step.detail }
            return "\(name) is thinking"
        }
        if session.steps.contains(where: { $0.state == "failed" }) { return "Activity includes a failed step" }
        if session.steps.contains(where: { $0.state == "denied" }) { return "Activity includes a stopped or declined step" }
        return "\(session.steps.count) completed step\(session.steps.count == 1 ? "" : "s")"
    }

    private var activity: some View {
        DisclosureGroup(isExpanded: $showActivity) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.steps) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: step.state == "done" ? "checkmark.circle" : step.state == "running" ? "circle.dotted" : "exclamationmark.circle")
                                .foregroundStyle(step.state == "failed" ? Color.orange : Color.secondary)
                            Text(step.detail.isEmpty ? step.tool : step.detail)
                                .textSelection(.enabled)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 11))
                    }
                    if session.steps.isEmpty {
                        Text("Steps appear here as \(name) works.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            .frame(maxHeight: compact ? 110 : 160)
        } label: {
            HStack(spacing: 8) {
                if session.busy { ProgressView().controlSize(.mini) }
                Text(activityLabel).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 3)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !session.attachments.isEmpty { attachments }
            ZStack(alignment: .topLeading) {
                if session.draft.isEmpty {
                    Text(session.busy ? "Draft your next request…" : "Ask \(name) anything…")
                        .font(.system(size: compact ? 13 : 14))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5).padding(.top, 7)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $session.draft)
                    .font(.system(size: compact ? 13 : 14))
                    .scrollContentBackground(.hidden)
                    .focused($typing)
                    .accessibilityLabel("Message to \(name)")
            }
            .frame(height: composerHeight)
            if !attachmentNotice.isEmpty {
                Text(attachmentNotice).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(action: chooseFiles) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(session.busy || session.attachments.count >= 8)
                    .help("Attach files from your Mac")
                    .accessibilityLabel("Attach files")
                Button {
                    typing = true
                    SpeechOut.dictate()
                } label: { Image(systemName: "mic") }
                    .buttonStyle(.borderless)
                    .help("Use macOS Dictation")
                    .accessibilityLabel("Dictate message")
                if let folder = session.projectFolder {
                    Label(folder.lastPathComponent, systemImage: "folder")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(folder.path)
                }
                Spacer(minLength: 8)
                if session.busy {
                    Button("Stop", systemImage: "stop.fill") { session.stop() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    if !compact {
                        Text("⌘Return").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.regular)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send to \(name) (⌘Return)")
                    .accessibilityLabel("Send to \(name)")
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(typing ? tint.opacity(0.5) : Surface.separator.opacity(0.6), lineWidth: typing ? 1 : 0.5))
    }

    private var composerHeight: CGFloat {
        let columns = compact ? 40 : 85
        let lines = session.draft.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + columns - 1) / columns) }
        return CGFloat(min(max(lines, compact ? 2 : 3), 6)) * 19 + 8
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.attachments, id: \.self) { url in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 18, height: 18)
                        Text(url.lastPathComponent).lineLimit(1).frame(maxWidth: 150)
                        Button {
                            session.attachments.removeAll { $0 == url }
                            attachmentNotice = ""
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(url.lastPathComponent)")
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(Surface.text, in: RoundedRectangle(cornerRadius: 10))
                    .help(url.path)
                }
            }
        }
    }

    private func send() {
        guard canSend else { return }
        followsLatest = true
        attachmentNotice = ""
        session.send()
        typing = true
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = "Choose files for \(name) to read in your next request."
        if panel.runModal() == .OK { for url in panel.urls { attach(url) } }
    }

    private func attach(_ url: URL) {
        guard url.isFileURL, !session.busy else { return }
        let file = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            attachmentNotice = "Choose individual files to attach."
            return
        }
        if session.attachments.count >= 8 && !session.attachments.contains(file) {
            attachmentNotice = "Attach up to 8 files at a time."
            return
        }
        session.attach(file)
        typing = true
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !session.busy else { return false }
        let conversationID = session.pipLibrary?.activeConversationID
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    guard session.pipLibrary?.activeConversationID == conversationID else { return }
                    attach(url)
                }
            }
        }
        return accepted
    }
}
