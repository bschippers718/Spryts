import AppKit
import SwiftUI

// MARK: - A look per role

/// Each role has its own typeface, colours and shape, used by both its popup and its expanded view.
struct RoleTheme {
    let scheme: ColorScheme?     // nil follows the system
    let design: Font.Design
    let corner: CGFloat
    let paper: Color?            // nil uses Liquid Glass
    var glass: Bool { paper == nil }

    static func of(_ role: String) -> RoleTheme {
        switch role {
        case "coder":
            return RoleTheme(scheme: nil, design: .default, corner: 22, paper: nil)
        case "generalist":
            return RoleTheme(scheme: nil, design: .default, corner: 30, paper: nil)
        case "writer":
            return RoleTheme(scheme: .light, design: .serif, corner: 14,
                             paper: Color(red: 0.98, green: 0.96, blue: 0.91))
        case "forecaster":
            return RoleTheme(scheme: .dark, design: .rounded, corner: 30,
                             paper: Color(red: 0.12, green: 0.14, blue: 0.20))
        case "gamer":
            return RoleTheme(scheme: nil, design: .monospaced, corner: 16, paper: nil)
        case "coach":
            return RoleTheme(scheme: .dark, design: .rounded, corner: 18,
                             paper: Color(red: 0.05, green: 0.11, blue: 0.13))
        default:
            return RoleTheme(scheme: nil, design: .rounded, corner: 24, paper: nil)
        }
    }
}

/// A character's expanded view: Pip's desk, Nova's IDE, the writer's studio.
@MainActor
protocol Expansion: AnyObject {
    var isOpen: Bool { get }
    var isKey: Bool { get }
    var number: Int { get }
    var tethers: Bool { get }     // true when the character should go and sit on it
    func show()
    func close()
}

// MARK: - Pip's workspace

@MainActor
final class DeskController: NSObject, Expansion, NSWindowDelegate {
    static let size = CGSize(width: 1180, height: 760)
    private let window: NSWindow
    private let session: ChatSession
    private let shelf: AppShelf

    init(session: ChatSession, sheet: CharacterSheet, shelf: AppShelf, team: [ChatSession]) {
        self.session = session
        self.shelf = shelf
        let rect = NSRect(origin: .zero, size: DeskController.size)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.title = sheet.name
        window.contentMinSize = CGSize(width: 760, height: 560)
        window.setFrameAutosaveName("SprytsDesk-" + sheet.id)
        if let library = session.pipLibrary {
            let controller = PipSplitController(session: session, library: library, shelf: shelf, team: team,
                                                tint: Color(nsColor: NSColor(hex: sheet.look.body)))
            window.contentViewController = controller
            controller.installToolbar(in: window)
        } else {
            window.contentView = NSHostingView(rootView: ContentUnavailableView("Workspace unavailable", systemImage: "exclamationmark.triangle",
                description: Text("Pip's conversation library couldn't be opened. Your saved conversations have not been removed.")))
        }
    }

    var isOpen: Bool { window.isVisible && !window.isMiniaturized }
    var isKey: Bool { window.isKeyWindow }
    var number: Int { window.windowNumber }
    var tethers: Bool { false }

    func showToday() {
        if let split = window.contentViewController as? PipSplitController {
            split.openToday()
        }
    }

    func show() {
        let placedBefore = UserDefaults.standard.string(forKey: "NSWindow Frame " + window.frameAutosaveName) != nil
        if !window.isVisible, !placedBefore, let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            let width = min(DeskController.size.width, area.width - 40)
            let height = min(DeskController.size.height, area.height - 80)
            window.setFrame(NSRect(x: area.midX - width / 2, y: area.midY - height / 2,
                                   width: width, height: height), display: true)
        }
        shelf.refreshActivity()
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.performClose(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmPipSaved(session) }
}

@MainActor
func confirmPipSaved(_ session: ChatSession) -> Bool {
    // A library that never loaded cannot be overwritten. With no local composer to lose,
    // closing is safe and allows the person to repair the original file and relaunch.
    if session.pipLibrary?.needsRecovery == true && session.draft.isEmpty && session.attachments.isEmpty { return true }
    guard session.pipLibrary != nil, !session.save() else { return true }
    let alert = NSAlert()
    alert.messageText = "Your conversation couldn’t be saved"
    alert.informativeText = session.pipLibrary?.error ?? "Keep Spryts open and try saving again."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Keep Open")
    alert.runModal()
    return false
}

// MARK: - The writer's studio

struct Voice: Identifiable, Equatable {
    let id: String
    let guide: String
}

struct WritingSkill: Identifiable {
    let id: String
    let icon: String
    let instruction: String
    let returnsText: Bool      // true when the reply is text to put in the draft
}

/// Gives the studio access to the editor's selection and cursor.
final class EditorBridge: ObservableObject {
    weak var textView: NSTextView?
    var savedRange: NSRange?

    var selection: String {
        guard let view = textView else { return "" }
        let range = view.selectedRange()
        if range.length == 0 { return "" }
        return (view.string as NSString).substring(with: range)
    }

    func rememberSelection() {
        guard let view = textView else { return }
        let range = view.selectedRange()
        savedRange = range.length > 0 ? range : nil
    }

    func replaceSaved(with text: String) {
        guard let view = textView, let range = savedRange,
              range.location + range.length <= (view.string as NSString).length else { return }
        if view.shouldChangeText(in: range, replacementString: text) {
            view.replaceCharacters(in: range, with: text)
            view.didChangeText()
        }
        savedRange = nil
    }

    func insertAtCursor(_ text: String) {
        guard let view = textView else { return }
        let range = NSRange(location: view.selectedRange().location + view.selectedRange().length, length: 0)
        let piece = (range.location > 0 ? "\n\n" : "") + text
        if view.shouldChangeText(in: range, replacementString: piece) {
            view.replaceCharacters(in: range, with: piece)
            view.didChangeText()
        }
    }
}

/// The page: a real text view, so selection, undo and proper typography all work.
struct WritingEditor: NSViewRepresentable {
    @Binding var text: String
    let fontName: String
    let fontSize: CGFloat
    let bridge: EditorBridge

    static let paper = NSColor(srgbRed: 0.99, green: 0.975, blue: 0.94, alpha: 1)
    static let ink = NSColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: 1)

    static func font(_ name: String, size: CGFloat) -> NSFont {
        if name != "New York", let named = NSFont(name: name, size: size) { return named }
        let base = NSFont.systemFont(ofSize: size)
        if let serif = base.fontDescriptor.withDesign(.serif), let font = NSFont(descriptor: serif, size: size) {
            return font
        }
        return base
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.backgroundColor = WritingEditor.paper
        scroll.hasVerticalScroller = true
        if let view = scroll.documentView as? NSTextView {
            view.isRichText = false
            view.allowsUndo = true
            view.drawsBackground = true
            view.backgroundColor = WritingEditor.paper
            view.insertionPointColor = WritingEditor.ink
            view.isAutomaticQuoteSubstitutionEnabled = true
            view.isAutomaticDashSubstitutionEnabled = true
            view.delegate = context.coordinator
            view.string = text
            bridge.textView = view
            style(view, in: scroll)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            view.string = text
        }
        style(view, in: scroll)
    }

    /// Typeface, line spacing, and margins that keep the text in a readable column.
    private func style(_ view: NSTextView, in scroll: NSScrollView) {
        let font = WritingEditor.font(fontName, size: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.45
        paragraph.paragraphSpacing = fontSize * 0.6
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph, .foregroundColor: WritingEditor.ink
        ]
        view.typingAttributes = attributes
        view.defaultParagraphStyle = paragraph
        if let storage = view.textStorage {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        let side = max(44, (scroll.contentSize.width - 720) / 2)
        view.textContainerInset = NSSize(width: side, height: 48)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WritingEditor

        init(_ parent: WritingEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

/// The studio's documents, typeface and voice.
final class StudioModel: ObservableObject {
    @Published var documents: [URL] = []
    @Published var current: URL?
    @Published var text = ""
    @Published var fontName: String
    @Published var fontSize: CGFloat
    @Published var voiceID: String
    @Published var hasOwnVoice: Bool
    private var loadedText = ""
    private var pending: DispatchWorkItem?

    static let fonts = ["New York", "Charter", "Iowan Old Style", "Palatino", "Baskerville", "Avenir Next", "Menlo"]

    static let skills: [WritingSkill] = [
        WritingSkill(id: "Continue", icon: "arrow.right.to.line", instruction: "Continue this draft from exactly where it leaves off with the next paragraph or two. Do not repeat what is already there.", returnsText: true),
        WritingSkill(id: "Tighten", icon: "arrow.down.right.and.arrow.up.left", instruction: "Tighten this: cut filler and repetition, keep every idea and the meaning.", returnsText: true),
        WritingSkill(id: "Expand", icon: "arrow.up.left.and.arrow.down.right", instruction: "Expand this with concrete detail and example. Add substance, not padding.", returnsText: true),
        WritingSkill(id: "Rewrite", icon: "arrow.triangle.2.circlepath", instruction: "Rewrite this in the voice described, keeping the meaning.", returnsText: true),
        WritingSkill(id: "Proofread", icon: "checkmark.seal", instruction: "Proofread this: fix spelling, grammar and punctuation only. Change nothing else.", returnsText: true),
        WritingSkill(id: "Critique", icon: "text.magnifyingglass", instruction: "Give an honest critique of this in five short points: what works, what doesn't, and the single most valuable change.", returnsText: false),
        WritingSkill(id: "Outline", icon: "list.bullet.indent", instruction: "Outline what this draft is doing, section by section, and note anything missing.", returnsText: false),
        WritingSkill(id: "Titles", icon: "textformat.size", instruction: "Suggest eight titles for this piece, ranging from plain to bold.", returnsText: false)
    ]

    init() {
        let defaults = UserDefaults.standard
        fontName = defaults.string(forKey: "studio.font") ?? "New York"
        let size = defaults.double(forKey: "studio.size")
        fontSize = size > 0 ? CGFloat(size) : 18
        voiceID = defaults.string(forKey: "studio.voice") ?? "Plain"
        hasOwnVoice = !(defaults.string(forKey: "studio.ownVoice") ?? "").isEmpty
    }

    var voices: [Voice] {
        var list = [
            Voice(id: "Plain", guide: "plain and direct: everyday words, short sentences, no ornament"),
            Voice(id: "Warm", guide: "warm and conversational: friendly, personal, unhurried"),
            Voice(id: "Punchy", guide: "punchy: short, energetic sentences, strong verbs, a little attitude"),
            Voice(id: "Formal", guide: "formal and precise: measured, complete sentences, no slang"),
            Voice(id: "Lyrical", guide: "lyrical: rhythm and imagery matter, sentences vary in length, still clear")
        ]
        let sample = UserDefaults.standard.string(forKey: "studio.ownVoice") ?? ""
        if !sample.isEmpty {
            list.append(Voice(id: "Mine", guide: "the writer's own voice. Match the rhythm, word choice and tone of this sample of their writing:\n\"\"\"\n" + sample + "\n\"\"\""))
        }
        return list
    }

    var voice: Voice {
        voices.first(where: { $0.id == voiceID }) ?? voices[0]
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }

    func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(fontName, forKey: "studio.font")
        defaults.set(Double(fontSize), forKey: "studio.size")
        defaults.set(voiceID, forKey: "studio.voice")
    }

    /// Learns the person's voice from what is on the page now.
    func learnVoice() {
        let sample = String(text.prefix(2500)).trimmingCharacters(in: .whitespacesAndNewlines)
        if sample.count < 200 { return }
        UserDefaults.standard.set(sample, forKey: "studio.ownVoice")
        hasOwnVoice = true
        voiceID = "Mine"
        savePreferences()
    }

    func folder(for session: ChatSession) -> URL {
        if let assigned = session.projectFolder { return assigned }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return documents.appendingPathComponent("Spryts Writing")
    }

    func load(folder: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        var found = urls.filter { ["md", "txt", "markdown"].contains($0.pathExtension.lowercased()) }
        found.sort(by: { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            return da > db
        })
        documents = found
        if let current, found.contains(current) { return }
        if let first = found.first {
            open(first)
        } else {
            newDocument(in: folder)
        }
    }

    func open(_ url: URL) {
        saveNow()
        current = url
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        loadedText = content
        text = content
    }

    func newDocument(in folder: URL) {
        saveNow()
        var index = 1
        var url = folder.appendingPathComponent("Untitled.md")
        while FileManager.default.fileExists(atPath: url.path) {
            index += 1
            url = folder.appendingPathComponent("Untitled \(index).md")
        }
        try? "".write(to: url, atomically: true, encoding: .utf8)
        documents.insert(url, at: 0)
        current = url
        loadedText = ""
        text = ""
    }

    /// Saves a moment after typing stops.
    func textChanged() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveNow() {
        guard let current, text != loadedText else { return }
        try? text.write(to: current, atomically: true, encoding: .utf8)
        loadedText = text
    }
}

struct StudioView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var model: StudioModel
    @ObservedObject var bridge: EditorBridge
    let name: String
    let tint: Color

    private let paper = Color(red: 0.99, green: 0.975, blue: 0.94)
    private let ink = Color(red: 0.13, green: 0.12, blue: 0.11)
    private let edge = Color(red: 0.94, green: 0.915, blue: 0.86)

    var body: some View {
        HStack(spacing: 0) {
            shelf
                .frame(width: 190)
                .frame(maxHeight: .infinity)
                .background(edge)
            VStack(spacing: 0) {
                toolbar
                WritingEditor(text: $model.text, fontName: model.fontName, fontSize: model.fontSize, bridge: bridge)
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            partner
                .frame(width: 310)
                .frame(maxHeight: .infinity)
                .background(edge)
        }
        .frame(minWidth: 940, minHeight: 540)
        .background(paper)
        .foregroundColor(ink)
        .fontDesign(.serif)
        .environment(\.colorScheme, .light)
        .onChange(of: model.text) { model.textChanged() }
        .onChange(of: model.fontName) { model.savePreferences() }
        .onChange(of: model.fontSize) { model.savePreferences() }
        .onChange(of: model.voiceID) { model.savePreferences() }
        .onChange(of: session.projectFolder) { model.load(folder: model.folder(for: session)) }
    }

    // MARK: Document shelf

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Drafts").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: { model.newDocument(in: model.folder(for: session)) }) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("New draft")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.documents, id: \.self) { url in
                        Button(action: { model.open(url) }) {
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(.system(size: 13, weight: url == model.current ? .semibold : .regular))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(url == model.current ? tint.opacity(0.22) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
            Divider()
            Button(action: chooseFolder) {
                Label(model.folder(for: session).lastPathComponent, systemImage: "folder")
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .padding(12)
            .help("Choose where drafts are kept")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Keep drafts here"
        if panel.runModal() == .OK, let url = panel.url {
            session.assign(folder: url)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            Text(model.current?.deletingPathExtension().lastPathComponent ?? "Untitled")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text("\(model.wordCount) words · \(max(1, model.wordCount / 230)) min read")
                .font(.system(size: 11))
                .foregroundColor(ink.opacity(0.55))
            Spacer()
            Picker("", selection: $model.fontName) {
                ForEach(StudioModel.fonts, id: \.self) { font in
                    Text(font).tag(font)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            Stepper(value: $model.fontSize, in: 13...26, step: 1) {
                Text("\(Int(model.fontSize)) pt").font(.system(size: 11))
            }
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(paper)
    }

    // MARK: The writing partner

    private var partner: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 11, height: 11)
                Text(name).font(.system(size: 15, weight: .semibold))
                Spacer()
                if session.busy {
                    Button(action: { session.stop() }) { Image(systemName: "stop.circle.fill") }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            HStack(spacing: 8) {
                Text("Voice").font(.system(size: 11)).foregroundColor(ink.opacity(0.55))
                Picker("", selection: $model.voiceID) {
                    ForEach(model.voices) { voice in
                        Text(voice.id).tag(voice.id)
                    }
                }
                .labelsHidden()
                Button("Learn mine") { model.learnVoice() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(tint)
                    .help("Learn your voice from this draft (needs a couple of paragraphs)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(StudioModel.skills) { skill in
                    Button(action: { run(skill) }) {
                        HStack(spacing: 6) {
                            Image(systemName: skill.icon).font(.system(size: 11)).frame(width: 14)
                            Text(skill.id).font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(tint.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(session.busy)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            Text("Skills act on your selection, or the whole draft if nothing is selected.")
                .font(.system(size: 10))
                .foregroundColor(ink.opacity(0.5))
                .padding(.horizontal, 14)
                .padding(.top, 6)

            Divider().padding(.top, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(session.messages.filter { !$0.hidden }.suffix(14)) { message in
                            suggestion(message)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(12)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: session.messages) { proxy.scrollTo("end", anchor: .bottom) }
            }
            Divider()
            TextField("Ask \(name) about this draft…", text: $session.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(12)
                .onSubmit { askAboutDraft() }
        }
    }

    private func suggestion(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.role == "user" {
                Text(message.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ink.opacity(0.55))
            } else {
                Text(message.text.isEmpty ? "…" : message.text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(paper)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                if !message.text.isEmpty && !session.busy {
                    HStack(spacing: 12) {
                        if bridge.savedRange != nil {
                            Button("Replace selection") { bridge.replaceSaved(with: message.text) }
                        }
                        Button("Insert") { bridge.insertAtCursor(message.text) }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(tint)
                }
            }
        }
    }

    private func run(_ skill: WritingSkill) {
        bridge.rememberSelection()
        let selected = bridge.selection
        var target = selected.isEmpty ? model.text : selected
        if skill.id == "Continue" { target = String(model.text.suffix(5000)) }
        if target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        if skill.id == "Continue" { bridge.savedRange = nil }
        var prompt = skill.instruction + "\nVoice: " + model.voice.guide + "."
        if skill.returnsText {
            prompt += "\nReply with only the resulting text: no preamble, no quotation marks, no commentary."
        }
        prompt += "\n\nText:\n" + String(target.prefix(14000))
        let scope = skill.id == "Continue" ? "" : (selected.isEmpty ? " the whole draft" : " the selection")
        session.ask(display: skill.id + scope + " · " + model.voiceID, prompt: prompt)
    }

    private func askAboutDraft() {
        let question = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty || session.busy { return }
        session.draft = ""
        bridge.savedRange = nil
        let prompt = question + "\n\n(The current draft, for context:\n" + String(model.text.prefix(10000)) + "\n)"
        session.ask(display: question, prompt: prompt)
    }
}

@MainActor
final class StudioWindowController: NSObject, Expansion {
    let window: NSWindow
    private let model = StudioModel()
    private let bridge = EditorBridge()
    private let session: ChatSession

    init(session: ChatSession, sheet: CharacterSheet) {
        self.session = session
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 700),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = sheet.name + "'s studio"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = WritingEditor.paper
        let view = StudioView(session: session, model: model, bridge: bridge, name: sheet.name,
                              tint: Color(nsColor: NSColor(hex: sheet.look.body)))
            .padding(.top, 28)
        window.contentView = NSHostingView(rootView: view)
        model.load(folder: model.folder(for: session))
    }

    var isOpen: Bool { window.isVisible && !window.isMiniaturized }
    var isKey: Bool { window.isKeyWindow }
    var number: Int { window.windowNumber }
    var tethers: Bool { true }

    func show() {
        if !window.isVisible, let screen = NSScreen.screens.first {
            let area = screen.visibleFrame
            let width = min(1140, area.width - 80)
            let height = min(700, area.height - 220)
            window.setFrame(NSRect(x: area.midX - width / 2, y: area.minY + 40, width: width, height: height), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        model.saveNow()
        window.orderOut(nil)
    }
}
