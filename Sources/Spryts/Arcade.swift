import AppKit
import SpriteKit

// Joy's arcade: classic games played on top of the desktop as it is right now.
// A game is a see-through layer over the screen. It measures the open windows to build its level and draws on top
// of them. It never moves, closes, hides or reads a real window, and Esc always gives the screen straight back.

/// The two games Joy runs.
enum ArcadeGame: String, CaseIterable, Identifiable {
    case climb = "joy-climb"
    case breaker = "joy-breaker"

    var id: String { rawValue }
    var title: String { self == .climb ? "Window Climb" : "Window Breaker" }
    var blurb: String {
        self == .climb
            ? "Your windows are the ledges. Climb to the door at the top, jump the beach balls, grab the coins."
            : "Your windows are the bricks. Keep the ball up and knock every pane out. They all come back."
    }
    var controls: String {
        self == .climb
            ? "← → move · Space jump · ↓ + Space drop · X swing · P pause · Esc quit"
            : "Mouse or ← → move · Space launch · P pause · Esc quit"
    }
    var symbol: String { self == .climb ? "figure.climbing" : "square.grid.3x3.topleft.filled" }
}

/// Things that happen in a game that Joy might react to from the stage.
enum ArcadeEvent {
    case started, hurt, cleared, over(score: Int, best: Bool)
}

@MainActor
enum ArcadeDesk {
    /// The windows on this screen, in the screen's own coordinates (origin at its bottom-left corner).
    /// Positions only: no titles, no contents, so no screen-recording permission is needed.
    static func windows(on screen: NSScreen) -> [DeskWindow] {
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [DeskWindow] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int, pid != myPID,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.1 { continue }
            if r.width < 160 || r.height < 60 { continue }
            // The window list measures from the top-left of the main screen; AppKit from the bottom-left.
            let global = CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
            let local = global.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                .intersection(CGRect(origin: .zero, size: screen.frame.size))
            if local.isNull || local.width < 120 || local.height < 50 { continue }
            out.append(DeskWindow(id: number, rect: local, order: out.count))
            if out.count >= 40 { break }
        }
        return out
    }
}

@MainActor
enum ArcadeArt {
    static let indigo = NSColor(hex: "#3D3A8C")
    static let cream = NSColor(hex: "#FFF1D6")
    static let cherry = NSColor(hex: "#E5263A")
    static let gold = NSColor(hex: "#F2B93B")
    static let ink = NSColor(hex: "#16142B")
    static let font = "Menlo-Bold"

    /// A colour for each window, steady for as long as the window lives.
    static func tint(_ window: Int) -> NSColor {
        let palette = ["#5AC8FA", "#FF9F0A", "#30D158", "#BF5AF2", "#FF6482", "#FFD60A", "#64D2FF", "#AC8E68"]
        return NSColor(hex: palette[abs(window) % palette.count])
    }

    static func box(_ rect: CGRect, _ color: NSColor, corner: CGFloat = 0) -> SKShapeNode {
        let node = SKShapeNode(rect: rect, cornerRadius: corner)
        node.fillColor = color
        node.strokeColor = .clear
        node.lineWidth = 0
        node.isAntialiased = corner > 0
        return node
    }

    static func label(_ text: String, size: CGFloat, color: NSColor = .white) -> SKLabelNode {
        let node = SKLabelNode(fontNamed: font)
        node.text = text
        node.fontSize = size
        node.fontColor = color
        node.verticalAlignmentMode = .center
        node.horizontalAlignmentMode = .center
        return node
    }

    /// A small drawn Joy, used only when the real one is not on the stage (the checks). Feet at the origin: indigo tunic, cream face, gold boots and belt,
    /// and the joystick she carries like a sword, its cherry-red ball over her shoulder.
    static func joy() -> SKNode {
        let root = SKNode()
        let stick = SKNode()
        stick.name = "stick"
        stick.position = CGPoint(x: -7, y: 22)
        stick.zRotation = 0.5
        stick.addChild(box(CGRect(x: -1.5, y: 0, width: 3, height: 22), ink))
        let ball = SKShapeNode(circleOfRadius: 5.5)
        ball.fillColor = cherry
        ball.strokeColor = .clear
        ball.position = CGPoint(x: 0, y: 25)
        stick.addChild(ball)
        root.addChild(stick)

        let bootL = box(CGRect(x: -9, y: 0, width: 8, height: 6), gold, corner: 2)
        bootL.name = "bootL"
        let bootR = box(CGRect(x: 1, y: 0, width: 8, height: 6), gold, corner: 2)
        bootR.name = "bootR"
        root.addChild(bootL)
        root.addChild(bootR)
        root.addChild(box(CGRect(x: -11, y: 5, width: 22, height: 20), indigo, corner: 6))
        root.addChild(box(CGRect(x: -11, y: 10, width: 22, height: 3), gold))
        let cap = SKShapeNode(circleOfRadius: 12.5)
        cap.fillColor = indigo
        cap.strokeColor = .clear
        cap.position = CGPoint(x: 0, y: 35)
        root.addChild(cap)
        let face = SKShapeNode(circleOfRadius: 10)
        face.fillColor = cream
        face.strokeColor = .clear
        face.position = CGPoint(x: 1.5, y: 33)
        root.addChild(face)
        for x in [CGFloat(-1.5), CGFloat(5.5)] {
            let eye = SKShapeNode(circleOfRadius: 1.8)
            eye.fillColor = ink
            eye.strokeColor = .clear
            eye.position = CGPoint(x: x, y: 34)
            root.addChild(eye)
        }
        return root
    }
}

// MARK: - What every game shares

/// A game layer: the dimmed desktop, window outlines, the scoreboard, keys, pause and game over.
class ArcadeScene: SKScene {
    let game: ArcadeGame
    let desk: [DeskWindow]
    let field: CGRect
    let floorY: CGFloat
    let hostName: String

    var score = 0
    var lives = 3
    var stage = 1
    var keys: Set<UInt16> = []
    var pressed: Set<UInt16> = []
    private(set) var over = false
    private(set) var halted = false
    var onLeave: (() -> Void)?
    var onEvent: ((ArcadeEvent) -> Void)?
    /// How tall the player is. The real Joy is about a hundred points; the stand-in sprite is smaller.
    let hero: CGFloat
    /// True when nobody real is playing (the checks): a small drawn Joy stands in.
    let standIn: Bool
    /// What the real Joy should be doing this frame. She is the player: the stage draws her from this.
    var puppet: ArcadePuppet?
    var onPuppet: ((ArcadePuppet?) -> Void)?

    let world = SKNode()                 // everything that belongs to the level
    private let scoreLabel = ArcadeArt.label("", size: 15)
    private let hintLabel = ArcadeArt.label("", size: 12, color: NSColor.white.withAlphaComponent(0.75))
    private let banner = SKNode()
    private var lastTime: TimeInterval = 0
    private var best = 0
    private var shownScore = -1
    private var shownLives = -1
    private var shownStage = -1

    enum Key {
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        static let space: UInt16 = 49, escape: UInt16 = 53, enter: UInt16 = 36
        static let a: UInt16 = 0, d: UInt16 = 2, w: UInt16 = 13, s: UInt16 = 1
        static let x: UInt16 = 7, f: UInt16 = 3, p: UInt16 = 35, m: UInt16 = 46
    }

    init(game: ArcadeGame, desk: [DeskWindow], size: CGSize, floorY: CGFloat, hostName: String, hero: CGFloat? = nil) {
        self.hero = hero ?? 46
        self.standIn = hero == nil
        self.game = game
        self.desk = desk
        self.field = CGRect(origin: .zero, size: size)
        self.floorY = floorY
        self.hostName = hostName
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = .clear
        best = Leaderboard.best(game.rawValue)
    }

    required init?(coder aDecoder: NSCoder) { return nil }

    override func didMove(to view: SKView) {
        // Dim the desktop a little so the game reads, and trace each window so the level is plain to see.
        let shade = ArcadeArt.box(field, NSColor.black.withAlphaComponent(0.38))
        shade.zPosition = -20
        addChild(shade)
        for window in desk {
            let outline = SKShapeNode(rect: window.rect.insetBy(dx: 1, dy: 1), cornerRadius: 10)
            outline.fillColor = .clear
            outline.strokeColor = ArcadeArt.tint(window.id).withAlphaComponent(0.35)
            outline.lineWidth = 1.5
            outline.zPosition = -10
            addChild(outline)
        }
        addChild(world)

        let bar = ArcadeArt.box(CGRect(x: -330, y: -19, width: 660, height: 38), ArcadeArt.ink.withAlphaComponent(0.88), corner: 19)
        bar.strokeColor = ArcadeArt.gold.withAlphaComponent(0.8)
        bar.lineWidth = 1.5
        bar.position = CGPoint(x: field.midX, y: field.maxY - 60)
        bar.zPosition = 50
        bar.addChild(scoreLabel)
        addChild(bar)
        hintLabel.text = game.controls
        hintLabel.position = CGPoint(x: field.midX, y: floorY + 16)
        hintLabel.zPosition = 50
        addChild(hintLabel)
        // The keys are a reminder, not furniture: they fade once the game is under way, and Pause shows them again.
        hintLabel.run(.sequence([.wait(forDuration: 7), .fadeOut(withDuration: 1)]))
        banner.zPosition = 60
        addChild(banner)

        begin()
        refreshBar()
        onEvent?(.started)
    }

    // MARK: For each game to fill in

    func begin() {}
    func step(_ dt: CGFloat) {}
    func restart() {}

    // MARK: Score, sound, words

    func sound(_ name: String, volume: Float = 0.35) {
        if !UserDefaults.standard.bool(forKey: "gameMuted") { GameSound.play(name, volume: volume) }
    }

    private func refreshBar() {
        if score == shownScore && lives == shownLives && stage == shownStage { return }
        shownScore = score
        shownLives = lives
        shownStage = stage
        let hearts = String(repeating: "♥", count: max(0, lives))
        scoreLabel.text = "\(game.title.uppercased())  \(String(format: "%06d", score))  \(hearts)  LEVEL \(stage)  BEST \(String(format: "%06d", max(best, score)))"
    }

    /// Words that float up from a spot and fade: "+100", "WINDOW CLEARED".
    func pop(_ text: String, at point: CGPoint, color: NSColor? = nil, size: CGFloat = 16) {
        let label = ArcadeArt.label(text, size: size, color: color ?? ArcadeArt.gold)
        label.position = point
        label.zPosition = 40
        world.addChild(label)
        label.run(.sequence([.group([.moveBy(x: 0, y: 46, duration: 0.8), .sequence([.wait(forDuration: 0.4), .fadeOut(withDuration: 0.4)])]),
                             .removeFromParent()]))
    }

    /// A few specks flying out from a point.
    func burst(at point: CGPoint, color: NSColor, count: Int = 8) {
        for _ in 0..<count {
            let bit = ArcadeArt.box(CGRect(x: -3, y: -3, width: 6, height: 6), color)
            bit.position = point
            bit.zPosition = 30
            world.addChild(bit)
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let far = CGFloat.random(in: 30...90)
            bit.run(.sequence([.group([.moveBy(x: cos(angle) * far, y: sin(angle) * far - 30, duration: 0.5),
                                       .fadeOut(withDuration: 0.5), .rotate(byAngle: 4, duration: 0.5)]),
                               .removeFromParent()]))
        }
    }

    /// A message across the middle of the screen. Empty lines clear it.
    func show(_ lines: [String]) {
        banner.removeAllChildren()
        if lines.isEmpty { return }
        let height = CGFloat(lines.count) * 34 + 44
        let card = ArcadeArt.box(CGRect(x: -300, y: -height / 2, width: 600, height: height), ArcadeArt.ink.withAlphaComponent(0.92), corner: 22)
        card.strokeColor = ArcadeArt.gold
        card.lineWidth = 2
        card.position = CGPoint(x: field.midX, y: field.midY + 40)
        for (index, line) in lines.enumerated() {
            let label = ArcadeArt.label(line, size: index == 0 ? 26 : 15, color: index == 0 ? ArcadeArt.gold : .white)
            label.position = CGPoint(x: 0, y: height / 2 - 40 - CGFloat(index) * 34)
            card.addChild(label)
        }
        banner.addChild(card)
    }

    func finish() {
        if over { return }
        over = true
        let isBest = score > best && score > 0
        Leaderboard.add(ScoreEntry(game: game.rawValue, host: hostName, score: score, date: Date(), wave: stage, streak: nil))
        if isBest { best = score }
        sound(isBest ? "Hero" : "Submarine")
        show(["GAME OVER", "Score \(score)" + (isBest ? "   New best!" : "   Best \(best)"), "Return to play again · Esc to leave"])
        onEvent?(.over(score: score, best: isBest))
    }

    func halt(_ stop: Bool) {
        if over || halted == stop { return }
        halted = stop
        show(stop ? ["PAUSED", game.controls, "P or click to carry on"] : [])
    }

    // MARK: The clock and the keys

    override func update(_ currentTime: TimeInterval) {
        let dt = lastTime == 0 ? 1.0 / 60 : min(1.0 / 30, currentTime - lastTime)
        lastTime = currentTime
        if !halted && !over { step(CGFloat(dt)) }
        onPuppet?(puppet)
        pressed.removeAll()
        refreshBar()
    }

    override func keyDown(with event: NSEvent) {
        let code = event.keyCode
        if code == Key.escape {
            onLeave?()
            return
        }
        if event.isARepeat { return }
        keys.insert(code)
        pressed.insert(code)
        if code == Key.p { halt(!halted) }
        if code == Key.m {
            let muted = !UserDefaults.standard.bool(forKey: "gameMuted")
            UserDefaults.standard.set(muted, forKey: "gameMuted")
        }
        if over && code == Key.enter {
            over = false
            score = 0
            lives = 3
            stage = 1
            show([])
            world.removeAllChildren()
            restart()
            onEvent?(.started)
        }
    }

    override func keyUp(with event: NSEvent) {
        keys.remove(event.keyCode)
    }

    override func mouseDown(with event: NSEvent) {
        if halted { halt(false) } else { clicked(at: event.location(in: self)) }
    }

    func clicked(at point: CGPoint) {}
}

// MARK: - Window Climb

/// Climb your own windows to the door at the top. Folders appear as stepping stones where the windows leave a gap.
/// Spinning beach balls roll down from the door: jump them for points or swing the joystick at them.
final class ClimbScene: ArcadeScene {
    private struct Roller {
        let node: SKNode
        var pos: CGPoint
        var vel: CGVector
        var age: CGFloat = 0
        var cleared = false
        var flying = false          // a cursor crossing the screen, not a ball
    }

    private var level = ClimbLevel(ledges: [], start: .zero, door: .zero, coins: [])
    private var player = ArcadeArt.joy()
    private var pos = CGPoint.zero
    private var vel = CGVector.zero
    private var facing: CGFloat = 1
    private var grounded = false
    private var standing = -1
    private var coyote: CGFloat = 0
    private var wantJump: CGFloat = 0
    private var dropping = -1
    private var dropTime: CGFloat = 0
    private var safe: CGFloat = 0
    private var swing: CGFloat = 0
    private var swingRest: CGFloat = 0
    private var stride: CGFloat = 0
    private var rollers: [Roller] = []
    private var coins: [SKNode] = []
    private var door = SKNode()
    private var clock: CGFloat = 0
    private var nextBall: CGFloat = 2
    private var nextCursor: CGFloat = 6
    private var between: CGFloat = 0     // counts down between levels
    private var seed: UInt64 = 0

    private let gravity: CGFloat = 1800
    private let jumpSpeed: CGFloat = 760
    private let runSpeed: CGFloat = 300

    /// Where the climber is, for the checks.
    var probe: (x: CGFloat, y: CGFloat, grounded: Bool, door: CGPoint) { (pos.x, pos.y, grounded, level.door) }

    override func begin() {
        seed = UInt64(Date().timeIntervalSince1970)
        build()
    }

    override func restart() {
        seed &+= 7
        build()
    }

    private func build() {
        world.removeAllChildren()
        rollers = []
        coins = []
        level = ArcadeLevels.climb(windows: desk, frame: field, floorY: floorY, seed: seed &+ UInt64(stage))
        for ledge in level.ledges {
            switch ledge.kind {
            case .floor:
                continue
            case .window(let id):
                // The top edge of a real window, lit up.
                let edge = ArcadeArt.box(CGRect(x: ledge.minX, y: ledge.y - 6, width: ledge.width, height: 7), ArcadeArt.tint(id), corner: 3)
                edge.zPosition = 5
                world.addChild(edge)
            case .folder:
                let body = ArcadeArt.box(CGRect(x: ledge.minX, y: ledge.y - 20, width: ledge.width, height: 20), NSColor(hex: "#4FA8F7"), corner: 5)
                body.zPosition = 5
                let tab = ArcadeArt.box(CGRect(x: ledge.minX + 6, y: ledge.y - 3, width: 34, height: 7), NSColor(hex: "#7CC1FF"), corner: 3)
                tab.zPosition = 4
                world.addChild(tab)
                world.addChild(body)
            }
        }
        for point in level.coins {
            let coin = SKShapeNode(circleOfRadius: 8)
            coin.fillColor = ArcadeArt.gold
            coin.strokeColor = NSColor(hex: "#B07A12")
            coin.lineWidth = 2
            coin.position = point
            coin.zPosition = 8
            coin.run(.repeatForever(.sequence([.scaleX(to: 0.3, duration: 0.35), .scaleX(to: 1, duration: 0.35)])))
            world.addChild(coin)
            coins.append(coin)
        }
        door = SKNode()
        door.position = level.door
        door.zPosition = 6
        // A door she can actually walk through: a little taller than she is.
        let tall = hero * 1.18
        let wide = hero * 0.74
        door.addChild(ArcadeArt.box(CGRect(x: -wide / 2 - 5, y: 0, width: wide + 10, height: tall + 5), ArcadeArt.gold, corner: 10))
        door.addChild(ArcadeArt.box(CGRect(x: -wide / 2, y: 0, width: wide, height: tall), ArcadeArt.ink, corner: 7))
        let knob = SKShapeNode(circleOfRadius: 3)
        knob.fillColor = ArcadeArt.gold
        knob.strokeColor = .clear
        knob.position = CGPoint(x: wide * 0.3, y: tall * 0.45)
        door.addChild(knob)
        world.addChild(door)

        player = ArcadeArt.joy()
        player.zPosition = 20
        player.isHidden = !standIn
        world.addChild(player)
        place()
        clock = 0
        nextBall = 2.5
        nextCursor = 7
        between = 0
        show(stage == 1 ? ["WINDOW CLIMB", "Reach the door at the top of your windows"] : ["LEVEL \(stage)"])
        run(.sequence([.wait(forDuration: 1.6), .run { [weak self] in if self?.halted == false { self?.show([]) } }]))
    }

    private func place() {
        pos = level.start
        vel = .zero
        grounded = true
        standing = 0
        safe = 2
        dropping = -1
    }

    private func spawnBall() {
        let node = SKNode()
        // The spinning wait cursor, as a thing you can jump over.
        let colors = ["#FF453A", "#FFD60A", "#30D158", "#0A84FF"]
        for (index, hex) in colors.enumerated() {
            let wedge = SKShapeNode()
            let path = CGMutablePath()
            path.move(to: .zero)
            path.addArc(center: .zero, radius: 13, startAngle: CGFloat(index) * .pi / 2, endAngle: CGFloat(index + 1) * .pi / 2, clockwise: false)
            path.closeSubpath()
            wedge.path = path
            wedge.fillColor = NSColor(hex: hex)
            wedge.strokeColor = .clear
            node.addChild(wedge)
        }
        node.zPosition = 15
        let direction: CGFloat = pos.x < level.door.x ? -1 : 1
        let speed = min(260, 120 + 16 * CGFloat(stage)) * (Bool.random() ? direction : -direction * 0.9)
        let start = CGPoint(x: level.door.x + (speed > 0 ? 26 : -26), y: level.door.y + 13)
        node.position = start
        world.addChild(node)
        rollers.append(Roller(node: node, pos: start, vel: CGVector(dx: speed, dy: 0)))
    }

    private func spawnCursor() {
        guard let ledge = level.ledges.dropFirst().randomElement() else { return }
        let fromLeft = Bool.random()
        let node = SKShapeNode()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 14, y: 0))
        path.addLine(to: CGPoint(x: -10, y: 9))
        path.addLine(to: CGPoint(x: -5, y: 0))
        path.addLine(to: CGPoint(x: -10, y: -9))
        path.closeSubpath()
        node.path = path
        node.fillColor = .white
        node.strokeColor = ArcadeArt.ink
        node.lineWidth = 1.5
        node.zPosition = 15
        node.xScale = fromLeft ? 1 : -1
        let y = ledge.y + 26
        let start = CGPoint(x: fromLeft ? -30 : field.maxX + 30, y: y)
        node.position = start
        world.addChild(node)
        // A warning at the edge it will come from.
        pop("!", at: CGPoint(x: fromLeft ? 24 : field.maxX - 24, y: y), color: ArcadeArt.cherry, size: 26)
        var roller = Roller(node: node, pos: start, vel: CGVector(dx: (fromLeft ? 1 : -1) * min(520, 300 + 30 * CGFloat(stage)), dy: 0))
        roller.flying = true
        roller.age = -0.8          // it waits a beat after the warning
        rollers.append(roller)
    }

    /// The highest ledge a falling thing lands on between two heights, if any.
    private func landing(x: CGFloat, from oldY: CGFloat, to newY: CGFloat, skipping skipped: Int, margin: CGFloat) -> Int? {
        var found: Int?
        for (index, ledge) in level.ledges.enumerated() where index != skipped {
            if oldY >= ledge.y - 0.5 && newY <= ledge.y && x >= ledge.minX - margin && x <= ledge.maxX + margin {
                if found == nil || ledge.y > level.ledges[found ?? 0].y { found = index }
            }
        }
        return found
    }

    private func hurt() {
        if safe > 0 || between > 0 { return }
        lives -= 1
        sound("Basso", volume: 0.5)
        burst(at: CGPoint(x: pos.x, y: pos.y + hero * 0.5), color: ArcadeArt.cherry, count: 12)
        onEvent?(.hurt)
        for roller in rollers { roller.node.removeFromParent() }
        rollers = []
        if lives <= 0 {
            player.isHidden = true
            puppet = ArcadePuppet(feet: CGPoint(x: pos.x, y: floorY), facing: facing)
            finish()
        } else {
            place()
        }
    }

    override func step(_ dt: CGFloat) {
        if between > 0 {
            between -= dt
            puppet?.cheering = true
            puppet?.speed = 0
            puppet?.airborne = false
            if between <= 0 {
                stage += 1
                build()
            }
            return
        }
        clock += dt
        safe = max(0, safe - dt)
        swing = max(0, swing - dt)
        swingRest = max(0, swingRest - dt)
        dropTime = max(0, dropTime - dt)
        if dropTime <= 0 { dropping = -1 }

        // Running.
        var want: CGFloat = 0
        if keys.contains(Key.left) || keys.contains(Key.a) { want -= 1 }
        if keys.contains(Key.right) || keys.contains(Key.d) { want += 1 }
        if want != 0 { facing = want }
        let quickness: CGFloat = grounded ? 14 : 7
        vel.dx += (want * runSpeed - vel.dx) * min(1, dt * quickness)

        // Jumping, with a little forgiveness either side of the edge and the button.
        if pressed.contains(Key.space) || pressed.contains(Key.up) || pressed.contains(Key.w) { wantJump = 0.12 }
        wantJump = max(0, wantJump - dt)
        coyote = grounded ? 0.09 : max(0, coyote - dt)
        if wantJump > 0 && coyote > 0 {
            let down = keys.contains(Key.down) || keys.contains(Key.s)
            if down && standing > 0 {
                dropping = standing
                dropTime = 0.3
            } else {
                vel.dy = jumpSpeed
                sound("Pop", volume: 0.25)
            }
            wantJump = 0
            coyote = 0
            grounded = false
        }
        let holding = keys.contains(Key.space) || keys.contains(Key.up) || keys.contains(Key.w)
        if !holding && vel.dy > 300 { vel.dy = 300 }       // let go early for a short hop

        vel.dy -= gravity * dt
        let old = pos
        pos.x = min(field.maxX - 16, max(field.minX + 16, pos.x + vel.dx * dt))
        pos.y += vel.dy * dt
        grounded = false
        if vel.dy <= 0, let index = landing(x: pos.x, from: old.y, to: pos.y, skipping: dropping, margin: 7) {
            pos.y = level.ledges[index].y
            vel.dy = 0
            grounded = true
            standing = index
        }

        // The swing of the joystick.
        if (pressed.contains(Key.x) || pressed.contains(Key.f)) && swingRest <= 0 {
            swing = 0.22
            swingRest = 0.5
            sound("Tink", volume: 0.3)
        }

        // Coins.
        for index in coins.indices.reversed() {
            let coin = coins[index]
            if abs(coin.position.x - pos.x) < 14 + hero * 0.22 && abs(coin.position.y - (pos.y + hero * 0.5)) < 12 + hero * 0.5 {
                score += 50
                sound("Tink")
                pop("+50", at: coin.position)
                coin.removeFromParent()
                coins.remove(at: index)
            }
        }

        // Things coming the other way.
        nextBall -= dt
        if nextBall <= 0 && rollers.count < 9 {
            spawnBall()
            nextBall = max(1.3, 3.4 - 0.3 * CGFloat(stage)) * CGFloat.random(in: 0.8...1.25)
        }
        if stage >= 2 {
            nextCursor -= dt
            if nextCursor <= 0 {
                spawnCursor()
                nextCursor = max(2.2, 6.5 - 0.5 * CGFloat(stage)) * CGFloat.random(in: 0.8...1.3)
            }
        }
        var index = rollers.count - 1
        while index >= 0 {
            var roller = rollers[index]
            roller.age += dt
            var gone = false
            if roller.flying {
                if roller.age > 0 { roller.pos.x += roller.vel.dx * dt }
                gone = roller.pos.x < -60 || roller.pos.x > field.maxX + 60
            } else {
                roller.vel.dy -= gravity * dt
                let before = roller.pos
                roller.pos.x += roller.vel.dx * dt
                roller.pos.y += roller.vel.dy * dt
                if roller.vel.dy <= 0, let ledge = landing(x: roller.pos.x, from: before.y - 13, to: roller.pos.y - 13, skipping: -1, margin: 0) {
                    roller.pos.y = level.ledges[ledge].y + 13
                    roller.vel.dy = 0
                }
                let onFloor = roller.pos.y <= floorY + 14
                if roller.pos.x < 14 || roller.pos.x > field.maxX - 14 {
                    if onFloor { gone = true } else { roller.vel.dx = -roller.vel.dx }
                    roller.pos.x = min(field.maxX - 14, max(14, roller.pos.x))
                }
                if roller.age > 30 { gone = true }
                roller.node.zRotation -= roller.vel.dx * dt / 13
            }
            roller.node.position = roller.pos

            let dx = roller.pos.x - pos.x
            let dy = roller.pos.y - (pos.y + hero * 0.45)
            let reach = 40 + hero * 0.55
            if !gone && swing > 0 && dx * facing > -12 && dx * facing < reach && abs(dy) < 22 + hero * 0.45 {
                score += 150
                sound("Glass", volume: 0.3)
                pop("+150", at: roller.pos)
                burst(at: roller.pos, color: roller.flying ? .white : ArcadeArt.tint(Int(roller.pos.x)))
                gone = true
            } else if !gone && abs(dx) < 13 + hero * 0.2 && abs(dy) < 13 + hero * 0.42 {
                hurt()
                return
            } else if !gone && !roller.cleared && !roller.flying && !grounded && abs(dx) < 16 && dy < -(13 + hero * 0.42) && dy > -(110 + hero * 0.5) {
                // Sailing clean over one, the old way.
                roller.cleared = true
                score += 100
                pop("+100", at: CGPoint(x: pos.x, y: pos.y + hero + 16))
                sound("Ping", volume: 0.3)
            }
            if gone {
                roller.node.removeFromParent()
                rollers.remove(at: index)
            } else {
                rollers[index] = roller
            }
            index -= 1
        }

        // The door.
        if grounded && abs(pos.x - level.door.x) < 20 && abs(pos.y - level.door.y) < 6 {
            let bonus = max(0, 3000 - Int(clock * 25)) + lives * 200
            score += bonus
            sound("Hero")
            show(["LEVEL CLEAR", "Bonus \(bonus)"])
            onEvent?(.cleared)
            between = 1.8
            for roller in rollers { roller.node.removeFromParent() }
            rollers = []
        }

        // What the real Joy does on the stage: exactly this.
        puppet = ArcadePuppet(feet: pos, facing: facing, speed: grounded ? vel.dx : 0, airborne: !grounded, rising: vel.dy > 0,
                              swing: swing > 0 ? 1 - swing / 0.22 : 0, blink: safe > 0, carrying: false, cheering: between > 0)

        // The stand-in sprite, when nobody real is playing.
        player.position = pos
        player.xScale = facing
        player.alpha = safe > 0 && Int(clock * 12) % 2 == 0 ? 0.35 : 1
        if grounded && abs(vel.dx) > 30 { stride += dt * 14 } else { stride = 0 }
        player.childNode(withName: "bootL")?.position.y = grounded ? max(0, sin(stride)) * 4 : 3
        player.childNode(withName: "bootR")?.position.y = grounded ? max(0, -sin(stride)) * 4 : 0
        if let stick = player.childNode(withName: "stick") {
            // On her back at rest; swept forward and down in an arc when she swings.
            let sweep = swing > 0 ? 1 - swing / 0.22 : 0
            stick.zRotation = swing > 0 ? -0.4 - 1.9 * sweep : 0.5
            stick.position = swing > 0 ? CGPoint(x: 9, y: 16) : CGPoint(x: -7, y: 22)
        }
    }
}

// MARK: - Window Breaker

/// Your windows, tiled into bricks. Joy carries the paddle. Breaking is pretend: the panes are drawn over the
/// real windows, which are never touched, and every one of them is back the moment the game ends.
final class BreakerScene: ArcadeScene {
    private struct Pane {
        var brick: Brick
        let node: SKShapeNode
    }
    private struct Ball {
        let node: SKShapeNode
        var pos: CGPoint
        var vel: CGVector
        var held = true
    }
    private struct Gift {
        let node: SKNode
        var pos: CGPoint
        let kind: String
    }

    private var panes: [Pane] = []
    private var balls: [Ball] = []
    private var gifts: [Gift] = []
    private var left: [Int: Int] = [:]          // bricks still standing in each window
    private let paddle = SKNode()
    private var paddleBar = SKShapeNode()
    private var paddleX: CGFloat = 0
    private var targetX: CGFloat = 0
    private var width: CGFloat = 130
    private var wide: CGFloat = 0
    private var slow: CGFloat = 0
    private var combo = 0
    private var between: CGFloat = 0
    private let radius: CGFloat = 8

    /// She holds the paddle over her head, so it sits just above her raised hands.
    private var paddleTop: CGFloat { floorY + max(78, hero * 1.1 + 14) }

    /// Where things are, for the checks.
    var probe: (ballX: CGFloat, ballY: CGFloat, paddleX: CGFloat, bricks: Int, balls: Int) {
        (balls.first?.pos.x ?? 0, balls.first?.pos.y ?? 0, paddleX, panes.count, balls.count)
    }
    private var pace: CGFloat { min(820, 500 + 40 * CGFloat(stage - 1)) * (slow > 0 ? 0.62 : 1) }

    override func begin() {
        paddleX = field.midX
        targetX = paddleX
        build()
    }

    override func restart() {
        begin()
    }

    private func build() {
        world.removeAllChildren()
        panes = []
        balls = []
        gifts = []
        left = [:]
        combo = 0
        wide = 0
        slow = 0
        for var brick in ArcadeLevels.bricks(windows: desk, frame: field, floorY: floorY) {
            // Later levels are the same windows, glazed thicker.
            brick.hits = min(3, brick.hits + (stage - 1) / 2)
            let node = SKShapeNode(rect: brick.rect, cornerRadius: 5)
            node.zPosition = 5
            world.addChild(node)
            panes.append(Pane(brick: brick, node: node))
            paint(panes.count - 1)
            left[brick.window, default: 0] += 1
        }
        paddle.removeAllChildren()
        paddle.removeFromParent()
        paddleBar = ArcadeArt.box(CGRect(x: -width / 2, y: -14, width: width, height: 14), ArcadeArt.gold, corner: 7)
        paddle.addChild(paddleBar)
        if standIn {
            let joy = ArcadeArt.joy()
            joy.position = CGPoint(x: 0, y: -14 - 44)
            paddle.addChild(joy)
        }
        paddle.zPosition = 20
        world.addChild(paddle)
        addBall()
        show(stage == 1 ? ["WINDOW BREAKER", "Space or click to launch. Your windows are safe."] : ["LEVEL \(stage)"])
        run(.sequence([.wait(forDuration: 1.8), .run { [weak self] in if self?.halted == false { self?.show([]) } }]))
    }

    private func paint(_ index: Int) {
        let pane = panes[index]
        let color = pane.brick.window == 0 ? ArcadeArt.tint(Int(pane.brick.rect.minY) / 36) : ArcadeArt.tint(pane.brick.window)
        pane.node.fillColor = color.withAlphaComponent(pane.brick.hits >= 3 ? 0.92 : (pane.brick.hits == 2 ? 0.75 : 0.5))
        pane.node.strokeColor = pane.brick.hits >= 2 ? NSColor.white.withAlphaComponent(0.9) : color
        pane.node.lineWidth = pane.brick.hits >= 2 ? 2 : 1
    }

    private func addBall() {
        let node = SKShapeNode(circleOfRadius: radius)
        node.fillColor = ArcadeArt.cherry
        node.strokeColor = .white
        node.lineWidth = 1.5
        node.zPosition = 25
        world.addChild(node)
        balls.append(Ball(node: node, pos: CGPoint(x: paddleX, y: paddleTop + radius), vel: .zero))
    }

    private func launch() {
        for index in balls.indices where balls[index].held {
            balls[index].held = false
            let angle = CGFloat.random(in: -0.5...0.5)
            balls[index].vel = CGVector(dx: sin(angle) * pace, dy: cos(angle) * pace)
            sound("Pop", volume: 0.3)
        }
    }

    override func clicked(at point: CGPoint) {
        launch()
    }

    override func mouseMoved(with event: NSEvent) {
        targetX = event.location(in: self).x
    }

    override func mouseDragged(with event: NSEvent) {
        targetX = event.location(in: self).x
    }

    private func drop(from rect: CGRect) {
        let roll = CGFloat.random(in: 0...1)
        if roll > 0.14 { return }
        let kind = roll < 0.05 ? "wide" : (roll < 0.09 ? "multi" : (roll < 0.125 ? "slow" : "life"))
        let node = SKNode()
        let color = kind == "life" ? ArcadeArt.cherry : (kind == "wide" ? ArcadeArt.gold : (kind == "multi" ? NSColor(hex: "#30D158") : NSColor(hex: "#5AC8FA")))
        node.addChild(ArcadeArt.box(CGRect(x: -14, y: -10, width: 28, height: 20), color, corner: 6))
        node.addChild(ArcadeArt.label(kind == "life" ? "♥" : (kind == "wide" ? "W" : (kind == "multi" ? "3" : "S")), size: 13, color: ArcadeArt.ink))
        node.zPosition = 22
        let start = CGPoint(x: rect.midX, y: rect.midY)
        node.position = start
        world.addChild(node)
        gifts.append(Gift(node: node, pos: start, kind: kind))
    }

    private func take(_ kind: String) {
        sound("Ping")
        switch kind {
        case "wide":
            wide = 12
            pop("WIDE", at: CGPoint(x: paddleX, y: paddleTop + 30))
        case "slow":
            slow = 8
            pop("SLOW", at: CGPoint(x: paddleX, y: paddleTop + 30))
        case "life":
            lives = min(5, lives + 1)
            pop("+1", at: CGPoint(x: paddleX, y: paddleTop + 30), color: ArcadeArt.cherry)
        default:
            guard let first = balls.first(where: { !$0.held }) else { return }
            for turn in [CGFloat(-0.5), CGFloat(0.5)] where balls.count < 6 {
                addBall()
                let last = balls.count - 1
                balls[last].held = false
                balls[last].pos = first.pos
                balls[last].vel = CGVector(dx: first.vel.dx * cos(turn) - first.vel.dy * sin(turn),
                                           dy: first.vel.dx * sin(turn) + first.vel.dy * cos(turn))
            }
            pop("MULTI", at: CGPoint(x: paddleX, y: paddleTop + 30))
        }
    }

    private func strike(_ index: Int) {
        panes[index].brick.hits -= 1
        let pane = panes[index]
        if pane.brick.hits > 0 {
            paint(index)
            sound("Tink", volume: 0.3)
            return
        }
        combo += 1
        let points = 10 * min(10, combo)
        score += points
        sound("Pop", volume: 0.3)
        burst(at: CGPoint(x: pane.brick.rect.midX, y: pane.brick.rect.midY), color: pane.node.fillColor.withAlphaComponent(1), count: 5)
        drop(from: pane.brick.rect)
        pane.node.removeFromParent()
        panes.remove(at: index)
        let remaining = (left[pane.brick.window] ?? 1) - 1
        left[pane.brick.window] = remaining
        if remaining == 0 && pane.brick.window != 0 && !panes.isEmpty {
            score += 200
            sound("Glass", volume: 0.35)
            pop("WINDOW CLEARED +200", at: CGPoint(x: pane.brick.rect.midX, y: pane.brick.rect.midY + 20), size: 18)
        }
    }

    override func step(_ dt: CGFloat) {
        if between > 0 {
            between -= dt
            puppet?.cheering = true
            puppet?.speed = 0
            if between <= 0 {
                stage += 1
                build()
            }
            return
        }
        wide = max(0, wide - dt)
        slow = max(0, slow - dt)
        let wanted: CGFloat = wide > 0 ? 200 : 130
        if wanted != width {
            width = wanted
            paddleBar.removeFromParent()
            paddleBar = ArcadeArt.box(CGRect(x: -width / 2, y: -14, width: width, height: 14), ArcadeArt.gold, corner: 7)
            paddle.addChild(paddleBar)
        }
        if keys.contains(Key.left) || keys.contains(Key.a) { targetX -= 760 * dt }
        if keys.contains(Key.right) || keys.contains(Key.d) { targetX += 760 * dt }
        targetX = min(field.maxX - width / 2 - 6, max(field.minX + width / 2 + 6, targetX))
        let before = paddleX
        paddleX += (targetX - paddleX) * min(1, dt * 20)
        paddle.position = CGPoint(x: paddleX, y: paddleTop)
        let moving = (paddleX - before) / max(dt, 0.001)
        puppet = ArcadePuppet(feet: CGPoint(x: paddleX, y: floorY), facing: moving >= 0 ? 1 : -1, speed: moving,
                              airborne: false, rising: false, swing: 0, blink: false, carrying: true, cheering: false)
        if pressed.contains(Key.space) { launch() }

        let ceiling = field.maxY - 96
        var index = balls.count - 1
        while index >= 0 {
            var ball = balls[index]
            if ball.held {
                ball.pos = CGPoint(x: paddleX, y: paddleTop + radius)
            } else {
                // Keep to the current pace (levels, the slow gift), then move in steps too small to skip a brick.
                let now = max(1, hypot(ball.vel.dx, ball.vel.dy))
                ball.vel = CGVector(dx: ball.vel.dx / now * pace, dy: ball.vel.dy / now * pace)
                let steps = max(1, Int((pace * dt / 5).rounded(.up)))
                let slice = dt / CGFloat(steps)
                var lost = false
                for _ in 0..<steps {
                    ball.pos.x += ball.vel.dx * slice
                    ball.pos.y += ball.vel.dy * slice
                    if ball.pos.x < field.minX + radius + 4 {
                        ball.pos.x = field.minX + radius + 4
                        ball.vel.dx = abs(ball.vel.dx)
                    }
                    if ball.pos.x > field.maxX - radius - 4 {
                        ball.pos.x = field.maxX - radius - 4
                        ball.vel.dx = -abs(ball.vel.dx)
                    }
                    if ball.pos.y > ceiling - radius {
                        ball.pos.y = ceiling - radius
                        ball.vel.dy = -abs(ball.vel.dy)
                    }
                    if ball.vel.dy < 0 && ball.pos.y - radius <= paddleTop && ball.pos.y - radius >= paddleTop - 16
                        && abs(ball.pos.x - paddleX) <= width / 2 + radius {
                        // Where it meets the paddle decides where it goes: the edges send it wide.
                        let offset = max(-1, min(1, (ball.pos.x - paddleX) / (width / 2)))
                        let angle = offset * 1.05
                        ball.vel = CGVector(dx: sin(angle) * pace, dy: cos(angle) * pace)
                        ball.pos.y = paddleTop + radius
                        combo = 0
                        sound("Tink", volume: 0.25)
                    }
                    if let hit = panes.firstIndex(where: { pane in
                        let r = pane.brick.rect
                        let nearX = max(r.minX, min(r.maxX, ball.pos.x))
                        let nearY = max(r.minY, min(r.maxY, ball.pos.y))
                        let dx = ball.pos.x - nearX
                        let dy = ball.pos.y - nearY
                        return dx * dx + dy * dy < radius * radius
                    }) {
                        let r = panes[hit].brick.rect
                        // Bounce off whichever face it came in through.
                        let fromSide = min(abs(ball.pos.x - r.minX), abs(ball.pos.x - r.maxX))
                        let fromEnd = min(abs(ball.pos.y - r.minY), abs(ball.pos.y - r.maxY))
                        let inside = r.contains(ball.pos)
                        let side = (ball.pos.x < r.minX || ball.pos.x > r.maxX) && !(ball.pos.y < r.minY || ball.pos.y > r.maxY)
                        if side || (inside && fromSide < fromEnd) {
                            ball.vel.dx = ball.pos.x < r.midX ? -abs(ball.vel.dx) : abs(ball.vel.dx)
                        } else {
                            ball.vel.dy = ball.pos.y < r.midY ? -abs(ball.vel.dy) : abs(ball.vel.dy)
                        }
                        strike(hit)
                    }
                    if ball.pos.y < floorY + 10 {
                        lost = true
                        break
                    }
                }
                // Never let it settle into a flat line that would take forever to come down.
                if abs(ball.vel.dy) < pace * 0.18 {
                    let sign: CGFloat = ball.vel.dy < 0 ? -1 : 1
                    ball.vel.dy = sign * pace * 0.18
                }
                if lost {
                    ball.node.removeFromParent()
                    balls.remove(at: index)
                    index -= 1
                    continue
                }
            }
            ball.node.position = ball.pos
            balls[index] = ball
            index -= 1
        }

        var giftIndex = gifts.count - 1
        while giftIndex >= 0 {
            gifts[giftIndex].pos.y -= 190 * dt
            gifts[giftIndex].node.position = gifts[giftIndex].pos
            let gift = gifts[giftIndex]
            if abs(gift.pos.y - paddleTop) < 16 && abs(gift.pos.x - paddleX) < width / 2 + 14 {
                gift.node.removeFromParent()
                gifts.remove(at: giftIndex)
                take(gift.kind)
            } else if gift.pos.y < floorY {
                gift.node.removeFromParent()
                gifts.remove(at: giftIndex)
            }
            giftIndex -= 1
        }

        if balls.isEmpty {
            lives -= 1
            combo = 0
            sound("Basso", volume: 0.5)
            onEvent?(.hurt)
            if lives <= 0 { finish() } else { addBall() }
        } else if panes.isEmpty {
            let bonus = 500 + 100 * lives
            score += bonus
            sound("Hero")
            show(["ALL CLEAR", "Bonus \(bonus). Your windows are fine."])
            onEvent?(.cleared)
            between = 2
        }
    }
}

// MARK: - Putting a game on the screen

/// A borderless window that can take the keyboard, so the arrow keys reach the game.
private final class ArcadeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class ArcadeController: NSObject, NSWindowDelegate {
    private var window: ArcadeWindow?
    private var scene: ArcadeScene?
    private weak var host: SprytCharacter?
    private(set) var playing: ArcadeGame?
    /// Called when a game closes, so scores on show can refresh.
    var onClosed: (() -> Void)?

    func start(_ game: ArcadeGame, host: SprytCharacter?) {
        stop()
        guard let screen = NSScreen.screens.first else { return }
        let desk = ArcadeDesk.windows(on: screen)
        let size = screen.frame.size
        let floor = screen.visibleFrame.minY - screen.frame.minY
        let name = host?.sheet.name ?? "Joy"
        // With Joy on the stage she is the player, at her real size. Without her, a drawn stand-in plays.
        let hero: CGFloat? = host.map { $0.sheet.look.height }
        let made: ArcadeScene = game == .climb
            ? ClimbScene(game: game, desk: desk, size: size, floorY: floor, hostName: name, hero: hero)
            : BreakerScene(game: game, desk: desk, size: size, floorY: floor, hostName: name, hero: hero)
        let corner = screen.frame.origin
        made.onPuppet = { [weak host] act in
            guard var act else { return }
            // The game counts from the corner of its screen; the stage counts from the corner of the desktop.
            act.feet.x += corner.x
            act.feet.y += corner.y
            host?.puppet = act
        }
        made.onLeave = { [weak self] in
            Task { @MainActor [weak self] in self?.stop() }
        }
        made.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.react(to: event) }
        }

        let panel = ArcadeWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        // Above the person's windows, below the Spryts themselves and the menu bar.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        view.presentScene(made)
        panel.contentView = view

        self.host = host
        host?.playing = true
        host?.wake()
        window = panel
        scene = made
        playing = game
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
    }

    func stop() {
        guard let panel = window else { return }
        panel.delegate = nil
        panel.orderOut(nil)
        (panel.contentView as? SKView)?.presentScene(nil)
        window = nil
        scene = nil
        playing = nil
        host?.puppet = nil
        host?.playing = false
        host = nil
        onClosed?()
    }

    /// Joy is the one playing, and she has something to say about how it is going.
    private func react(to event: ArcadeEvent) {
        guard let host else { return }
        switch event {
        case .started:
            host.pendingSpeech = ["Your desktop, my rules. Go!", "Player one, ready!", "Let's see those reflexes."].randomElement()
        case .hurt:
            host.pendingSpeech = ["Ow. Okay.", "That one's on me.", "Shake it off."].randomElement()
        case .cleared:
            host.pendingSpeech = ["Clean run!", "That's a clear. Next one's meaner.", "Textbook."].randomElement()
        case .over(let score, let best):
            host.pendingSpeech = best ? "New best: \(score). Put that on the cabinet." : "\(score). Good run. Again?"
        }
    }

    // Clicking another app's window pauses the game instead of leaving it running unseen.
    func windowDidResignKey(_ notification: Notification) {
        scene?.halt(true)
    }
}
