import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Markdown

/// One block of a reply: a paragraph, a heading, a list, or a fenced code block.
struct MDBlock: Identifiable {
    let id: Int
    let kind: Int        // 0 paragraph, 1 heading, 2 list, 3 code
    let text: String
    let lang: String
    let items: [String]
}

enum Markdown {
    static func parse(_ source: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        var items: [String] = []
        var code: [String] = []
        var lang = ""
        var inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(MDBlock(id: blocks.count, kind: 0, text: paragraph.joined(separator: "\n"), lang: "", items: []))
                paragraph = []
            }
        }
        func flushItems() {
            if !items.isEmpty {
                blocks.append(MDBlock(id: blocks.count, kind: 2, text: "", lang: "", items: items))
                items = []
            }
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(MDBlock(id: blocks.count, kind: 3, text: code.joined(separator: "\n"), lang: lang, items: []))
                    code = []
                    inCode = false
                } else {
                    flushParagraph()
                    flushItems()
                    lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode {
                code.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                flushItems()
                continue
            }
            if trimmed.hasPrefix("#") {
                flushParagraph()
                flushItems()
                let title = trimmed.drop(while: { $0 == "#" || $0 == " " })
                blocks.append(MDBlock(id: blocks.count, kind: 1, text: String(title), lang: "", items: []))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                items.append(String(trimmed.dropFirst(2)))
                continue
            }
            if let dot = trimmed.firstIndex(of: "."), trimmed[trimmed.startIndex..<dot].allSatisfy({ $0.isNumber }),
               trimmed.startIndex != dot, trimmed.index(after: dot) < trimmed.endIndex,
               trimmed[trimmed.index(after: dot)] == " " {
                flushParagraph()
                items.append(String(trimmed[trimmed.index(dot, offsetBy: 2)...]))
                continue
            }
            flushItems()
            paragraph.append(line)
        }
        if inCode {
            blocks.append(MDBlock(id: blocks.count, kind: 3, text: code.joined(separator: "\n"), lang: lang, items: []))
        }
        flushParagraph()
        flushItems()
        return blocks
    }

    /// Bold, italics, inline code and links inside a line of text.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Colours code for reading: comments, strings, numbers and common keywords. Diffs are coloured by line.
enum Highlighter {
    static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "class", "struct", "enum", "protocol",
        "extension", "switch", "case", "default", "break", "continue", "guard", "in", "do", "try", "catch", "throw",
        "throws", "async", "await", "static", "private", "public", "internal", "self", "nil", "true", "false",
        "def", "from", "as", "with", "lambda", "None", "True", "False", "elif", "except", "finally", "pass", "yield",
        "function", "const", "new", "this", "typeof", "export", "interface", "type", "null", "undefined", "void",
        "fn", "mut", "impl", "trait", "use", "pub", "match", "package", "go", "defer", "chan", "map", "range"
    ]
    nonisolated(unsafe) static let word = try? Regex("[A-Za-z_][A-Za-z0-9_]*")
    nonisolated(unsafe) static let number = try? Regex("\\b[0-9][0-9_.]*\\b")
    nonisolated(unsafe) static let string = try? Regex("\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'")

    static let base = Color(white: 0.88)
    static let comment = Color(white: 0.55)
    static let keyword = Color(red: 0.98, green: 0.55, blue: 0.67)
    static let literal = Color(red: 0.62, green: 0.85, blue: 0.55)
    static let numeric = Color(red: 0.95, green: 0.76, blue: 0.45)
    static let added = Color(red: 0.55, green: 0.88, blue: 0.58)
    static let removed = Color(red: 0.98, green: 0.52, blue: 0.5)
    static let hunk = Color(red: 0.55, green: 0.75, blue: 0.98)

    static func color(_ code: String, lang: String, limit: Int) -> AttributedString {
        var out = AttributedString()
        let diff = lang == "diff" || lang == "patch"
        var count = 0
        for rawLine in code.split(separator: "\n", omittingEmptySubsequences: false) {
            if count >= limit {
                var more = AttributedString("… (truncated)\n")
                more.swiftUI.foregroundColor = comment
                out.append(more)
                break
            }
            count += 1
            let line = String(rawLine)
            var piece = AttributedString(line)
            piece.swiftUI.foregroundColor = base
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if diff {
                if line.hasPrefix("+") {
                    piece.swiftUI.foregroundColor = added
                } else if line.hasPrefix("-") {
                    piece.swiftUI.foregroundColor = removed
                } else if line.hasPrefix("@@") {
                    piece.swiftUI.foregroundColor = hunk
                }
            } else if trimmed.hasPrefix("//") || trimmed.hasPrefix("# ") || trimmed.hasPrefix("#!") || trimmed.hasPrefix("--") {
                piece.swiftUI.foregroundColor = comment
            } else if line.count < 400 {
                if let word {
                    for range in line.ranges(of: word) where keywords.contains(String(line[range])) {
                        if let r = Range(range, in: piece) { piece[r].swiftUI.foregroundColor = keyword }
                    }
                }
                if let number {
                    for range in line.ranges(of: number) {
                        if let r = Range(range, in: piece) { piece[r].swiftUI.foregroundColor = numeric }
                    }
                }
                if let string {
                    for range in line.ranges(of: string) {
                        if let r = Range(range, in: piece) { piece[r].swiftUI.foregroundColor = literal }
                    }
                }
            }
            out.append(piece)
            out.append(AttributedString("\n"))
        }
        return out
    }

    /// Lines removed and added by an edit, as a diff.
    static func diff(before: String, after: String) -> String {
        var lines: [String] = []
        for line in before.split(separator: "\n", omittingEmptySubsequences: false) where !before.isEmpty {
            lines.append("- " + String(line))
        }
        for line in after.split(separator: "\n", omittingEmptySubsequences: false) where !after.isEmpty {
            lines.append("+ " + String(line))
        }
        return lines.joined(separator: "\n")
    }
}

struct CodeBlockView: View {
    let code: String
    let lang: String
    var limit = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(white: 0.17))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(Highlighter.color(code, lang: lang, limit: limit))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct MarkdownBlockView: View {
    let block: MDBlock

    var body: some View {
        switch block.kind {
        case 1:
            Text(Markdown.inline(block.text))
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 2)
        case 2:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(block.items.enumerated()), id: \.offset) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundColor(.secondary)
                        Text(Markdown.inline(item.element))
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case 3:
            CodeBlockView(code: block.text, lang: block.lang)
        default:
            Text(Markdown.inline(block.text))
                .font(.system(size: 13))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Markdown.parse(text)) { block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Files

final class FileNode: Identifiable {
    let id = UUID()
    let url: URL
    let isFolder: Bool
    var children: [FileNode]?

    init(url: URL, isFolder: Bool, children: [FileNode]?) {
        self.url = url
        self.isFolder = isFolder
        self.children = children
    }
}

/// What the right-hand side of the workspace is showing.
final class WorkspaceModel: ObservableObject {
    @Published var tree: [FileNode] = []
    @Published var selected: URL?
    @Published var fileText = ""
    @Published var branch = ""
    @Published var conversations: [Conversation] = []
    @Published var tab = 0
    @Published var follow = true
    private var budget = 0
    private static let skipped: Set<String> = [
        "node_modules", "build", "dist", "DerivedData", "Pods", "target", "venv", "__pycache__", "vendor"
    ]

    func reload(folder: URL?) {
        guard let folder else {
            tree = []
            branch = ""
            conversations = []
            return
        }
        budget = 1500
        tree = children(of: folder, depth: 0)
        refresh(folder: folder)
    }

    /// The cheap things that change after every run.
    func refresh(folder: URL?) {
        guard let folder else { return }
        branch = WorkspaceModel.git(["rev-parse", "--abbrev-ref", "HEAD"], in: folder)
        conversations = Harness.conversations(for: folder)
        if let selected { open(selected) }
    }

    private func children(of folder: URL, depth: Int) -> [FileNode] {
        let fm = FileManager.default
        guard depth < 6, budget > 0,
              let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var nodes: [FileNode] = []
        for url in urls {
            if budget <= 0 { break }
            let name = url.lastPathComponent
            if WorkspaceModel.skipped.contains(name) { continue }
            budget -= 1
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            nodes.append(FileNode(url: url, isFolder: isFolder, children: isFolder ? children(of: url, depth: depth + 1) : nil))
        }
        nodes.sort(by: { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.url.lastPathComponent.localizedCaseInsensitiveCompare(b.url.lastPathComponent) == .orderedAscending
        })
        return nodes
    }

    func open(_ url: URL) {
        selected = url
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        if size > 600_000 {
            fileText = "(This file is too large to show here.)"
        } else if let text = try? String(contentsOf: url, encoding: .utf8) {
            fileText = text
        } else {
            fileText = "(This file isn't text.)"
        }
    }

    static func git(_ arguments: [String], in folder: URL) -> String {
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        run.arguments = ["-C", folder.path] + arguments
        let pipe = Pipe()
        run.standardOutput = pipe
        run.standardError = FileHandle.nullDevice
        run.standardInput = FileHandle.nullDevice
        do {
            try run.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            run.waitUntilExit()
            return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }
}

// MARK: - The workspace window

struct WorkspaceView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var model: WorkspaceModel
    let name: String
    let tint: Color
    let role: String
    @FocusState private var typing: Bool

    private var visibleMessages: [ChatMessage] {
        session.messages.filter { !$0.hidden }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                conversationPane
                    .frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                workPane
                    .frame(minWidth: 360, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .background(Color(red: 0.09, green: 0.09, blue: 0.13))
        .environment(\.colorScheme, .dark)
        .onChange(of: session.touchedFile) {
            if model.follow, let url = session.touchedFile { model.open(url) }
        }
        .onChange(of: session.editCount) {
            if model.follow, let url = session.touchedFile { model.open(url) }
        }
        .onChange(of: session.busy) {
            if !session.busy { model.refresh(folder: session.projectFolder) }
        }
        .onChange(of: session.projectFolder) {
            model.reload(folder: session.projectFolder)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        var isFolder: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                            session.assign(folder: url)
                        } else {
                            session.attach(url)
                        }
                    }
                }
            }
            return true
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 11, height: 11)
            Text(name).font(.system(size: 14, weight: .semibold))
            Text(role.isEmpty ? session.providerLabel : role.capitalized + " · " + session.providerLabel)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Menu {
                ForEach(session.modelChoices, id: \.id) { choice in
                    Button(action: { session.model = choice.id }) {
                        if choice.id == session.model {
                            Label(choice.label, systemImage: "checkmark")
                        } else {
                            Text(choice.label)
                        }
                    }
                }
            } label: {
                Label(session.modelLabel, systemImage: "cpu")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(session.busy || session.modelChoices.count < 2)
            .help("Model: " + session.model + ". Applies from the next message.")
            Button(action: chooseFolder) {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(session.projectFolder?.lastPathComponent ?? "Choose a folder…")
                }
                .font(.system(size: 12))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.08))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(session.projectFolder?.path ?? "Everything this character creates goes in the folder you choose")
            if !model.branch.isEmpty {
                Label(model.branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if !session.lastTest.isEmpty {
                Text(session.lastTest)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((session.lastTest.hasPrefix("passed") ? Color.green : Color.red).opacity(0.2))
                    .clipShape(Capsule())
            }
            Spacer()
            Menu {
                ForEach(model.conversations) { conversation in
                    Button(conversation.title) { session.resume(conversation) }
                }
                if !model.conversations.isEmpty { Divider() }
                Button("New conversation") { session.newConversation() }
            } label: {
                Label("Conversations", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(session.busy)
            if session.busy {
                Button(action: { session.stop() }) {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Stop")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Assign"
        if panel.runModal() == .OK, let url = panel.url {
            session.assign(folder: url)
        }
    }

    // MARK: Conversation

    private var conversationPane: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if visibleMessages.isEmpty {
                            Text(session.projectFolder == nil
                                 ? "Choose a folder, then tell \(name) what to build."
                                 : "Tell \(name) what to do in \(session.projectFolder?.lastPathComponent ?? "this folder").")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        }
                        ForEach(visibleMessages) { message in
                            messageView(message).id(message.id)
                        }
                        if !session.steps.isEmpty {
                            stepSummary
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: session.messages) {
                    proxy.scrollTo("end", anchor: .bottom)
                }
                .onChange(of: session.steps) {
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            if let approval = session.approval {
                ApprovalCardView(session: session, approval: approval, name: name)
            }
            Divider()
            if !session.attachments.isEmpty {
                attachmentRow
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: chooseAttachments) {
                    Image(systemName: "paperclip").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Attach files")
                .disabled(session.busy)
                TextField("Tell \(name) what to do…", text: $session.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($typing)
                    .onSubmit { session.send() }
                if session.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: { session.send() }) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(tint)
                }
            }
            .padding(12)
        }
        .onAppear { typing = true }
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
                    .help(url.path)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 10)
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        if panel.runModal() == .OK {
            for url in panel.urls { session.attach(url) }
        }
    }

    private func messageView(_ message: ChatMessage) -> some View {
        Group {
            if message.role == "user" {
                HStack {
                    Spacer(minLength: 60)
                    Text(message.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(tint.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
            } else {
                MarkdownView(text: message.text.isEmpty ? "…" : message.text)
            }
        }
    }

    /// A compact list of what the agent has done in this task.
    private var stepSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(session.steps) { step in
                HStack(spacing: 6) {
                    Image(systemName: icon(for: step.state))
                        .font(.system(size: 10))
                        .foregroundColor(color(for: step.state))
                        .frame(width: 12)
                    Text(step.tool).font(.system(size: 11, weight: .semibold))
                    Text(step.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func icon(for state: String) -> String {
        switch state {
        case "done": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "denied": return "xmark.circle.fill"
        default: return "circle.dotted"
        }
    }

    private func color(for state: String) -> Color {
        switch state {
        case "done": return .green
        case "failed": return .orange
        case "denied": return .red
        default: return .secondary
        }
    }

    // MARK: Work

    private var workPane: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                Text("Files").tag(0)
                Text("Changes").tag(1)
                Text("Run").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            if model.tab == 0 {
                filesTab
            } else if model.tab == 1 {
                changesTab
            } else {
                runTab
            }
        }
    }

    private var filesTab: some View {
        VSplitView {
            Group {
                if model.tree.isEmpty {
                    Text(session.projectFolder == nil ? "No folder assigned yet." : "This folder is empty.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        OutlineGroup(model.tree, children: \.children) { node in
                            HStack(spacing: 6) {
                                Image(systemName: node.isFolder ? "folder" : "doc.text")
                                    .foregroundColor(node.isFolder ? .secondary : tint)
                                    .font(.system(size: 11))
                                Text(node.url.lastPathComponent)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if !node.isFolder { model.open(node.url) }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minHeight: 120, idealHeight: 220)
            fileViewer
                .frame(minHeight: 160, maxHeight: .infinity)
        }
    }

    private var fileViewer: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.selected?.lastPathComponent ?? "No file open")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(white: 0.75))
                    .lineLimit(1)
                Spacer()
                Toggle("Follow \(name)", isOn: $model.follow)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(white: 0.17))
            ScrollView([.vertical, .horizontal]) {
                Text(Highlighter.color(model.fileText, lang: model.selected?.pathExtension ?? "", limit: 1500))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(white: 0.11))
    }

    /// Every edit the agent made in this task, as a diff.
    private var changesTab: some View {
        let edits = session.steps.filter { $0.kind == "edit" }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if edits.isEmpty {
                    Text("Edits made in this task will appear here.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
                ForEach(edits) { step in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: icon(for: step.state)).foregroundColor(color(for: step.state)).font(.system(size: 10))
                            Text(URL(fileURLWithPath: step.path).lastPathComponent)
                                .font(.system(size: 12, weight: .semibold))
                            Text(step.tool).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        CodeBlockView(code: Highlighter.diff(before: step.before, after: step.after), lang: "diff", limit: 200)
                    }
                }
            }
            .padding(12)
        }
    }

    /// Commands and their output, as they happen.
    private var runTab: some View {
        let runs = session.steps.filter { $0.kind == "run" || $0.kind == "build" || $0.kind == "test" }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if runs.isEmpty {
                        Text("Commands will appear here as they run.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(white: 0.55))
                            .padding(.top, 30)
                    }
                    ForEach(runs) { step in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("$ " + step.detail)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(step.state == "failed" ? Highlighter.removed : Highlighter.added)
                                .textSelection(.enabled)
                            Text(step.state == "running" ? "running…" : (step.output.isEmpty ? "(no output)" : step.output))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(white: 0.82))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Color.clear.frame(height: 1).id("runEnd")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.steps) {
                proxy.scrollTo("runEnd", anchor: .bottom)
            }
        }
        .background(Color(white: 0.09))
    }
}

/// The yes-or-no card for a risky action. Shared by the bubble and the workspace.
struct ApprovalCardView: View {
    @ObservedObject var session: ChatSession
    let approval: Approval
    let name: String

    var body: some View {
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
                    .lineLimit(6)
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
}

/// Owns one character's workspace window.
@MainActor
final class WorkspaceWindowController: NSObject, NSWindowDelegate, Expansion {
    let window: NSWindow
    let model = WorkspaceModel()
    private let session: ChatSession

    init(session: ChatSession, sheet: CharacterSheet) {
        self.session = session
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = sheet.name + " IDE"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.13, alpha: 1)
        let view = WorkspaceView(session: session, model: model, name: sheet.name,
                                 tint: Color(nsColor: NSColor(hex: sheet.look.body)), role: sheet.role ?? "")
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        model.reload(folder: session.projectFolder)
    }

    var isOpen: Bool { window.isVisible && !window.isMiniaturized }
    var isKey: Bool { window.isKeyWindow }
    var number: Int { window.windowNumber }
    var tethers: Bool { true }

    func close() {
        window.orderOut(nil)
    }

    /// Opens the window, leaving room above it for the character to stand on its title bar.
    func show() {
        if !window.isVisible, let screen = NSScreen.screens.first {
            let area = screen.visibleFrame
            let width = min(1120, area.width - 80)
            let height = min(700, area.height - 220)
            let frame = NSRect(x: area.midX - width / 2, y: area.minY + 40, width: width, height: height)
            window.setFrame(frame, display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
