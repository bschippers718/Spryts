import AppKit
import Carbon.HIToolbox
import SceneKit

/// The transparent stage. It only receives clicks while the cursor is on a character.
final class StageView: SCNView {
    weak var stage: AppDelegate?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { stage?.pointerDown(at: NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { stage?.pointerDragged(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { stage?.pointerUp(at: NSEvent.mouseLocation, clicks: event.clickCount) }

    // Files dragged from Finder and dropped on a character.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let found = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let urls = (found as? [URL]) ?? []
        if urls.isEmpty { return false }
        stage?.dropped(urls, at: NSEvent.mouseLocation)
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSPanel!
    private var stageView: StageView!
    private let scene = SCNScene()
    private let world = World()
    private var characters: [SprytCharacter] = []
    private var panels: [String: ChatPanelController] = [:]
    private var bubbles: [String: SpeechBubbleController] = [:]
    private var weatherDrops: [String: WeatherDropController] = [:]   // the forecaster's five-day sky, toggled by a click
    private let shelf = AppShelf()
    private var hotKey: HotKey?
    private var seenRequests: Set<String> = []
    private var workspaces: [String: Expansion] = [:]
    private var pendingClick: SprytCharacter?
    private var pendingClickTime: CGFloat = 0
    private var hover: [String: CGFloat] = [:]
    private var frontPopup = ""
    private var weatherClock: CGFloat = 0
    private var maker: SprytMakerController?
    private var away: [String: CGFloat] = [:]
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var last = CACurrentMediaTime()
    private var worldClock: CGFloat = 1
    private var quiet = false
    private var restartRequested = false

    // Presence: is the person here, and for how long.
    private var idleSeconds: CGFloat = 0
    private var isAway = false
    private var awayFor: CGFloat = 0
    private var night = false
    private var activeStreak: CGFloat = 0
    private var uptime: CGFloat = 0

    // Speaking first, on a budget.
    private var speakFirst = true
    private var saidHello = false
    private var sinceRemark: CGFloat = 600

    private var grabbed: SprytCharacter?
    private var game: OrangeSmash?
    private let arcade = ArcadeController()
    private var engineItems: [NSMenuItem] = []
    private var hud: GameHUDController?
    private var dragging = false
    private var grabOffset = CGPoint.zero
    private var downAt = CGPoint.zero
    private var lastDrag = CGPoint.zero
    private var lastDragTime = CACurrentMediaTime()
    private var dragVelocity = CGVector(dx: 0, dy: 0)

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first else {
            NSApp.terminate(nil)
            return
        }
        let frame = screen.frame

        window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        stageView = StageView(frame: NSRect(origin: .zero, size: frame.size), options: nil)
        stageView.stage = self
        stageView.scene = scene
        stageView.backgroundColor = .clear
        stageView.antialiasingMode = .multisampling4X
        stageView.autoenablesDefaultLighting = false
        stageView.rendersContinuously = true
        stageView.preferredFramesPerSecond = 60
        stageView.registerForDraggedTypes([.fileURL])
        window.contentView = stageView
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()

        // An orthographic camera set up so one scene unit is one screen point.
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(frame.height / 2)
        camera.zNear = 1
        camera.zFar = 8000
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = v3(frame.width / 2, frame.height / 2, 3000)
        scene.rootNode.addChildNode(cameraNode)
        stageView.pointOfView = cameraNode

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 550
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 850
        let sunNode = SCNNode()
        sunNode.light = sun
        sunNode.eulerAngles = v3(-0.55, 0.45, 0)
        scene.rootNode.addChildNode(sunNode)

        refreshWorld()

        let sheets = Config.loadSheets()
        var index: CGFloat = 0
        for sheet in sheets {
            let x = frame.minX + frame.width * (0.25 + 0.5 * index / CGFloat(max(sheets.count - 1, 1)))
            let start = CGPoint(x: x, y: frame.maxY - sheet.look.height - 40)
            let character = SprytCharacter(sheet: sheet, start: start, zIndex: index * 300)
            character.zone = (index + 0.5) / CGFloat(max(sheets.count, 1))
            character.zoneSpan = 1 / CGFloat(max(sheets.count, 1))
            scene.rootNode.addChildNode(character.node)
            characters.append(character)
            panels[sheet.id] = ChatPanelController(session: character.session, sheet: sheet, shelf: shelf)
            let apps = shelf
            character.session.contextProvider = {
                apps.context + FocusKeeper.contextNote()
                    + ((sheet.role ?? "generalist") == "generalist" ? TeamCoordinator.shared.context(for: sheet.id) : "")
            }
            if (sheet.role ?? "generalist") == "generalist" {
                character.session.onTaskFinished = { ask, done in
                    apps.note(ask, mentioning: ask + " " + done)
                }
            }
            if sheet.harness != nil && AppDelegate.hasPlace(sheet.role) {
                let id = sheet.id
                character.session.onOpenWorkspace = { [weak self] in
                    Task { @MainActor [weak self] in self?.openWorkspace(id) }
                }
            }
            let playID = sheet.id
            character.session.onPlay = { [weak self] in
                Task { @MainActor [weak self] in self?.startGame(playID) }
            }
            // With a gamer on the team, everyone can hand you over to her arcade while they work.
            if sheets.contains(where: { $0.role == "gamer" }) {
                character.session.onArcade = { [weak self] game in
                    Task { @MainActor [weak self] in self?.startArcade(game) }
                }
            }
            bubbles[sheet.id] = SpeechBubbleController()
            if sheet.role == "forecaster" { weatherDrops[sheet.id] = WeatherDropController(id: sheet.id) }
            hover[sheet.id] = 0
            away[sheet.id] = 0
            index += 1
        }

        TeamCoordinator.shared.recoverInterrupted()
        buildMenu()
        buildEditMenu()

        // Control-Option-Space summons the first character from anywhere.
        hotKey = HotKey(keyCode: 49, modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            Task { @MainActor [weak self] in self?.summon() }
        }

        let t = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for workspace in workspaces.values {
            if let coding = workspace as? WorkspaceWindowController, !coding.confirmUnsavedChanges() {
                restartRequested = false
                return .terminateCancel
            }
        }
        for character in characters where character.session.pipLibrary != nil {
            if !confirmPipSaved(character.session) {
                restartRequested = false
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        for character in characters {
            character.session.stop()
            character.session.save()
        }
        if restartRequested { launchReplacement() }
    }

    /// Opens the big workspace window for a character and sends the character to sit on it.
    func openWorkspace(_ id: String) {
        guard let character = characters.first(where: { $0.sheet.id == id }) else { return }
        let controller: Expansion
        if let existing = workspaces[id] {
            controller = existing
        } else {
            // Each role opens into its own kind of place.
            switch character.sheet.role ?? "generalist" {
            case "coder":
                controller = WorkspaceWindowController(session: character.session, sheet: character.sheet)
            case "writer":
                controller = StudioWindowController(session: character.session, sheet: character.sheet)
            case "forecaster":
                controller = ForecastRoomController(session: character.session, sheet: character.sheet)
            case "coach":
                controller = TrainingRoomController(session: character.session, sheet: character.sheet)
            case "gamer":
                controller = ArcadeRoomController(session: character.session, sheet: character.sheet)
            case "generalist":
                controller = DeskController(session: character.session, sheet: character.sheet, shelf: shelf, team: characters.map(\.session))
            default:
                // A role without a place of its own has no big window. It never borrows someone else's.
                return
            }
            workspaces[id] = controller
        }
        character.session.pinned = false
        panels[id]?.hide()
        character.wake()
        character.returnToStage(world: world, others: characters)
        if controller.isOpen && controller.isKey && !controller.tethers {
            controller.close()   // the desk toggles
        } else {
            controller.show()
        }
    }

    static func placeName(_ role: String?) -> String {
        switch role ?? "generalist" {
        case "coder": return "IDE"
        case "writer": return "studio"
        case "coach": return "training room"
        case "gamer": return "arcade"
        case "forecaster": return "forecast"
        default: return "desk"
        }
    }

    /// What a character does, in a word, for the menu.
    static func jobName(_ role: String?) -> String {
        switch role ?? "generalist" {
        case "generalist": return "your day"
        case "coder": return "code"
        case "writer": return "writing"
        case "coach": return "training"
        case "gamer": return "games"
        case "forecaster": return "weather"
        case "companion": return "made by you"
        default: return role ?? ""
        }
    }

    /// Roles that have an expanded view built for them.
    static func hasPlace(_ role: String?) -> Bool {
        ["generalist", "coder", "writer", "coach", "forecaster", "gamer"].contains(role ?? "generalist")
    }

    @objc private func openWorkspaceFromMenu(_ sender: NSMenuItem) {
        guard sender.tag >= 0 && sender.tag < characters.count else { return }
        openWorkspace(characters[sender.tag].sheet.id)
    }

    /// Responder-chain commands work in every native workspace, including the focused code editor.
    private func buildEditMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Spryts Studio")
        applicationMenu.addItem(NSMenuItem(title: "About Spryts Studio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title: "Hide Spryts Studio", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        applicationMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title: "Quit Spryts Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(NSMenuItem(title: "New Chat", action: #selector(PipSplitController.newPipChat(_:)), keyEquivalent: "n"))
        let newProject = NSMenuItem(title: "New Project…", action: #selector(PipSplitController.newPipProject(_:)), keyEquivalent: "n")
        newProject.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(newProject)
        file.addItem(.separator())
        file.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.addItem(.separator())
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        edit.addItem(find)
        let next = NSMenuItem(title: "Find Next", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        next.tag = Int(NSFindPanelAction.next.rawValue)
        edit.addItem(next)
        let previous = NSMenuItem(title: "Find Previous", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        previous.tag = Int(NSFindPanelAction.previous.rawValue)
        previous.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(previous)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Search Chats and Projects", action: #selector(PipSplitController.searchPipChats(_:)), keyEquivalent: "k"))
        edit.addItem(NSMenuItem(title: "Focus Pip’s Conversation", action: #selector(PipSplitController.focusPipChat(_:)), keyEquivalent: "l"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    /// Brings the first character over and opens its panel ready for typing. Press again to dismiss.
    @objc private func summon() {
        guard let character = characters.first else { return }
        character.noteInteraction()
        character.come(to: NSEvent.mouseLocation.x, world: world)
        bubbles[character.sheet.id]?.hide()
        openWorkspace(character.sheet.id)
    }

    /// Files dropped on a character become attachments for the next message.
    func dropped(_ urls: [URL], at point: CGPoint) {
        let target = characters.first(where: { $0.hitRect.insetBy(dx: -20, dy: -20).contains(point) }) ?? characters.first
        guard let character = target, let panel = panels[character.sheet.id] else { return }
        for url in urls { character.session.attach(url) }
        character.session.pinned = true
        panel.focus()
    }

    private func refreshWorld() {
        if let screen = NSScreen.screens.first {
            world.refresh(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }

    /// Seconds since the person last moved the mouse, clicked, scrolled or typed. Needs no permission.
    private func secondsSinceInput() -> CGFloat {
        let kinds: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .scrollWheel, .keyDown]
        var least = Double.greatestFiniteMagnitude
        for kind in kinds {
            least = min(least, CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: kind))
        }
        return CGFloat(least)
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✦"
        let menu = NSMenu()
        // One line per character; what you can do with it is inside.
        for (i, character) in characters.enumerated() {
            let entry = NSMenuItem(title: character.sheet.name + "  ·  " + AppDelegate.jobName(character.sheet.role), action: nil, keyEquivalent: "")
            let inside = NSMenu()
            let talkItem = NSMenuItem(title: "Talk", action: #selector(talk(_:)), keyEquivalent: "")
            talkItem.target = self
            talkItem.tag = i
            inside.addItem(talkItem)
            if character.sheet.harness != nil && AppDelegate.hasPlace(character.sheet.role) {
                let openItem = NSMenuItem(title: "Open the " + AppDelegate.placeName(character.sheet.role), action: #selector(openWorkspaceFromMenu(_:)), keyEquivalent: "")
                openItem.target = self
                openItem.tag = i
                inside.addItem(openItem)
            }
            entry.submenu = inside
            menu.addItem(entry)
        }
        menu.addItem(NSMenuItem.separator())
        let summonItem = NSMenuItem(title: "Summon (Control-Option-Space)", action: #selector(summon), keyEquivalent: "")
        summonItem.target = self
        menu.addItem(summonItem)
        let backItem = NSMenuItem(title: "Bring everyone back on stage", action: #selector(bringBack), keyEquivalent: "")
        backItem.target = self
        menu.addItem(backItem)
        let quietItem = NSMenuItem(title: "Quiet mode", action: #selector(toggleQuiet(_:)), keyEquivalent: "")
        quietItem.target = self
        menu.addItem(quietItem)
        let playItem = NSMenuItem(title: "Play Orange Smash", action: #selector(playFromMenu), keyEquivalent: "")
        playItem.target = self
        menu.addItem(playItem)
        let makeItem = NSMenuItem(title: "Make a Spryt…", action: #selector(openMaker), keyEquivalent: "")
        makeItem.target = self
        menu.addItem(makeItem)
        menu.addItem(NSMenuItem.separator())

        // Everything you set once and leave alone lives in here.
        let settingsEntry = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settings = NSMenu()
        let claudeItem = NSMenuItem(title: "New Spryts use Claude Code", action: #selector(chooseEngine(_:)), keyEquivalent: "")
        claudeItem.target = self
        claudeItem.tag = 0
        claudeItem.state = Engine.current == "grok" ? .off : .on
        settings.addItem(claudeItem)
        let grokItem = NSMenuItem(title: "New Spryts use Grok", action: #selector(chooseEngine(_:)), keyEquivalent: "")
        grokItem.target = self
        grokItem.tag = 1
        grokItem.state = Engine.current == "grok" ? .on : .off
        settings.addItem(grokItem)
        engineItems = [claudeItem, grokItem]
        let connectItem = NSMenuItem(title: "Connect in browser…", action: #selector(connectClaude), keyEquivalent: "")
        connectItem.target = self
        settings.addItem(connectItem)
        settings.addItem(NSMenuItem.separator())
        let speakItem = NSMenuItem(title: "Let them speak first", action: #selector(toggleSpeakFirst(_:)), keyEquivalent: "")
        speakItem.target = self
        speakItem.state = .on
        settings.addItem(speakItem)
        if characters.contains(where: { ($0.sheet.role ?? "generalist") == "generalist" && $0.sheet.harness != nil }) {
            let briefItem = NSMenuItem(title: "Morning brief and end-of-day wrap", action: #selector(toggleBriefings(_:)), keyEquivalent: "")
            briefItem.target = self
            briefItem.state = Briefings.enabled ? .on : .off
            settings.addItem(briefItem)
        }
        settings.addItem(NSMenuItem.separator())
        let resetItem = NSMenuItem(title: "Reset \"Always allow\" choices", action: #selector(resetAlwaysAllow), keyEquivalent: "")
        resetItem.target = self
        settings.addItem(resetItem)
        let forgetItem = NSMenuItem(title: "Forget chats and memories", action: #selector(forgetAll), keyEquivalent: "")
        forgetItem.target = self
        settings.addItem(forgetItem)
        settingsEntry.submenu = settings
        menu.addItem(settingsEntry)
        let quit = NSMenuItem(title: "Quit Spryts", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func talk(_ sender: NSMenuItem) {
        guard sender.tag >= 0 && sender.tag < characters.count else { return }
        let character = characters[sender.tag]
        character.session.pinned = true
        panels[character.sheet.id]?.show()
    }

    @objc private func toggleSpeakFirst(_ sender: NSMenuItem) {
        speakFirst.toggle()
        sender.state = speakFirst ? .on : .off
    }

    @objc private func toggleBriefings(_ sender: NSMenuItem) {
        Briefings.enabled.toggle()
        sender.state = Briefings.enabled ? .on : .off
    }

    /// The chief of staff's morning brief or end-of-day wrap, once each a day, when the person is at the Mac.
    private func briefIfDue() {
        guard let chief = characters.first(where: { ($0.sheet.role ?? "generalist") == "generalist" && $0.sheet.harness != nil }),
              !chief.session.busy, !chief.isOffstage, let due = Briefings.due() else { return }
        Briefings.mark(due.key)
        sinceRemark = 0
        chief.session.onReply = { [weak chief] text in
            guard let chief else { return }
            let first = text.split(separator: "\n").first.map(String.init) ?? ""
            chief.pendingSpeech = first.count > 140 ? String(first.prefix(140)) + "…" : first
        }
        chief.session.ask(display: due.display, prompt: due.prompt)
    }

    /// Deliver work once, retain its status, and return a receipt without starting another agent turn.
    private func deliverHandoffs() {
        let team = TeamCoordinator.shared
        team.refresh()
        func character(_ query: String) -> SprytCharacter? {
            characters.first { $0.sheet.id.lowercased() == query.lowercased()
                || ($0.sheet.role ?? "generalist") == query.lowercased()
                || $0.sheet.name.lowercased() == query.lowercased() }
        }
        func canWork(_ spryt: SprytCharacter) -> Bool {
            spryt.sheet.harness != nil && Handoffs.allowedRoles.contains(spryt.sheet.role ?? "generalist")
        }

        // Report both successful and unsuccessful turns. A report never grants permission or sends
        // another prompt, and it waits for the source's current work rather than interrupting it.
        for job in team.jobs where job.status.isTerminal && job.receiptDeliveredAt == nil {
            guard let source = character(job.from), canWork(source), !source.session.busy else { continue }
            let report = (job.toName ?? job.to) + " · " + job.status.label + "\n"
                + String(job.task.prefix(240)) + "\n\n" + (job.result ?? job.detail ?? "No written report.")
            if !source.session.messages.contains(where: { $0.role == "assistant" && $0.text == report }) {
                source.session.messages.append(ChatMessage(role: "assistant", text: report))
                source.session.save()
            }
            team.markReceiptDelivered(job.id)
        }

        for job in team.jobs.sorted(by: { $0.createdAt < $1.createdAt }) {
            if job.status == .running || job.status == .waitingApproval {
                if let target = character(job.to), target.session.activeTeamJobID == job.id {
                    team.update(job.id, status: target.session.approval == nil ? .running : .waitingApproval,
                                detail: target.session.approval == nil ? nil : "Waiting for your approval in " + target.sheet.name + ".")
                }
                continue
            }
            guard job.status == .queued || job.status == .needsAttention else { continue }
            guard let source = character(job.from), canWork(source) else {
                team.update(job.id, status: .failed, detail: "The sending specialist is unavailable. No work was started.")
                continue
            }
            guard let target = character(job.to), canWork(target) else {
                team.update(job.id, status: .failed, detail: "The requested specialist is unavailable. No work was started.")
                continue
            }
            guard source.sheet.id != target.sheet.id else {
                team.update(job.id, status: .failed, detail: "A specialist cannot hand a task to itself. No work was started.")
                continue
            }
            if target.session.busy { continue }
            guard target.session.harnessBinary() != nil else {
                team.update(job.id, status: .needsAttention, detail: "Connect an agent engine for " + target.sheet.name + " to start this task.")
                continue
            }
            if target.sheet.role == "coder" {
                guard let folder = target.session.projectFolder else {
                    team.update(job.id, status: .needsAttention, detail: "Choose a project in " + target.sheet.name + "'s workspace to start this task.")
                    continue
                }
                if let expected = job.projectFolder,
                   URL(fileURLWithPath: expected).standardizedFileURL != folder.standardizedFileURL {
                    team.update(job.id, status: .needsAttention, detail: "This task belongs to " + expected + ". Choose that project in " + target.sheet.name + "'s workspace.")
                    continue
                }
            }
            team.resolve(job.id, fromName: source.sheet.name, toName: target.sheet.name,
                         projectFolder: job.projectFolder ?? target.session.projectFolder?.path)
            guard team.update(job.id, status: .running) else { continue }
            target.session.activeTeamJobID = job.id
            target.wake()
            if target.isOffstage { target.returnToStage(world: world, others: characters) }
            target.pendingSpeech = "Got a task from \(source.sheet.name). On it."
            let context = "\n\n(This task was handed over by \(source.sheet.name) on the person's behalf. "
                + "Keep the same scope and approval requirements. Work only in your assigned project; "
                + "if the intended project or outcome is unclear, report the blocker before changing anything. "
                + "Do not hand this task to another character. End with an honest report of what changed, "
                + "what you verified, and any unresolved blocker; the app returns that report to the sender.)"
            target.session.ask(display: "From \(source.sheet.name): " + job.task, prompt: job.task + context) { [weak target] outcome in
                target?.session.activeTeamJobID = nil
                team.finish(job.id, outcome: outcome)
            }
        }
    }

    @objc private func toggleQuiet(_ sender: NSMenuItem) {
        quiet.toggle()
        sender.state = quiet ? .on : .off
    }

    // MARK: Games

    /// A default for new characters. Existing characters keep their own engine.
    @objc private func chooseEngine(_ sender: NSMenuItem) {
        let wanted = sender.tag == 1 ? "grok" : "claude"
        if wanted == Engine.current { return }
        Engine.current = wanted
        for (index, item) in engineItems.enumerated() { item.state = index == sender.tag ? .on : .off }
        Connector.shared.refresh()
    }

    @objc private func connectClaude() {
        Connector.shared.connect()
    }

    @objc private func playFromMenu() {
        if let first = characters.first { startGame(first.sheet.id) }
    }

    /// Starts Orange Smash with this character doing the throwing.
    func startGame(_ id: String) {
        guard let character = characters.first(where: { $0.sheet.id == id }) else { return }
        endGame()
        if character.isOffstage { character.returnToStage(world: world, others: characters) }
        character.wake()
        let newGame = OrangeSmash(host: character, stage: scene.rootNode)
        newGame.state.onEnd = { [weak self] in
            Task { @MainActor [weak self] in self?.endGame() }
        }
        newGame.state.onAgain = { [weak self] in
            Task { @MainActor [weak self] in self?.game?.restart() }
        }
        game = newGame
        let scoreboard = GameHUDController(state: newGame.state, tint: NSColor(hex: character.sheet.look.body))
        scoreboard.show()
        hud = scoreboard
    }

    /// Starts one of Joy's games over the desktop. She watches from the stage.
    func startArcade(_ raw: String) {
        guard let which = ArcadeGame(rawValue: raw) else { return }
        endGame()
        let joy = characters.first(where: { $0.sheet.role == "gamer" })
        if let joy {
            // Her own windows step aside so the level is the person's desktop, not hers.
            workspaces[joy.sheet.id]?.close()
            if joy.isOffstage { joy.returnToStage(world: world, others: characters) }
        }
        for panel in panels.values { panel.hide() }
        arcade.onClosed = { ArcadeScores.shared.reload() }
        arcade.start(which, host: joy)
    }

    func endGame() {
        arcade.stop()
        game?.stop()
        game = nil
        hud?.close()
        hud = nil
    }

    @objc private func bringBack() {
        for character in characters { character.returnToStage(world: world, others: characters) }
    }

    /// Goes back to asking: clears everything saved with the "Always allow" button, for every character.
    @objc private func resetAlwaysAllow() {
        for character in characters { character.session.alwaysGrants = [] }
    }

    @objc private func forgetAll() {
        for character in characters { character.session.forget() }
    }

    @objc private func openMaker() {
        if maker == nil {
            maker = SprytMakerController(onRestart: { [weak self] in
                Task { @MainActor [weak self] in self?.restart() }
            })
        }
        maker?.show()
    }

    /// Starts a fresh copy of the app and closes this one, so a new or changed Spryt walks on.
    private func restart() {
        restartRequested = true
        NSApp.terminate(nil)
    }

    private func launchReplacement() {
        guard let path = Bundle.main.executablePath else { return }
        // A short pause lets this copy finish closing before the new one puts its characters on screen.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "sleep 0.6; exec \"$0\"", path]
        launcher.environment = ProcessInfo.processInfo.environment
        launcher.currentDirectoryURL = Config.home
        do {
            try launcher.run()
        } catch {
            Harness.log("restart failed: " + String(error.localizedDescription.prefix(120)))
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func nudge(_ kind: Nudge, from character: SprytCharacter?) {
        guard let character, !character.session.busy else { return }
        sinceRemark = 0
        character.session.speakUp(kind)
    }

    // MARK: Frame loop

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - last, 0.05))
        last = now
        uptime += dt
        sinceRemark += dt

        if let waiting = pendingClick {
            pendingClickTime -= dt
            if pendingClickTime <= 0 {
                pendingClick = nil
                if let drop = weatherDrops[waiting.sheet.id] {
                    // The forecaster's click shows the real sky; its room opens from the popup or the ✦ menu.
                    drop.toggle()
                } else {
                    openWorkspace(waiting.sheet.id)
                }
            }
        }

        let mouse = NSEvent.mouseLocation
        var returned = false
        var returnedAfter: CGFloat = 0

        worldClock += dt
        if worldClock > 0.25 {
            worldClock = 0
            var own: Set<Int> = []
            for character in characters {
                if let controller = workspaces[character.sheet.id], controller.isOpen, controller.tethers {
                    own.insert(controller.number)
                    character.homePlatform = controller.number
                    character.perched = controller.isKey
                } else {
                    character.homePlatform = nil
                    character.perched = false
                }
            }
            world.ownWindows = own
            refreshWorld()

            // Permission requests from running agents: route each to its character.
            for item in Harness.newRequests(seen: &seenRequests) {
                let owner = characters.first(where: { $0.session.harnessSession == item.sessionID })
                    ?? characters.first(where: { $0.session.process != nil })
                if let owner {
                    owner.session.request(item)
                } else {
                    Harness.answer(item.id, allow: false)
                }
            }

            deliverHandoffs()

            // Look at the real sky again every ten minutes; the service itself only fetches every half hour.
            weatherClock += 0.25
            if weatherClock > 600 {
                weatherClock = 0
                for drop in weatherDrops.values { drop.keepFresh() }
            }

            idleSeconds = secondsSinceInput()
            let hour = Calendar.current.component(.hour, from: Date())
            night = hour >= 22 || hour < 6
            if idleSeconds > 120 {
                // The moment they step away, remember what was open, for "Where was I?" later.
                if !isAway { FocusKeeper.shared.snapshotAway() }
                isAway = true
                awayFor = idleSeconds
            } else if isAway && idleSeconds < 3 {
                isAway = false
                returned = true
                returnedAfter = awayFor
            }
            if idleSeconds > 180 { activeStreak = 0 }
        }
        if idleSeconds < 60 { activeStreak += dt }

        // One nearby character acknowledges a return; the others simply wake up.
        let returnGreeter = returned && !quiet ? characters.filter { $0.canWelcomeBack }.min(by: {
            hypot($0.hitRect.midX - mouse.x, $0.hitRect.midY - mouse.y)
                < hypot($1.hitRect.midX - mouse.x, $1.hitRect.midY - mouse.y)
        }) : nil

        // Speaking first: a hello, a welcome back, a nudge after a long stretch. Never more often than the gaps below.
        if speakFirst && !quiet {
            if !saidHello && uptime > 3 {
                saidHello = true
                nudge(.hello, from: characters.first)
            } else if returned && returnedAfter > 180 && sinceRemark > 180 {
                nudge(.back(minutes: Int(returnedAfter / 60)), from: returnGreeter)
            } else if uptime > 30 && idleSeconds < 20 && sinceRemark > 90 && Briefings.due() != nil {
                briefIfDue()
            } else if activeStreak > 50 * 60 && sinceRemark > 480 {
                let minutes = Int(activeStreak / 60)
                activeStreak = 0
                nudge(.breakTime(minutes: minutes), from: characters.randomElement())
            }
        }

        let presence = Presence(idle: idleSeconds, returned: returned, night: night, greeterID: returnGreeter?.sheet.id)
        var overAny = false
        for character in characters {
            let id = character.sheet.id
            guard let panel = panels[id] else { continue }
            let over = grabbed == nil && character.puppet == nil && character.hitRect.contains(mouse)
            if over { overAny = true }
            // A character in the wings takes clicks but doesn't open its popup on hover.
            hover[id] = over && !character.isOffstage ? (hover[id] ?? 0) + dt : 0
            let engaged = (hover[id] ?? 0) >= 0.3   // long enough that passing over a character doesn't open it

            // One window per character: while its big window is open, the small popup stays away.
            let expanded = workspaces[id]?.isOpen ?? false
            if expanded && panel.isVisible { panel.hide() }
            if (engaged || character.session.approval != nil) && !panel.isVisible && !dragging && !expanded {
                panel.show()
                character.noteInteraction()
                // One popup at a time: opening this one closes the others, unless pinned or waiting on an answer.
                frontPopup = id
                for other in characters where other.sheet.id != id {
                    if other.session.pinned || other.session.approval != nil { continue }
                    if let otherPanel = panels[other.sheet.id], otherPanel.isVisible { otherPanel.hide() }
                }
            }
            if panel.isVisible {
                let inPanel = panel.frame.insetBy(dx: -14, dy: -14).contains(mouse)
                let fresh = Date().timeIntervalSince(character.session.lastEvent) < 15
                // Only the popup you opened last stays up while its character works.
                let front = frontPopup == id
                let keep = over || inPanel || character.session.pinned || (character.session.busy && front) || panel.isKey || (fresh && front)
                    || character.session.approval != nil
                if keep {
                    away[id] = 0
                } else {
                    away[id] = (away[id] ?? 0) + dt
                    if (away[id] ?? 0) > 0.7 { panel.hide() }
                }
                panel.follow(anchor: character.hitRect, screen: world.frame)
            }

            character.attention = engaged || panel.isVisible
            character.panelOpen = panel.isVisible
            character.update(dt: dt, world: world, mouse: mouse, quiet: quiet, others: characters, presence: presence)
            character.syncNode(origin: world.frame.origin)

            // A line the character decided to say: show it overhead unless the chat is already open.
            if let bubble = bubbles[id] {
                if let line = character.pendingSpeech {
                    character.pendingSpeech = nil
                    if !panel.isVisible && !expanded { bubble.say(line) }
                }
                if panel.isVisible && bubble.isVisible { bubble.hide() }
                bubble.tick(dt: dt, anchor: character.hitRect, screen: world.frame)
            }
            if let drop = weatherDrops[id] {
                if character.mode == .held || character.mode == .offstage { drop.hide() }
                drop.tick(anchor: character.hitRect, screen: world.frame)
            }
        }
        if let game {
            game.update(dt: dt, frame: world.frame, floorY: world.floorY, mouse: mouse)
            hud?.layout(over: game.state.over)
            if grabbed == nil && game.hovering(mouse) { overAny = true }
        }
        window.ignoresMouseEvents = !(overAny || grabbed != nil)
    }

    // MARK: Click, double-click and drag

    func pointerDown(at point: CGPoint) {
        // While a game is on, anything it throws gets first refusal on a click.
        if let game, game.click(at: point) { return }
        for character in characters.reversed() where character.puppet == nil && character.hitRect.contains(point) {
            if character.isOffstage {
                // Clicking a character in the wings brings it back.
                character.returnToStage(world: world, others: characters)
                break
            }
            grabbed = character
            dragging = false
            downAt = point
            lastDrag = point
            lastDragTime = CACurrentMediaTime()
            dragVelocity = CGVector(dx: 0, dy: 0)
            grabOffset = CGPoint(x: point.x - character.pos.x, y: point.y - character.pos.y)
            break
        }
    }

    func pointerDragged(to point: CGPoint) {
        guard let character = grabbed else { return }
        if !dragging {
            if hypot(point.x - downAt.x, point.y - downAt.y) < 5 { return }
            dragging = true
            panels[character.sheet.id]?.hide()
            bubbles[character.sheet.id]?.hide()
            character.session.pinned = false
            if character.session.busy { character.session.stop() }
            character.beginDrag()
        }
        let now = CACurrentMediaTime()
        let dt = CGFloat(max(now - lastDragTime, 0.001))
        let vx = (point.x - lastDrag.x) / dt
        let vy = (point.y - lastDrag.y) / dt
        dragVelocity = CGVector(dx: dragVelocity.dx * 0.6 + vx * 0.4, dy: dragVelocity.dy * 0.6 + vy * 0.4)
        character.drag(to: CGPoint(x: point.x - grabOffset.x, y: point.y - grabOffset.y), dx: point.x - lastDrag.x)
        lastDrag = point
        lastDragTime = now
    }

    func pointerUp(at point: CGPoint, clicks: Int) {
        guard let character = grabbed else { return }
        if dragging {
            character.endDrag(velocity: dragVelocity)
        } else if clicks >= 2 {
            // A double-click is a poke. Undo the pin change the first click made.
            if pendingClick != nil {
                pendingClick = nil
            } else if clicks == 2 && character.session.onOpenWorkspace == nil {
                character.session.pinned.toggle()
            }
            character.poke()
        } else {
            if character.session.onOpenWorkspace != nil {
                // A click opens the character's own place. It waits a beat in case this is a double-click.
                pendingClick = character
                pendingClickTime = CGFloat(NSEvent.doubleClickInterval) + 0.03
            } else {
                // A plain click pins or unpins the chat.
                character.session.pinned.toggle()
                if character.session.pinned { panels[character.sheet.id]?.show() }
            }
        }
        grabbed = nil
        dragging = false
    }
}
