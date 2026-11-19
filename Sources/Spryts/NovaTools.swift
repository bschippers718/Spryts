import AppKit
import SwiftUI

// The programmer's tools inside the IDE: an editor, the agent's plan, @-mentions and a terminal.

extension Highlighter {
    /// The same colours as `color`, as ranges for a text view. Plain text is left out.
    static func spans(_ code: String, lang: String) -> [(NSRange, NSColor)] {
        let attributed = color(code, lang: lang, limit: 200_000)
        var out: [(NSRange, NSColor)] = []
        for run in attributed.runs {
            guard let color = run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self], color != base else { continue }
            out.append((NSRange(run.range, in: attributed), NSColor(color)))
        }
        return out
    }
}

/// What is selected in the editor, so it can be handed to the agent.
final class CodeSelection: ObservableObject {
    @Published var text = ""
    @Published var first = 0
    @Published var last = 0
}

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let lang: String
    let editable: Bool
    let selection: CodeSelection
    let documentID: URL?

    static let background = CodePalette.background
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.font = CodeEditor.font
        view.textColor = CodePalette.text
        view.backgroundColor = CodeEditor.background
        view.insertionPointColor = .textColor
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.isHorizontallyResizable = true
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = CodeEditor.background
        scroll.verticalRulerView = CodeLineRuler(textView: view, scrollView: scroll)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.view = view
        context.coordinator.load(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = context.coordinator.view else { return }
        view.isEditable = editable
        if context.coordinator.documentID != documentID {
            context.coordinator.documentID = documentID
            context.coordinator.load(text, newDocument: true)
        } else if view.string != text {
            context.coordinator.load(text)
        } else if context.coordinator.lang != lang {
            context.coordinator.lang = lang
            context.coordinator.recolor()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var view: NSTextView?
        var lang = ""
        var documentID: URL?
        private var pending: DispatchWorkItem?

        init(_ parent: CodeEditor) {
            self.parent = parent
            documentID = parent.documentID
        }

        func load(_ text: String, newDocument: Bool = false) {
            guard let view else { return }
            pending?.cancel()
            let keep = view.selectedRange()
            view.string = text
            // A replacement from disk must not remain in the previous document's undo stack.
            view.undoManager?.removeAllActions()
            lang = parent.lang
            recolor()
            let caret = newDocument ? 0 : min(keep.location, (text as NSString).length)
            view.setSelectedRange(NSRange(location: caret, length: 0))
            if newDocument { view.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func recolor() {
            guard let storage = view?.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: CodeEditor.font, .foregroundColor: CodePalette.text], range: full)
            if storage.length < 150_000 {
                for (range, color) in Highlighter.spans(storage.string, lang: lang)
                where range.location + range.length <= storage.length {
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
            storage.endEditing()
        }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.string
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.recolor() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view else { return }
            let range = view.selectedRange()
            let all = view.string as NSString
            guard range.location + range.length <= all.length else { return }
            let picked = range.length > 0 ? all.substring(with: range) : ""
            let first = all.substring(to: range.location).filter { $0 == "\n" }.count + 1
            let last = first + picked.trimmingCharacters(in: .newlines).filter { $0 == "\n" }.count
            let selection = parent.selection
            let document = parent.documentID
            DispatchQueue.main.async { [weak self] in
                guard self?.parent.documentID == document else { return }
                selection.text = picked
                selection.first = first
                selection.last = last
            }
        }
    }
}

/// A native ruler stays aligned with the editor while scrolling and searching.
final class CodeLineRuler: NSRulerView {
    private weak var editor: NSTextView?
    private var observer: NSObjectProtocol?
    override var isFlipped: Bool { true }

    init(textView: NSTextView, scrollView: NSScrollView) {
        editor = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 48
        scrollView.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                          object: scrollView.contentView, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        CodePalette.gutter.setFill()
        bounds.fill()
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        let text = editor.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let origin = editor.textContainerOrigin
        let visible = editor.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let start = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location
        var line = text.substring(to: min(start, text.length)).filter { $0 == "\n" }.count + 1
        func draw(_ number: Int, at y: CGFloat) {
            let label = String(number) as NSString
            let size = label.size(withAttributes: attributes)
            let point = convert(NSPoint(x: 0, y: y + origin.y), from: editor)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: point.y + 1), withAttributes: attributes)
        }
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
            draw(line, at: fragment.minY)
            line += 1
        }
        if text.length == 0 || (editor.string.hasSuffix("\n") && NSMaxRange(glyphs) == layout.numberOfGlyphs) {
            draw(line, at: layout.extraLineFragmentRect.minY)
        }
    }
}

struct QuickOpenView: View {
    let files: [String]
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool
    @State private var query = ""
    @State private var selected = 0

    private var matches: [String] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return Array(files.filter { path in terms.allSatisfy { path.lowercased().contains($0) } }
            .sorted { a, b in
                let aName = (a as NSString).lastPathComponent.lowercased().hasPrefix(query.lowercased())
                let bName = (b as NSString).lastPathComponent.lowercased().hasPrefix(query.lowercased())
                if aName != bName { return aName }
                return a.localizedStandardCompare(b) == .orderedAscending
            }.prefix(60))
    }

    private func choose(_ path: String) { open(path); dismiss() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Open Quickly", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($typing)
                    .onSubmit { if matches.indices.contains(selected) { choose(matches[selected]) } }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(matches.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element) { index, path in
                            Button(action: { choose(path) }) {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text((path as NSString).lastPathComponent).fontWeight(.medium)
                                        Text((path as NSString).deletingLastPathComponent)
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.head)
                                    }
                                    Spacer()
                                    if index == selected { Image(systemName: "return").foregroundStyle(.secondary) }
                                }
                                .font(.system(size: 13))
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .contentShape(Rectangle())
                                .background(index == selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                        if matches.isEmpty {
                            Text("No matching files").foregroundStyle(.secondary).padding(30)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selected) { proxy.scrollTo(selected) }
            }
            Divider()
            HStack {
                Text("↑ ↓ to navigate · Return to open")
                Spacer()
                Text("\(files.count) project files")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 560, height: 430)
        .background(Surface.text)
        .onChange(of: query) { selected = 0 }
        .onAppear { typing = true }
    }
}

// MARK: - The plan

/// The agent's to-do list for the task in hand, ticked off as it goes.
struct PlanCard: View {
    let plan: [PlanItem]
    let tint: Color
    @State private var open = true

    private var done: Int { plan.filter { $0.status == "done" }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { open.toggle() }) {
                HStack(spacing: 7) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Image(systemName: "checklist").font(.system(size: 12)).foregroundStyle(tint)
                    Text("Plan").font(.system(size: 12, weight: .semibold))
                    Text("\(done) of \(plan.count)").font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(tint).frame(width: 90 * CGFloat(done) / CGFloat(max(plan.count, 1)))
                    }
                    .frame(width: 90, height: 5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(plan) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: item.status == "done" ? "checkmark.circle.fill" : (item.status == "active" ? "circle.dotted" : "circle"))
                            .font(.system(size: 11))
                            .foregroundColor(item.status == "done" ? .green : (item.status == "active" ? tint : .secondary))
                        Text(item.status == "active" ? item.active : item.text)
                            .font(.system(size: 12, weight: item.status == "active" ? .semibold : .regular))
                            .strikethrough(item.status == "done", color: .secondary)
                            .foregroundColor(item.status == "done" ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .solidCard(corner: 14, padding: 12)
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

// MARK: - @-mentions

enum Mentions {
    /// The text after an @ the person is still typing, if any.
    static func query(_ draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex && !draft[draft.index(before: at)].isWhitespace { return nil }
        let typed = draft[draft.index(after: at)...]
        if typed.contains(where: { $0.isWhitespace }) { return nil }
        return String(typed)
    }

    static func matches(_ query: String, in files: [String]) -> [String] {
        let q = query.lowercased()
        if q.isEmpty { return Array(files.prefix(7)) }
        let named = files.filter { ($0 as NSString).lastPathComponent.lowercased().hasPrefix(q) }
        let rest = files.filter { $0.lowercased().contains(q) && !named.contains($0) }
        return Array((named.sorted { $0.count < $1.count } + rest).prefix(7))
    }

    static func complete(_ draft: String, with path: String) -> String {
        guard let at = draft.lastIndex(of: "@") else { return draft }
        return String(draft[..<at]) + "@" + path + " "
    }
}

struct MentionList: View {
    let matches: [String]
    let tint: Color
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element) { item in
                Button(action: { pick(item.element) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").font(.system(size: 10)).foregroundColor(tint)
                        Text((item.element as NSString).lastPathComponent).font(.system(size: 12, weight: .medium))
                        Text((item.element as NSString).deletingLastPathComponent)
                            .font(.system(size: 11)).foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 0)
                        if item.offset == 0 { Text("tab").font(.system(size: 9)).foregroundColor(.secondary) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(item.offset == 0 ? tint.opacity(0.15) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Surface.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

// MARK: - Terminal

/// The person's own commands, run in the project. One at a time, and not interactive.
final class ShellRunner: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let command: String
        var output = ""
        var running = true
        var status: Int32 = 0
    }

    @Published var entries: [Entry] = []
    @Published var input = ""
    @Published private(set) var running = false
    private var process: Process?

    func run(in folder: URL?) {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, process == nil else { return }
        input = ""
        if command == "clear" {
            entries = []
            return
        }
        entries.append(Entry(command: command))
        let index = entries.count - 1
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/zsh")
        run.arguments = ["-lc", command]
        run.currentDirectoryURL = folder ?? URL(fileURLWithPath: NSHomeDirectory())
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin"
        run.environment = environment
        let pipe = Pipe()
        run.standardOutput = pipe
        run.standardError = pipe
        run.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.append(text, at: index) }
        }
        run.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { self?.finish(index, status: status) }
        }
        do {
            try run.run()
            process = run
            running = true
        } catch {
            entries[index].output = error.localizedDescription
            entries[index].running = false
            entries[index].status = 1
        }
    }

    private func append(_ text: String, at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries[index].output += text
        if entries[index].output.count > 60_000 { entries[index].output = String(entries[index].output.suffix(50_000)) }
    }

    private func finish(_ index: Int, status: Int32) {
        if entries.indices.contains(index) {
            entries[index].running = false
            entries[index].status = status
        }
        process = nil
        running = false
    }

    func stop() {
        guard let run = process, run.isRunning else { return }
        run.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if run.isRunning { run.terminate() } }
    }
}

struct TerminalView: View {
    @ObservedObject var shell: ShellRunner
    let folder: URL?
    let name: String
    let busy: Bool
    let onAsk: (String) -> Void
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if shell.entries.isEmpty {
                            Text("Your own commands, run in \(folder?.lastPathComponent ?? "your home folder"). One at a time; programs that wait for typing won't work here.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                        }
                        ForEach(shell.entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text("$ " + entry.command)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundColor(entry.running ? Highlighter.hunk : (entry.status == 0 ? Highlighter.added : Highlighter.removed))
                                        .textSelection(.enabled)
                                    Spacer(minLength: 0)
                                    if !entry.running && entry.status != 0 {
                                        Button("Ask \(name)") {
                                            onAsk("This command failed (exit \(entry.status)). What's wrong, and what would you do?\n\n```\n$ "
                                                  + entry.command + "\n" + String(entry.output.suffix(4000)) + "\n```")
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Highlighter.hunk)
                                        .disabled(busy)
                                    }
                                }
                                if !entry.output.isEmpty || entry.running {
                                    Text(entry.output.isEmpty ? "running…" : entry.output)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("shellEnd")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: shell.entries.last?.output) { proxy.scrollTo("shellEnd", anchor: .bottom) }
                .onChange(of: shell.entries.count) { proxy.scrollTo("shellEnd", anchor: .bottom) }
            }
            Divider()
            HStack(spacing: 8) {
                Text("$").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(Highlighter.added)
                TextField(shell.running ? "running…" : "command", text: $shell.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($typing)
                    .onSubmit { shell.run(in: folder) }
                    .disabled(shell.running)
                if shell.running {
                    Button(action: { shell.stop() }) { Image(systemName: "stop.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundColor(Highlighter.removed)
                        .help("Stop (sends Control-C)")
                }
            }
            .padding(10)
            .background(Surface.gutter)
        }
        .background(Surface.text)
        .onAppear { typing = true }
    }
}
