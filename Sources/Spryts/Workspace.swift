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

    static let base = Color(nsColor: CodePalette.text)
    static let comment = Color(nsColor: CodePalette.comment)
    static let keyword = Color(nsColor: CodePalette.keyword)
    static let literal = Color(nsColor: CodePalette.string)
    static let numeric = Color(nsColor: CodePalette.number)
    static let added = Color(nsColor: CodePalette.added)
    static let removed = Color(nsColor: CodePalette.removed)
    static let hunk = Color(nsColor: CodePalette.hunk)

    static func color(_ code: String, lang: String, limit: Int) -> AttributedString {
        var out = AttributedString()
        let diff = lang == "diff" || lang == "patch"
        var count = 0
        for rawLine in code.split(separator: "\n", omittingEmptySubsequences: false) {
            if count >= limit {
                var more = AttributedString("\n… (truncated)")
                more.swiftUI.foregroundColor = comment
                out.append(more)
                break
            }
            if count > 0 { out.append(AttributedString("\n")) }
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
                Text(lang.isEmpty ? "Code" : lang.capitalized)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Surface.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(Highlighter.color(code, lang: lang, limit: limit))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Surface.text)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Surface.separator, lineWidth: 0.5))
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
    var id: URL { url }
    let url: URL
    let isFolder: Bool
    var children: [FileNode]?

    init(url: URL, isFolder: Bool, children: [FileNode]?) {
        self.url = url
        self.isFolder = isFolder
        self.children = children
    }
}

/// The project and editor, including unsaved work in files that are not currently visible.
final class WorkspaceModel: ObservableObject {
    @Published var tree: [FileNode] = []
    @Published var selected: URL?
    @Published var fileText = ""
    @Published var branch = ""
    @Published var conversations: [Conversation] = []
    @Published var tab = 0
    @Published var follow = true
    @Published var saved = ""          // the open file as it is on disk
    @Published var stale = false       // the agent changed the file while it had unsaved edits here
    @Published var editable = false    // false for files too large or not text, which are never written back
    @Published var saveError: String?
    @Published var files: [String] = [] // every file in the tree, relative to the project, for @-mentions
    private(set) var root: URL?
    private var budget = 0
    private struct Draft {
        let text: String
        let saved: String
    }
    private var drafts: [URL: Draft] = [:]

    var dirty: Bool { selected != nil && fileText != saved }
    var dirtyCount: Int {
        drafts.keys.filter { $0 != selected }.count + (dirty ? 1 : 0)
    }

    @discardableResult
    func save(overwrite: Bool = false) -> Bool {
        guard let url = selected, dirty, editable else { return true }
        guard overwrite || (try? String(contentsOf: url, encoding: .utf8)) == saved else {
            stale = true
            saveError = "\(url.lastPathComponent) changed on disk. Review the file conflict before saving."
            return false
        }
        do {
            try fileText.write(to: url, atomically: true, encoding: .utf8)
            saved = fileText
            drafts[url] = nil
            stale = false
            saveError = nil
            return true
        } catch {
            saveError = "Couldn’t save \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    /// Stops on a conflict or failed write, showing the affected file without losing other drafts.
    @discardableResult
    func saveAll() -> Bool {
        rememberDraft()
        let original = selected
        for url in drafts.keys.sorted(by: { $0.path < $1.path }) {
            open(url)
            if !save() { return false }
        }
        if let original { open(original) }
        return true
    }

    func discardAll() {
        drafts = [:]
        saveError = nil
        if let selected { load(selected) }
    }

    func hasDraft(_ url: URL) -> Bool { url == selected ? dirty : drafts[url] != nil }

    private func rememberDraft() {
        guard let selected else { return }
        drafts[selected] = dirty && editable ? Draft(text: fileText, saved: saved) : nil
    }

    /// Opens the file again from disk, dropping any unsaved edits here.
    func revert() {
        if let selected { drafts[selected] = nil }
        saveError = nil
        stale = false
        if let url = selected { load(url) }
    }

    private func flatten(_ nodes: [FileNode], into out: inout [String], base: String) {
        for node in nodes {
            if node.isFolder {
                flatten(node.children ?? [], into: &out, base: base)
            } else {
                let path = node.url.path
                out.append(path.hasPrefix(base) ? String(path.dropFirst(base.count)) : node.url.lastPathComponent)
            }
        }
    }
    private static let skipped: Set<String> = [
        "node_modules", "build", "dist", "DerivedData", "Pods", "target", "venv", "__pycache__", "vendor"
    ]

    func reload(folder: URL?) {
        if root != folder {
            rememberDraft()
            selected = nil
            fileText = ""
            saved = ""
            editable = false
            stale = false
        }
        guard let folder else {
            tree = []
            files = []
            root = nil
            branch = ""
            conversations = []
            return
        }
        budget = 1500
        root = folder
        tree = children(of: folder, depth: 0)
        var all: [String] = []
        flatten(tree, into: &all, base: folder.standardizedFileURL.path + "/")
        files = all
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

    /// Shows a file. The same file with unsaved edits is left alone and flagged instead of overwritten.
    func open(_ url: URL) {
        if url == selected && dirty {
            stale = (try? String(contentsOf: url, encoding: .utf8)) != saved
            return
        }
        rememberDraft()
        if let draft = drafts[url] {
            selected = url
            fileText = draft.text
            saved = draft.saved
            editable = true
            stale = (try? String(contentsOf: url, encoding: .utf8)) != draft.saved
            return
        }
        load(url)
    }

    private func load(_ url: URL) {
        selected = url
        stale = false
        defer { saved = fileText }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        editable = false
        if size > 600_000 {
            fileText = "(This file is too large to show here.)"
        } else if let text = try? String(contentsOf: url, encoding: .utf8) {
            fileText = text
            editable = true
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
    @StateObject private var shell = ShellRunner()
    @StateObject private var selection = CodeSelection()
    @AppStorage("NovaShowNavigator") private var showNavigator = true
    @AppStorage("NovaShowAssistant") private var showAssistant = true
    @State private var quickOpen = false
    @State private var confirmReload = false

    private var visibleMessages: [ChatMessage] {
        session.messages.filter { !$0.hidden }
    }

    private var mentionMatches: [String] {
        guard let query = Mentions.query(session.draft) else { return [] }
        return Mentions.matches(query, in: model.files)
    }

    /// Puts a question in the input, ready to finish and send.
    private func draft(_ text: String) {
        session.prefillDraft(text)
        showAssistant = true
        typing = true
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                if showNavigator {
                    navigator
                        .frame(minWidth: 150, idealWidth: 190, maxWidth: 280, maxHeight: .infinity)
                }
                workPane
                    .frame(minWidth: 340, idealWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
                if showAssistant {
                    conversationPane
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 600, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(tint)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $quickOpen) {
            QuickOpenView(files: model.files) { path in
                guard let root = session.projectFolder else { return }
                openFile(root.appendingPathComponent(path))
            }
        }
        .alert("Couldn’t Save", isPresented: Binding(get: { model.saveError != nil }, set: { if !$0 { model.saveError = nil } })) {
            Button("OK", role: .cancel) { model.saveError = nil }
        } message: {
            Text(model.saveError ?? "")
        }
        .alert("Reload \(model.selected?.lastPathComponent ?? "file") from disk?", isPresented: $confirmReload) {
            Button("Reload", role: .destructive) { model.revert() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your unsaved edits to this file will be discarded.")
        }
        .onChange(of: session.touchedFile) {
            if model.follow, let url = session.touchedFile { model.open(url) }
        }
        .onChange(of: session.editCount) {
            if model.follow, let url = session.touchedFile { model.open(url) }
        }
        .onChange(of: session.busy) {
            if !session.busy { model.reload(folder: session.projectFolder) }
        }
        .onChange(of: session.approval?.id) {
            if session.approval != nil { showAssistant = true }
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

    /// The toolbar, in the style of Xcode: who and where on the left, the activity in the middle, controls in glass on the right.
    /// The window's traffic lights sit in the space on the left.
    private var topBar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectFolder?.lastPathComponent ?? name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if !model.branch.isEmpty {
                        Image(systemName: "arrow.triangle.branch")
                        Text(model.branch)
                    } else {
                        Text(name + " · " + session.providerLabel)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            activity
            Spacer(minLength: 6)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: { quickOpen = true }) {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.glass)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(session.projectFolder == nil)
                    .help("Open Quickly (⇧⌘O)")
                    Menu {
                        Toggle("Project Navigator", isOn: $showNavigator)
                            .keyboardShortcut("0", modifiers: .command)
                        Toggle("Assistant", isOn: $showAssistant)
                            .keyboardShortcut("0", modifiers: [.command, .option])
                            .disabled(session.approval != nil)
                        Button("Ask \(name)") { showAssistant = true; typing = true }
                            .keyboardShortcut("l", modifiers: .command)
                        Divider()
                        Button("Editor") { model.tab = 0 }.keyboardShortcut("1", modifiers: .command)
                        Button("Changes") { model.tab = 1 }.keyboardShortcut("2", modifiers: .command)
                        Button("Run Output") { model.tab = 2 }.keyboardShortcut("3", modifiers: .command)
                        Button("Terminal") { model.tab = 3 }.keyboardShortcut("4", modifiers: .command)
                        Divider()
                        Button("Save All") { model.saveAll() }
                            .keyboardShortcut("s", modifiers: [.command, .option])
                            .disabled(model.dirtyCount == 0)
                    } label: {
                        Image(systemName: "rectangle.split.3x1")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                    .help("Workspace layout and navigation")
                    EngineModelMenu(session: session)
                    Button(action: chooseFolder) {
                        Label(session.projectFolder == nil ? "Choose Folder…" : "Folder", systemImage: "folder")
                    }
                    .buttonStyle(.glass)
                    .help(session.projectFolder?.path ?? "Everything \(name) creates goes in the folder you choose")
                    Menu {
                        if session.engine == "claude" {
                            ForEach(model.conversations) { conversation in
                                Button(conversation.title) { session.resume(conversation) }
                            }
                            if !model.conversations.isEmpty { Divider() }
                        }
                        Button("New Conversation") { session.newConversation() }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                    .disabled(session.busy)
                    .help("Conversations")
                    if session.busy {
                        Button(action: { session.stop() }) {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.red)
                        .help("Stop")
                    }
                }
            }
            .controlSize(.regular)
        }
        .padding(.leading, 84)
        .padding(.trailing, 14)
        .frame(height: 52)
    }

    /// Xcode's activity view: what's happening now, or how the last run went.
    private var activity: some View {
        HStack(spacing: 7) {
            if session.busy {
                ProgressView().controlSize(.mini)
                let active = session.plan.first(where: { $0.status == "active" })?.active
                Text(active ?? session.steps.last.map { $0.detail.isEmpty ? $0.tool : $0.detail } ?? "\(name) is thinking…")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if !session.lastTest.isEmpty {
                Image(systemName: session.lastTest.hasPrefix("passed") ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(session.lastTest.hasPrefix("passed") ? .green : .red)
                Text(session.lastTest.prefix(1).capitalized + session.lastTest.dropFirst())
            } else {
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(tint)
                Text("\(name) · Idle")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(minWidth: 100, maxWidth: 320, minHeight: 28)
        .background(Surface.gutter, in: Capsule())
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
            HStack(spacing: 7) {
                Image(systemName: "sparkles").foregroundStyle(tint)
                Text(name).fontWeight(.semibold)
                Spacer()
                Text(session.providerLabel).foregroundStyle(.secondary)
                Button(action: { if session.approval == nil { showAssistant = false } }) {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help(session.approval == nil ? "Hide Assistant (⌥⌘0)" : "Review the pending approval first")
                .disabled(session.approval != nil)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 39)
            Divider()
            if !session.plan.isEmpty {
                PlanCard(plan: session.plan, tint: tint)
            }
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
                    .padding(.horizontal, 12)
            }
            if !session.attachments.isEmpty {
                attachmentRow
            }
            if !mentionMatches.isEmpty {
                MentionList(matches: mentionMatches, tint: tint) { path in
                    session.prefillDraft(Mentions.complete(session.draft, with: path))
                    typing = true
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: chooseAttachments) {
                    Image(systemName: "paperclip").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Attach files")
                .disabled(session.busy)
                TextField("Tell \(name) what to do… (@ to name a file)", text: $session.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($typing)
                    .onSubmit { session.send() }
                    .onKeyPress(.tab) {
                        guard let first = mentionMatches.first else { return .ignored }
                        session.prefillDraft(Mentions.complete(session.draft, with: first))
                        return .handled
                    }
                if session.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: {
                        typing = true
                        SpeechOut.dictate()
                    }) {
                        Image(systemName: "mic").font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Dictate (macOS Dictation)")
                    Button(action: { session.send() }) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(session.draft.isEmpty ? Color.secondary : tint)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Surface.separator, lineWidth: 0.5))
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        .solidCard(corner: 12, padding: 10)
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
                Text("Editor").tag(0)
                Text("Changes").tag(1)
                Text("Output").tag(2)
                Text("Terminal").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .frame(height: 39)
            Divider()
            if model.tab == 0 {
                fileViewer
            } else if model.tab == 1 {
                changesTab
            } else if model.tab == 2 {
                runTab
            } else {
                TerminalView(shell: shell, folder: session.projectFolder, name: name, busy: session.busy) { question in
                    session.draft = question
                    session.send()
                }
            }
        }
    }

    private func openFile(_ url: URL) {
        model.follow = false
        model.open(url)
        model.tab = 0
    }

    private var navigatorSelection: Binding<URL?> {
        Binding(get: { model.selected }, set: { url in
            guard let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { return }
            openFile(url)
        })
    }

    private var navigator: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Project").fontWeight(.semibold)
                Spacer()
                Button(action: { quickOpen = true }) { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .disabled(session.projectFolder == nil)
                    .help("Open Quickly (⇧⌘O)")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 39)
            Divider()
            Group {
                if model.tree.isEmpty {
                    Text(session.projectFolder == nil ? "No folder assigned yet." : "This folder is empty.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: navigatorSelection) {
                        OutlineGroup(model.tree, children: \.children) { node in
                            HStack(spacing: 6) {
                                Image(systemName: node.isFolder ? "folder" : "doc.text")
                                    .foregroundColor(node.isFolder ? .secondary : tint)
                                    .font(.system(size: 11))
                                Text(node.url.lastPathComponent)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if model.hasDraft(node.url) {
                                    Circle().fill(.secondary).frame(width: 5, height: 5)
                                        .accessibilityLabel("Unsaved changes")
                                }
                            }
                            .contentShape(Rectangle())
                            .tag(node.url)
                            .help(node.url.path)
                            .contextMenu {
                                if !node.isFolder {
                                    Button("Open") { openFile(node.url) }
                                }
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(maxHeight: .infinity)
            if model.dirtyCount > 0 {
                Divider()
                HStack {
                    Text("\(model.dirtyCount) unsaved").foregroundStyle(.secondary)
                    Spacer()
                    Button("Save All") { model.saveAll() }.buttonStyle(.borderless)
                }
                .font(.system(size: 11))
                .padding(10)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var fileViewer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text((model.selected?.lastPathComponent ?? "No file open") + (model.dirty ? " •" : ""))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(model.selected?.path ?? "Open a file from the project navigator")
                if model.selected != nil {
                    Button("Save") { model.save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(tint)
                        .disabled(!model.dirty)
                }
                Spacer()
                if !selection.text.isEmpty, let file = model.selected {
                    Button("Ask \(name)") {
                        askAbout(selection.text, in: file)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(tint)
                    .help("Ask \(name) about lines \(selection.first)–\(selection.last)")
                }
                Toggle("Follow \(name)", isOn: $model.follow)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Surface.gutter)
            if model.stale {
                HStack(spacing: 8) {
                    Text("This file changed on disk. Your edits are preserved.")
                        .font(.system(size: 11))
                    Spacer()
                    Button("Reload…") { confirmReload = true }
                    Button("Overwrite with Mine") { model.save(overwrite: true) }
                }
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.2))
            }
            if model.selected != nil {
                CodeEditor(text: $model.fileText, lang: model.selected?.pathExtension ?? "",
                           editable: model.editable, selection: selection, documentID: model.selected)
                Divider()
                HStack(spacing: 12) {
                    Text(model.editable ? "UTF-8" : "Read Only")
                    if let file = model.selected, !file.pathExtension.isEmpty { Text(file.pathExtension.uppercased()) }
                    Spacer()
                    Text(selection.text.isEmpty ? "Line \(max(selection.first, 1))" : "Lines \(selection.first)–\(selection.last)")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Surface.gutter)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "curlybraces").font(.system(size: 36, weight: .light)).foregroundStyle(tint)
                    Text("Your code, front and center").font(.system(size: 17, weight: .semibold))
                    Text(session.projectFolder == nil ? "Choose a project folder to get started." : "Open a file to edit, or ask \(name) to build something.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(session.projectFolder == nil ? "Choose Folder…" : "Open Quickly…") {
                        if session.projectFolder == nil { chooseFolder() } else { quickOpen = true }
                    }
                    .controlSize(.regular)
                    if session.projectFolder != nil {
                        Text("⇧⌘O to open a file · ⌘L to ask \(name)")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Surface.text)
    }

    private func askAbout(_ code: String, in file: URL) {
        var path = file.path
        if let root = session.projectFolder?.standardizedFileURL.path, path.hasPrefix(root + "/") {
            path = String(path.dropFirst(root.count + 1))
        }
        let shown = String(code.prefix(6000))
        draft("In `\(path)`, lines \(selection.first)–\(selection.last):\n```\(file.pathExtension)\n\(shown)\n```\n")
    }

    /// What changed in the project, against the checkpoint before a task or the last commit, with undo.
    private var changesTab: some View {
        ChangesView(session: session, name: name, tint: tint)
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
                            .foregroundStyle(.secondary)
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
                                .foregroundStyle(.primary)
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
        .background(Surface.text)
    }
}

/// The yes-or-no card for a risky action. Shared by the bubble and the workspace.
struct ApprovalCardView: View {
    @ObservedObject var session: ChatSession
    let approval: Approval
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: approval.danger ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(approval.danger ? Color.red : Color.orange)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(name) wants to use \(approval.tool)")
                        .font(.system(size: 13, weight: .semibold))
                    Text(approval.danger ? "This can't be undone or reaches outside this Mac. It always asks."
                                         : "Allow it once, for this task, or always.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if !approval.detail.isEmpty {
                Text(approval.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Surface.text, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Surface.separator, lineWidth: 0.5))
            }
            HStack(spacing: 8) {
                Button("Don't Allow") { session.decide(allow: false, forTask: false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !approval.danger {
                    Menu("More") {
                        Button("Allow for This Task") { session.decide(allow: true, forTask: true) }
                        Button("Always Allow " + approval.grantLabel) { session.decide(allow: true, forTask: true, always: true) }
                    }
                    .fixedSize()
                    .help("Allow \(approval.grantLabel) until this task ends, or always. Risky actions still ask.")
                }
                Button("Allow") { session.decide(allow: true, forTask: false) }
                    .buttonStyle(.borderedProminent)
                    .tint(approval.danger ? .red : .accentColor)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .solidCard(corner: 16, padding: 14)
        .padding(.vertical, 8)
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = sheet.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 860, height: 520)
        window.setFrameAutosaveName("SprytsIDE-" + sheet.id)
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

    /// True once the person has moved or sized the window: it reopens where they left it.
    private var placedBefore: Bool {
        UserDefaults.standard.string(forKey: "NSWindow Frame " + window.frameAutosaveName) != nil
    }

    func close() {
        window.performClose(nil)
    }

    /// Also used by the app delegate before quitting, so drafts are never silently abandoned.
    func confirmUnsavedChanges() -> Bool {
        guard model.dirtyCount > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = "Save your changes before closing?"
        alert.informativeText = "You have unsaved edits in \(model.dirtyCount) file\(model.dirtyCount == 1 ? "" : "s")."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return model.saveAll()
        case .alertThirdButtonReturn: model.discardAll(); return true
        default: return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmUnsavedChanges()
    }

    /// Opens the window, leaving room above it for the character to stand on its title bar.
    func show() {
        if !window.isVisible, !placedBefore, let screen = NSScreen.screens.first {
            let area = screen.visibleFrame
            let width = min(1240, area.width - 80)
            let height = min(760, area.height - 160)
            let frame = NSRect(x: area.midX - width / 2, y: area.minY + 40, width: width, height: height)
            window.setFrame(frame, display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
