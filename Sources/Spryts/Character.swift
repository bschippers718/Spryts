import AppKit
import SceneKit

enum Mode {
    case idle, walking, skidding, crouching, jumping, falling, landing, held
    case sitting, napping, dizzy, dancing, cartwheel
    case offstage      // thrown off the side of the screen; peeking back in until clicked
}
enum Activity { case none, thinking, talking, tool, error, waiting, asking }
enum Gait { case walk, run, skip, sneak }
private enum Errand { case none, greet, tag, cursor, flee, lap }

/// A short-lived speck: dust kicked up by feet, or a sparkle.
private struct Puff {
    let node: SCNNode
    var vx: CGFloat
    var vy: CGFloat
    var life: CGFloat
    let total: CGFloat
    let grow: CGFloat
    let alpha: CGFloat
}

/// What the app knows about the person right now.
struct Presence {
    var idle: CGFloat       // seconds since they last touched the mouse or keyboard
    var returned: Bool      // true for one frame when they come back from being away
    var night: Bool
}

private func clamp(_ x: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    min(max(x, lo), hi)
}

/// Wraps an angle into -pi...pi so a finished flip settles the short way round.
private func wrapAngle(_ a: CGFloat) -> CGFloat {
    var x = a.truncatingRemainder(dividingBy: 2 * CGFloat.pi)
    if x > CGFloat.pi { x -= 2 * CGFloat.pi }
    if x < -CGFloat.pi { x += 2 * CGFloat.pi }
    return x
}

/// One character: where it is, what it is doing, and how the chat it owns is driving it.
final class SprytCharacter {
    let sheet: CharacterSheet
    let body: CharacterBody
    let node = SCNNode()
    let session: ChatSession
    private let shadow: SCNNode
    private let emote = SCNNode()
    private let zIndex: CGFloat

    var pos: CGPoint
    var attention = false
    var panelOpen = false
    var pendingSpeech: String?
    /// True while this character is running a game: it stays put, stays awake, and throws things.
    var playing = false
    /// When set, the character lives on this surface: its own workspace window.
    var homePlatform: Int?
    /// True while the person is working in this character's workspace window.
    var perched = false
    private var hobbyTime: CGFloat = 0
    /// Seconds since this character last went anywhere. Resting is the default state.
    private var sinceMoved: CGFloat = 30
    // Off stage
    private var offSide: CGFloat = 1          // which edge it went off: -1 left, 1 right
    private var peekOut: CGFloat = 0          // 0 tucked behind the edge ... 1 leaning right out
    private var peekGoal: CGFloat = 0
    private var peekTimer: CGFloat = 1.5
    private var offWave: CGFloat = 0
    private var thrown = false
    private var stageFrame = CGRect.zero
    /// The programmer is studious and calm; the generalist is playful. The role decides which.
    private var isCoder: Bool { sheet.role == "coder" }
    private var isWriter: Bool { sheet.role == "writer" }
    /// The specialists are absorbed in their craft; only the generalist plays.
    private var isSpecialist: Bool { isCoder || isWriter }
    private(set) var petting = false
    private(set) var mode: Mode = .falling
    private(set) var activity: Activity = .none
    private(set) var mood = "calm"

    private var vel = CGVector(dx: 0, dy: 0)
    private var platformID = 0
    private var modeTime: CGFloat = 0
    private var activityTime: CGFloat = 0
    private var gesture = "none"
    private var gestureTime: CGFloat = 0
    private var t = CGFloat.random(in: 0...10)
    private var facing: CGFloat = Bool.random() ? 1 : -1
    private var phase: CGFloat = 0
    private var idleFor: CGFloat = 1.5
    private var walkTarget: CGFloat = 0
    private var gait: Gait = .walk
    private var errand: Errand = .none
    private weak var buddy: SprytCharacter?
    private var chaseTime: CGFloat = 0
    private var skidSpeed: CGFloat = 0
    private var sitFor: CGFloat = 0
    private var danceFor: CGFloat = 0
    private var danceSpinAt: CGFloat = 0
    private var danceSpun = false
    // Three tiers of movement, so there is always something small going on and the big moments stay rare.
    private var micro = 0                               // small gestures: every couple of seconds
    private var microTime: CGFloat = 0
    private var microDur: CGFloat = 1
    private var microAmp: CGFloat = 1
    private var microSide: CGFloat = 1
    private var nextMicro = CGFloat.random(in: 1...3)
    private var microHistory: [Int] = []
    private var fidget = 0                              // medium gestures: about once a minute
    private var fidgetTime: CGFloat = 0
    private var fidgetDur: CGFloat = 2.2
    private var fidgetAmp: CGFloat = 1
    private var nextFidget = CGFloat.random(in: 12...30)
    private var fidgetHistory: [Int] = []
    private var sneezed = false
    private var nextBig = CGFloat.random(in: 180...420)  // set pieces: a few times an hour
    private var bigHistory: [Int] = []
    private var lapsLeft = 0
    private var lapHome: CGFloat = 0
    private var backward = false
    private var comboHops = 0
    private var dizzyAfterSpin = false
    // What the agent is doing right now, and how the character shows it.
    private var workKind = "run"
    private var workTime: CGFloat = 0
    private var smokeTime: CGFloat = 0
    private var flashTime: CGFloat = 0
    private var tapWhenThere = false
    private weak var lastWorld: World?
    private var blink: CGFloat = 0
    private var nextBlink = CGFloat.random(in: 1...4)
    private var sinceInteraction: CGFloat = 0
    private var jumpFrom = CGPoint.zero
    private var jumpTo = CGPoint.zero
    private var jumpDur: CGFloat = 0.6     // time in the air, worked out from gravity
    private var jumpVY: CGFloat = 0        // upward speed at take-off
    private var flipL: CGFloat = 0         // angular momentum for the flip (constant in the air)
    private var landImpact: CGFloat = 0    // downward speed at touchdown
    private let gravity: CGFloat = 2600    // points per second squared, the same for jumps and falls
    private var rollDir: CGFloat = 1       // ground roll after a hard throw
    private var rollLeft: CGFloat = 0
    private var rollSpeed: CGFloat = 0
    private var jumpPlatform = 0
    private var flip = false
    private var roll: CGFloat = 0
    private var rollVel: CGFloat = 0
    private var tumbling = false
    private var bounces = 0
    private var spin: CGFloat = 0
    private var spinLeft: CGFloat = 0
    private var pendingFlee = false
    private var fleeDir: CGFloat = 1
    private var dangle: CGFloat = 0
    private var dangleVel: CGFloat = 0
    private var pose = Pose()
    private var lastX: CGFloat = 0
    private var speedX: CGFloat = 0
    private var shadowAlpha: CGFloat = 0
    private var lastMouse = CGPoint.zero
    private var mouseSpeed: CGFloat = 0
    private var mouseStill: CGFloat = 0
    private var startleCooldown: CGFloat = 3
    private var emoteTime: CGFloat = 0
    private var napTimer: CGFloat = 0
    private var petCharge: CGFloat = 0
    private var heartTimer: CGFloat = 0
    private var pokeTimes: [CGFloat] = []
    private var pokeTime: CGFloat = 0
    private var sulk: CGFloat = 0
    private var userIdle: CGFloat = 0
    private var night = false
    private var cursorOnScreen = true
    private var dartX: CGFloat = 0
    private var dartY: CGFloat = 0
    private var dartTimer: CGFloat = 1
    private var puffs: [Puff] = []
    private var puffClock: CGFloat = 0
    private var stepSide: CGFloat = 1
    private var summoned = false
    private var stuck: CGFloat = 0
    private var edgeSide: CGFloat = 0      // -1 at the left end of the surface, 1 at the right, 0 otherwise
    private var peekTime: CGFloat = 0
    /// Each character keeps its own distance from the cursor, so they don't all head for one spot.
    private let orbit = CGFloat.random(in: 160...460) * (Bool.random() ? 1 : -1)

    init(sheet: CharacterSheet, start: CGPoint, zIndex: CGFloat) {
        self.sheet = sheet
        self.pos = start
        self.lastX = start.x
        self.zIndex = zIndex
        self.session = ChatSession(sheet: sheet)

        var chosen: CharacterBody = ProceduralBody(look: sheet.look)
        if let modelName = sheet.meshyModel,
           let model = ModelBody(folder: Config.modelFolder(modelName), height: sheet.look.height, yawOffset: sheet.modelYaw ?? 0) {
            chosen = model
        }
        body = chosen

        let H = sheet.look.height
        let plane = SCNPlane(width: H * 0.55, height: H * 0.07)
        plane.cornerRadius = H * 0.035
        let m = SCNMaterial()
        m.diffuse.contents = NSColor.black
        m.lightingModel = .constant
        m.writesToDepthBuffer = false
        plane.firstMaterial = m
        shadow = SCNNode(geometry: plane)
        shadow.position = v3(0, 1, -H * 0.3)
        shadow.opacity = 0

        node.addChildNode(body.root)
        node.addChildNode(shadow)
        emote.opacity = 0
        node.addChildNode(emote)

        session.onEvent = { [weak self] event in self?.handle(event) }
    }

    var hitRect: CGRect {
        let H = body.height
        if mode == .offstage {
            // Off stage, the clickable part is the strip of screen edge it peeks around.
            let width = H * 0.7
            let x = offSide < 0 ? stageFrame.minX : stageFrame.maxX - width
            return CGRect(x: x, y: pos.y - 4, width: width, height: H * 1.05)
        }
        return CGRect(x: pos.x - H * 0.32, y: pos.y - 4, width: H * 0.64, height: H * 1.02)
    }

    /// The surface this character is standing on, for the others to compare against.
    var surfaceID: Int { mode == .offstage ? -1 : platformID }

    var isOffstage: Bool { mode == .offstage }

    /// True while this character is running after the cursor.
    var chasingCursor: Bool { mode == .walking && errand == .cursor }

    /// Where this character is, or is about to be, standing.
    var claimedX: CGFloat { mode == .walking ? walkTarget : pos.x }

    /// Moves a spot sideways until it is clear of the other characters on this surface.
    private func spaced(_ x: CGFloat, others: [SprytCharacter], lo: CGFloat, hi: CGFloat) -> CGFloat {
        let gap = body.height * 0.95
        var result = x
        var pass = 0
        while pass < 3 {
            for other in others where other !== self && other.surfaceID == platformID {
                let ox = other.claimedX
                if abs(result - ox) < gap {
                    var side: CGFloat = result >= ox ? 1 : -1
                    if result == ox { side = Bool.random() ? 1 : -1 }
                    var moved = ox + side * gap
                    if moved < lo || moved > hi { moved = ox - side * gap }
                    result = moved
                }
            }
            pass += 1
        }
        return clamp(result, lo, hi)
    }

    /// True when the character has a reason to stay exactly where it is, so others should make room for it.
    var isAnchored: Bool {
        attention || activity != .none || petting || hobbyTime > 0 || mode == .napping || mode == .sitting
    }

    /// How far apart two characters' feet must be so their bodies don't overlap.
    private func gap(to other: SprytCharacter) -> CGFloat {
        (body.height + other.body.height) * 0.4
    }

    /// Someone standing in the way, just ahead in the direction of travel.
    private func blocker(ahead dir: CGFloat, others: [SprytCharacter]) -> SprytCharacter? {
        others.first(where: {
            $0 !== self && $0.surfaceID == platformID && $0.mode != .jumping && $0.mode != .falling && $0.mode != .held
                && ($0.pos.x - pos.x) * dir > 0 && abs($0.pos.x - pos.x) < gap(to: $0)
        })
    }

    /// True if a spot on some surface is already taken.
    private func taken(_ x: CGFloat, on surface: Int, others: [SprytCharacter]) -> Bool {
        others.contains(where: { $0 !== self && $0.surfaceID == surface && abs($0.claimedX - x) < gap(to: $0) })
    }

    /// Each character has its own stretch of the floor, so they spread out instead of bunching up.
    var zone: CGFloat = 0.5
    var zoneSpan: CGFloat = 1

    /// True when the character has nothing better to do and can be greeted or tagged.
    var isFree: Bool {
        (mode == .idle || mode == .sitting) && activity == .none && !attention && gestureTime <= 0
    }

    private var grounded: Bool {
        switch mode {
        case .jumping, .falling, .held: return false
        default: return true
        }
    }

    private func setMode(_ m: Mode) {
        mode = m
        modeTime = 0
        if m == .walking || m == .crouching { sinceMoved = 0 }
        if m != .walking {
            summoned = false
            backward = false
        }
    }

    /// The stretch of the current surface this character can actually stand on.
    /// Everything that picks a place to walk to uses this, so a target is always reachable.
    private func limits(_ world: World) -> (lo: CGFloat, hi: CGFloat) {
        let r = world.range(id: platformID)
        let inset = max(26, body.height * 0.42)
        let lo = max(r.lowerBound + inset, world.frame.minX + inset)
        let hi = min(r.upperBound - inset, world.frame.maxX - inset)
        if hi < lo { return (pos.x, pos.x) }
        return (lo, hi)
    }

    /// Run over to where the person called from.
    func come(to x: CGFloat, world: World) {
        if !(mode == .idle || mode == .sitting || mode == .napping || mode == .walking) { return }
        let (lo, hi) = limits(world)
        let target = clamp(x, lo, hi)
        if abs(target - pos.x) < 60 { return }
        walkTarget = target
        facing = target >= pos.x ? 1 : -1
        gait = .run
        errand = .none
        buddy = nil
        setMode(.walking)
        summoned = true
    }

    private func setActivity(_ a: Activity) {
        if activity != a {
            activity = a
            activityTime = 0
        }
        if a != .none && (mode == .sitting || mode == .napping || mode == .walking || mode == .dancing) {
            errand = .none
            buddy = nil
            idleFor = 1
            setMode(.idle)
        }
    }

    /// Picks one of `count` moves, never one of the last few. This is what stops the repetition.
    private func pick(_ count: Int, avoiding history: inout [Int], keep: Int) -> Int {
        var options: [Int] = []
        var i = 1
        while i <= count {
            if !history.contains(i) { options.append(i) }
            i += 1
        }
        let choice = options.randomElement() ?? Int.random(in: 1...count)
        history.append(choice)
        if history.count > keep { history.removeFirst(history.count - keep) }
        return choice
    }

    // MARK: Dust and sparkles

    private func emit(count: Int, sparkle: Bool, dx: CGFloat = 0, dy: CGFloat = 0, spread: CGFloat = 1) {
        guard let stage = node.parent, puffs.count < 48 else { return }
        let H = body.height
        var i = 0
        while i < count {
            let size = sparkle ? H * CGFloat.random(in: 0.018...0.035) : H * CGFloat.random(in: 0.03...0.055)
            let sphere = SCNSphere(radius: size)
            sphere.segmentCount = 10
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = sparkle
                ? NSColor(srgbRed: 1.0, green: 0.82, blue: 0.25, alpha: 1)
                : NSColor(white: 0.86, alpha: 1)
            m.writesToDepthBuffer = false
            sphere.firstMaterial = m
            let speck = SCNNode(geometry: sphere)
            let ox = dx + CGFloat.random(in: -1...1) * H * 0.12 * spread
            let oy = dy + CGFloat.random(in: 0...1) * H * 0.04
            speck.position = v3(node.position.x + ox, node.position.y + oy, zIndex + (sparkle ? 90 : -45))
            stage.addChildNode(speck)
            let life = CGFloat.random(in: 0.35...0.6) * (sparkle ? 1.4 : 1)
            puffs.append(Puff(
                node: speck,
                vx: CGFloat.random(in: -1...1) * (sparkle ? 90 : 55) * spread,
                vy: sparkle ? CGFloat.random(in: 40...150) : CGFloat.random(in: 10...45),
                life: life, total: life,
                grow: sparkle ? -0.6 : 1.6,
                alpha: sparkle ? 1 : 0.55))
            i += 1
        }
    }

    private func updatePuffs(dt: CGFloat) {
        var i = puffs.count - 1
        while i >= 0 {
            puffs[i].life -= dt
            if puffs[i].life <= 0 {
                puffs[i].node.removeFromParentNode()
                puffs.remove(at: i)
            } else {
                let p = puffs[i]
                let age = 1 - p.life / p.total
                p.node.position = v3(p.node.position.x + p.vx * dt, p.node.position.y + p.vy * dt, p.node.position.z)
                let k = max(0.1, 1 + p.grow * age)
                p.node.scale = v3(k, k, k)
                p.node.opacity = p.alpha * (1 - age)
                puffs[i].vx *= max(0, 1 - 3 * dt)
            }
            i -= 1
        }
    }

    // MARK: Little symbols that pop up over the head

    private func showEmote(_ symbol: String) {
        let H = body.height
        let text = SCNText(string: symbol, extrusionDepth: 0)
        text.font = NSFont.systemFont(ofSize: H * 0.3, weight: .heavy)
        text.flatness = 0.2
        let m = SCNMaterial()
        m.diffuse.contents = NSColor(srgbRed: 1.0, green: 0.69, blue: 0.13, alpha: 1)
        m.lightingModel = .constant
        text.firstMaterial = m
        emote.geometry = text
        let box = text.boundingBox
        emote.pivot = SCNMatrix4MakeTranslation((box.min.x + box.max.x) / 2, box.min.y, 0)
        emoteTime = 1.7
    }

    // MARK: Chat state drives the body

    func handle(_ event: ChatEvent) {
        sinceInteraction = 0
        switch event {
        case .thinking:
            setActivity(.thinking)
            showEmote("…")
        case .streaming:
            setActivity(.talking)
        case .tool(let kind):
            if kind != workKind { workTime = 0 }
            workKind = kind
            setActivity(.tool)
        case .toolResult(let kind, let ok):
            if kind == "test" || kind == "build" {
                if ok {
                    mood = "proud"
                    showEmote("✓")
                    setActivity(.thinking)
                    play("pump")
                } else {
                    mood = "sorry"
                    showEmote("✗")
                    setActivity(.thinking)
                    play("facepalm")
                    smokeTime = 2.2
                }
            }
        case .failed:
            mood = "sorry"
            setActivity(.error)
            smokeTime = 2.5
            showEmote("?")
        case .done(let newMood, let replyGesture, let seconds):
            mood = newMood
            setActivity(.waiting)
            var g = replyGesture
            if seconds > 15 && (g == "none" || g == "nod") { g = "jump" }
            if newMood == "excited" && mode == .idle && g != "jump" {
                startDance(seconds: 2.6)
            } else {
                play(g)
            }
            if newMood == "happy" || newMood == "playful" || newMood == "excited" { showEmote("♪") }
            flashTime = 0.7
            if homePlatform != nil {
                let reply = session.messages.last(where: { $0.role == "assistant" && !$0.hidden })?.text ?? ""
                var line = reply.split(separator: "\n").first.map(String.init) ?? ""
                if line.count > 90 { line = String(line.prefix(90)) + "…" }
                if !line.isEmpty && !line.hasPrefix("```") { pendingSpeech = line }
            }
            if sheet.signature == "spark" { emit(count: 5, sparkle: true, dy: body.height * 1.05, spread: 0.8) }
            // A long job finished while the panel was closed: come over, tap the screen and say so.
            if seconds > 20 && !panelOpen, let world = lastWorld {
                let reply = session.messages.last(where: { $0.role == "assistant" && !$0.hidden })?.text ?? ""
                var line = reply.split(separator: "\n").first.map(String.init) ?? ""
                if line.count > 110 { line = String(line.prefix(110)) + "…" }
                if !line.isEmpty { pendingSpeech = line }
                tapWhenThere = true
                come(to: lastMouse.x, world: world)
                if mode != .walking {
                    tapWhenThere = false
                    play("tap")
                }
            }
        case .needsApproval:
            setActivity(.asking)
            showEmote("?")
        case .remark(let text, let newMood, let replyGesture):
            // The character is speaking first: stand up, face out, and say it.
            mood = newMood
            pendingSpeech = text
            if mode == .sitting || mode == .napping { setMode(.idle) }
            idleFor = 3
            play(replyGesture == "none" ? "wave" : replyGesture)
        }
    }

    // MARK: Touch

    /// A double-click. A couple are fun; three in a row is annoying.
    func poke() {
        sinceInteraction = 0
        pokeTimes = pokeTimes.filter { t - $0 < 4 }
        pokeTimes.append(t)
        if pokeTimes.count >= 3 {
            pokeTimes = []
            sulk = 3.5
            mood = "calm"
            showEmote("…")
            session.affection = max(0, session.affection - 0.5)
        } else {
            pokeTime = 0.45
            mood = "playful"
            showEmote("!")
        }
    }

    func noteInteraction() {
        sinceInteraction = 0
    }

    // MARK: Games

    /// Roughly where the throwing hand is, in screen points.
    var handPoint: CGPoint {
        CGPoint(x: pos.x + facing * body.height * 0.3, y: pos.y + body.height * 0.8)
    }

    /// A quick overarm swing as something leaves the hand.
    func throwSomething(toward vx: CGFloat) {
        sinceInteraction = 0
        if abs(vx) > 30 { facing = vx > 0 ? 1 : -1 }
        if mode == .napping || mode == .sitting { setMode(.idle) }
        gesture = "pump"
        gestureTime = 0.55
    }

    /// A quick wince when something goes wrong.
    func wince() {
        gesture = "facepalm"
        gestureTime = 0.9
    }

    /// A little celebration for a good hit.
    func cheer() {
        mood = "playful"
        gesture = "pump"
        gestureTime = 1.2
        emit(count: 8, sparkle: true, dy: body.height * 0.9)
    }

    /// Gets a dozing or sitting character back on its feet.
    func wake() {
        sinceInteraction = 0
        if mode == .napping || mode == .sitting {
            idleFor = 0.3
            setMode(.idle)
        }
    }

    private func play(_ g: String) {
        if g == "jump" {
            if mode == .idle { hop(height: body.height * 0.5, withFlip: sheet.motion.jumpiness > 0.6) }
            gesture = "wave"
            gestureTime = 2.4
        } else if g == "none" {
            gesture = "none"
            gestureTime = 0
        } else if g == "recite" {
            gesture = g
            gestureTime = 4.5
        } else if g == "tap" {
            gesture = g
            gestureTime = 2.4
            showEmote("!")
        } else {
            gesture = g
            gestureTime = 1.9
        }
    }

    private func hop(height: CGFloat, withFlip: Bool) {
        launch(to: pos, platform: platformID, apex: height, withFlip: withFlip)
    }

    /// How tightly the body is tucked at each point of a flip: open at take-off, balled up, open again to land.
    private func tuck(at s: CGFloat) -> CGFloat {
        if s < 0.22 {
            let x = s / 0.22
            return x * x * (3 - 2 * x)
        }
        if s > 0.72 {
            let x = max(0, (1 - s) / 0.28)
            return x * x * (3 - 2 * x)
        }
        return 1
    }

    /// A harder landing takes longer to absorb.
    private var landTime: CGFloat {
        0.16 + 0.1 * clamp(landImpact / 900, 0.4, 1.3)
    }

    /// Resistance to spinning. A tucked body has much less, so it turns faster.
    private func inertia(_ tucked: CGFloat) -> CGFloat {
        1 - 0.65 * tucked
    }

    /// Starts a jump that follows a real ballistic arc under gravity.
    private func launch(to target: CGPoint, platform: Int, apex: CGFloat, withFlip: Bool) {
        let H = body.height
        let rise = target.y - pos.y
        // The top of the arc has to clear both the take-off and the landing spot.
        var height = max(apex, rise + 24, 14)
        if withFlip { height = max(height, H * 0.95, rise + H * 0.55) }   // a full turn needs real air time
        jumpVY = (2 * gravity * height).squareRoot()
        let under = max(0, jumpVY * jumpVY - 2 * gravity * rise)
        jumpDur = (jumpVY + under.squareRoot()) / gravity
        jumpFrom = pos
        jumpTo = target
        jumpPlatform = platform
        flip = withFlip && jumpDur <= 0.85
        if flip {
            // Angular momentum is fixed at take-off. Pick the amount that gives exactly one turn
            // over the air time, given how the tuck speeds the spin up and the opening slows it.
            var sum: CGFloat = 0
            var i = 0
            while i < 48 {
                sum += 1 / inertia(tuck(at: (CGFloat(i) + 0.5) / 48))
                i += 1
            }
            flipL = 2 * CGFloat.pi / ((sum / 48) * jumpDur)
            roll = 0
        }
        setMode(.crouching)
    }

    private func startDance(seconds: CGFloat) {
        danceFor = seconds
        danceSpinAt = seconds * CGFloat.random(in: 0.35...0.6)
        danceSpun = false
        showEmote("♪")
        setMode(.dancing)
    }

    // MARK: The characters notice each other

    /// A heart on its way from one character to another.
    private struct HeartFlight {
        let node: SCNNode
        let from: CGPoint
        weak var target: SprytCharacter?
        var age: CGFloat
    }
    private var hearts: [HeartFlight] = []
    private var heartDelay: CGFloat = 0
    private weak var heartTarget: SprytCharacter?
    private var socialClock: CGFloat = CGFloat.random(in: 0...30)
    private var nextSocial: CGFloat = CGFloat.random(in: 45...110)
    private var replyIn: CGFloat = 0
    private var replyKind = ""
    private var replyLine = ""
    private var swoon: CGFloat = 0

    private var role: String { sheet.role ?? "generalist" }

    private func opener(to other: SprytCharacter) -> String {
        let n = other.sheet.name
        var lines = ["Hey \(n)! Having a good day?", "\(n)! You look great over there.", "Psst, \(n). Glad you're here."]
        if role == "coder" { lines += ["Hey \(n), all systems go?", "\(n)! Nice work today."] }
        if role == "writer" { lines += ["\(n), you brighten the whole screen.", "So good to see you, \(n)."] }
        return lines.randomElement() ?? "Hey \(n)!"
    }

    private var answer: String {
        if role == "coder" { return ["Affirmative!", "Ha. Compiling, as ever.", "All good. You're the best."].randomElement() ?? "Yes!" }
        if role == "writer" { return ["Oh, delightfully so.", "You do say the nicest things.", "Ha! Likewise, friend."].randomElement() ?? "Yes!" }
        return ["Ha! Always.", "You know it!", "Aw, thanks for checking in."].randomElement() ?? "Yes!"
    }

    /// Every so often, when two characters are both at a loose end, one reaches out to the other.
    private func social(dt: CGFloat, others: [SprytCharacter], quiet: Bool) {
        if swoon > 0 { swoon -= dt }

        // A blown kiss leaves the hand a moment after the gesture starts.
        if heartDelay > 0 {
            heartDelay -= dt
            if heartDelay <= 0, let target = heartTarget, let stage = node.parent {
                let H = body.height
                let text = SCNText(string: "♥", extrusionDepth: 0)
                text.font = NSFont.systemFont(ofSize: H * 0.24, weight: .heavy)
                text.flatness = 0.2
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.diffuse.contents = NSColor(srgbRed: 1.0, green: 0.35, blue: 0.5, alpha: 1)
                m.writesToDepthBuffer = false
                text.firstMaterial = m
                let heart = SCNNode(geometry: text)
                let box = text.boundingBox
                heart.pivot = SCNMatrix4MakeTranslation((box.min.x + box.max.x) / 2, (box.min.y + box.max.y) / 2, 0)
                let start = CGPoint(x: node.position.x + facing * H * 0.25, y: node.position.y + H * 0.72)
                heart.position = v3(start.x, start.y, zIndex + 95)
                stage.addChildNode(heart)
                hearts.append(HeartFlight(node: heart, from: start, target: target, age: 0))
            }
        }
        var i = hearts.count - 1
        while i >= 0 {
            hearts[i].age += dt
            let s = hearts[i].age / 1.3
            if s >= 1 || hearts[i].target == nil {
                hearts[i].node.removeFromParentNode()
                hearts.remove(at: i)
            } else if let target = hearts[i].target {
                let endX = target.node.position.x
                let endY = target.node.position.y + target.body.height * 0.8
                let from = hearts[i].from
                let x = from.x + (endX - from.x) * s
                let y = from.y + (endY - from.y) * s + sin(s * CGFloat.pi) * 70
                hearts[i].node.position = v3(x, y, zIndex + 95)
                let beat = 1 + 0.18 * sin(hearts[i].age * 16)
                hearts[i].node.scale = v3(beat, beat, 1)
            }
            i -= 1
        }

        // Answering someone who reached out.
        if replyIn > 0 {
            replyIn -= dt
            if replyIn <= 0 {
                switch replyKind {
                case "kiss":
                    swoon = 3.2
                    showEmote("♥")
                    emit(count: 6, sparkle: true, dy: body.height * 0.9)
                    play("nod")
                case "chat":
                    pendingSpeech = replyLine
                    play("nod")
                case "cheer":
                    play("pump")
                default:
                    play("wave")
                }
                idleFor = max(idleFor, 2.4)
            }
        }

        socialClock += dt
        if quiet || playing || socialClock < nextSocial || !isFree { return }
        let H = body.height
        let free = others.filter { $0 !== self && $0.isFree && !$0.playing && abs($0.pos.x - pos.x) > H }
        guard let other = free.randomElement() else {
            socialClock = nextSocial - 8   // nobody free just now: look again shortly
            return
        }
        socialClock = 0
        nextSocial = CGFloat.random(in: 60...150)
        facing = other.pos.x >= pos.x ? 1 : -1
        if mode == .sitting { setMode(.idle) }
        idleFor = max(idleFor, 4)
        let roll = CGFloat.random(in: 0...1)
        if roll < 0.35 {
            play("wave")
            other.reachedOut("wave", by: self, line: "", delay: 0.9)
        } else if roll < 0.65 {
            pendingSpeech = opener(to: other)
            play("wave")
            other.reachedOut("chat", by: self, line: other.answer, delay: 2.8)
        } else if roll < 0.82 {
            play("kiss")
            heartDelay = 0.7
            heartTarget = other
            other.reachedOut("kiss", by: self, line: "", delay: 2.0)
        } else {
            play("pump")
            showEmote("♪")
            other.reachedOut("cheer", by: self, line: "", delay: 0.6)
        }
    }

    /// Another character waved, spoke, cheered or blew a kiss this way.
    func reachedOut(_ kind: String, by other: SprytCharacter, line: String, delay: CGFloat) {
        if !isFree { return }
        facing = other.pos.x >= pos.x ? 1 : -1
        if mode == .sitting { setMode(.idle) }
        idleFor = max(idleFor, delay + 2.5)
        replyKind = kind
        replyLine = line
        replyIn = delay
        socialClock = 0
    }

    func greeted(from x: CGFloat) {
        if !isFree { return }
        facing = x >= pos.x ? 1 : -1
        if mode == .sitting { setMode(.idle) }
        idleFor = 2.6
        play("wave")
    }

    func tagged(from x: CGFloat) {
        if !isFree { return }
        showEmote("!")
        fleeDir = x >= pos.x ? -1 : 1
        pendingFlee = true
        hop(height: body.height * 0.4, withFlip: false)
    }

    // MARK: Being picked up and thrown

    func beginDrag() {
        dangle = 0
        dangleVel = 0
        errand = .none
        buddy = nil
        pendingFlee = false
        setMode(.held)
    }

    func drag(to p: CGPoint, dx: CGFloat) {
        pos = p
        dangleVel += clamp(dx * 0.03, -2, 2)
    }

    /// Leaves the stage through one side. It stays there, peeking in, until clicked.
    private func goOffstage(side: CGFloat) {
        let H = body.height
        offSide = side
        platformID = 0
        vel = CGVector(dx: 0, dy: 0)
        tumbling = false
        thrown = false
        roll = 0
        errand = .none
        buddy = nil
        hobbyTime = 0
        fidget = 0
        comboHops = 0
        peekOut = 0
        peekGoal = 0
        peekTimer = 1.6
        pos.x = side < 0 ? stageFrame.minX - H * 0.5 : stageFrame.maxX + H * 0.5
        setMode(.offstage)
    }

    /// Hops back onto the stage from where it has been waiting.
    func returnToStage(world: World, others: [SprytCharacter]) {
        if mode != .offstage { return }
        let H = body.height
        sinceInteraction = 0
        platformID = 0
        pos.y = world.floorY
        let (lo, hi) = limits(world)
        var target = offSide < 0 ? lo + CGFloat.random(in: 60...180) : hi - CGFloat.random(in: 60...180)
        target = spaced(clamp(target, lo, hi), others: others, lo: lo, hi: hi)
        facing = -offSide
        launch(to: CGPoint(x: target, y: world.floorY), platform: 0, apex: H * 0.7, withFlip: false)
        gesture = "wave"
        gestureTime = 2.6
        showEmote("♪")
    }

    func endDrag(velocity: CGVector) {
        thrown = true
        // Let go right at the side of the screen: that's a send-off too.
        if stageFrame.width > 0 && (pos.x < stageFrame.minX + body.height * 0.45 || pos.x > stageFrame.maxX - body.height * 0.45) {
            goOffstage(side: pos.x < stageFrame.midX ? -1 : 1)
            return
        }
        vel = CGVector(dx: clamp(velocity.dx, -1600, 1600), dy: clamp(velocity.dy, -1400, 1800))
        tumbling = hypot(vel.dx, vel.dy) > 900 && abs(vel.dx) > 250
        let spinWay: CGFloat = vel.dx >= 0 ? -1 : 1
        rollVel = tumbling ? spinWay * clamp(abs(vel.dx) * 0.012, 7, 16) : 0
        roll = 0
        bounces = 0
        setMode(.falling)
    }

    // MARK: Per-frame update

    func update(dt: CGFloat, world: World, mouse: CGPoint, quiet: Bool, others: [SprytCharacter], presence: Presence) {
        t += dt
        modeTime += dt
        activityTime += dt
        sinceInteraction += dt
        startleCooldown -= dt
        if attention { sinceInteraction = 0 }
        if gestureTime > 0 {
            gestureTime -= dt
            if gestureTime <= 0 { gesture = "none" }
        }
        if activity == .error && activityTime > 3 { setActivity(.waiting) }
        if activity == .waiting && activityTime > 25 && !panelOpen { setActivity(.none) }

        let H = body.height
        let m = sheet.motion
        lastWorld = world
        stageFrame = world.frame
        workTime += dt
        nextBig -= dt
        if mode == .idle || mode == .sitting || mode == .napping { sinceMoved += dt }
        if hobbyTime > 0 {
            hobbyTime -= dt
            if activity != .none || mode != .idle { hobbyTime = 0 }
        }
        if flashTime > 0 { flashTime -= dt }
        if smokeTime > 0 {
            smokeTime -= dt
            // Signature: an annoyed dragon leaks smoke.
            if sheet.signature == "smoke" {
                puffClock -= dt
                if puffClock <= 0 {
                    puffClock = 0.16
                    emit(count: 1, sparkle: false, dx: facing * H * 0.22, dy: H * 0.72, spread: 0.4)
                }
            }
        }

        // How the cursor is moving.
        let moved = hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y)
        mouseSpeed = mouseSpeed * 0.7 + (moved / max(dt, 0.001)) * 0.3
        mouseStill = moved < 0.5 ? mouseStill + dt : 0
        lastMouse = mouse
        cursorOnScreen = world.frame.contains(mouse)

        // Stroking: the cursor moving gently back and forth over them.
        let pace = moved / max(dt, 0.001)
        let over = hitRect.contains(mouse)
        let strokable = (mode == .idle || mode == .sitting) && activity != .tool && sulk <= 0
        if over && strokable && pace > 40 && pace < 1800 {
            petCharge = min(420, petCharge + moved)
        } else {
            petCharge = max(0, petCharge - 160 * dt)
        }
        petting = over && strokable && petCharge > 150
        if petting {
            mood = "happy"
            sinceInteraction = 0
            session.affection += Double(dt) * 0.4
            heartTimer -= dt
            if heartTimer <= 0 {
                heartTimer = 1.3
                showEmote("♥")
            }
        } else {
            heartTimer = 0
        }
        if pokeTime > 0 { pokeTime -= dt }
        if sulk > 0 { sulk -= dt }
        if peekTime > 0 {
            peekTime -= dt
            if peekTime <= 0 || mode != .idle {
                peekTime = 0
                if edgeSide != 0 { facing = -edgeSide }   // seen enough: turn back in
            }
        }

        // The person stepping away and coming back.
        userIdle = presence.idle
        night = presence.night
        if presence.returned {
            sinceInteraction = 0
            if mode == .napping || mode == .sitting {
                idleFor = 0.4
                setMode(.idle)
            }
            if mode == .idle && activity == .none {
                showEmote("!")
                facing = mouse.x >= pos.x ? 1 : -1
                play("jump")
            }
        }

        // A cursor whipping past makes them jump.
        let center = CGPoint(x: pos.x, y: pos.y + H * 0.5)
        if startleCooldown <= 0 && mouseSpeed > 2200 && !attention && !quiet && activity == .none
            && hypot(mouse.x - center.x, mouse.y - center.y) < H * 0.9
            && (mode == .idle || mode == .walking || mode == .sitting) {
            startleCooldown = 6
            errand = .none
            buddy = nil
            showEmote("!")
            facing = mouse.x >= pos.x ? 1 : -1
            hop(height: H * 0.55, withFlip: false)
        }

        if grounded {
            if let y = world.surfaceY(id: platformID, x: pos.x, clearance: H) {
                pos.y = y   // ride along when the window moves
            } else {
                vel = CGVector(dx: speedX * 0.5, dy: 0)
                tumbling = false
                bounces = 0
                errand = .none
                buddy = nil
                setMode(.falling)
            }
        }

        switch mode {
        case .idle:
            let stayPut = playing || attention || quiet || gestureTime > 0 || petting || sulk > 0 || pokeTime > 0 || hobbyTime > 0
                || activity == .talking || activity == .tool || activity == .error || activity == .waiting
                || activity == .asking
                || (activity == .thinking && panelOpen)
            if stayPut { break }
            if activity == .thinking {
                // Pace back and forth while the bot works in the background.
                if modeTime > 0.7 {
                    let (lo, hi) = limits(world)
                    var wanted = pos.x - facing * CGFloat.random(in: 60...110)
                    if wanted < lo || wanted > hi { wanted = pos.x + facing * CGFloat.random(in: 60...110) }
                    walkTarget = clamp(wanted, lo, hi)
                    facing = walkTarget >= pos.x ? 1 : -1
                    gait = .walk
                    errand = .none
                    setMode(.walking)
                }
                break
            }
            // Overlapping someone: step away. If they have a reason to stay put, it is always me who moves;
            // if we are both free, the one drawn in front does.
            if let crowd = others.first(where: {
                $0 !== self && $0.surfaceID == platformID
                    && ($0.mode == .idle || $0.mode == .sitting || $0.mode == .napping)
                    && abs($0.pos.x - pos.x) < gap(to: $0) * 0.9
                    && ($0.isAnchored || $0.zIndex < zIndex)
            }) {
                let (lo, hi) = limits(world)
                var side: CGFloat = pos.x >= crowd.pos.x ? 1 : -1
                if pos.x == crowd.pos.x { side = Bool.random() ? 1 : -1 }
                var target = crowd.pos.x + side * H * CGFloat.random(in: 1.0...1.7)
                if target < lo || target > hi { target = crowd.pos.x - side * H * CGFloat.random(in: 1.0...1.7) }
                target = spaced(clamp(target, lo, hi), others: others, lo: lo, hi: hi)
                if abs(target - pos.x) > 12 {
                    walkTarget = target
                    facing = target >= pos.x ? 1 : -1
                    gait = .walk
                    errand = .none
                    setMode(.walking)
                    break
                }
            }
            idleFor -= dt
            if idleFor <= 0 { decide(world: world, mouse: mouse, others: others) }

        case .walking:
            if (attention && !summoned) || quiet {
                errand = .none
                buddy = nil
                idleFor = 1
                setMode(.idle)
                break
            }
            let (lo, hi) = limits(world)

            if errand == .cursor {
                chaseTime -= dt
                if chaseTime <= 0 || mouseStill > 2.5 || mouse.x < lo - 80 || mouse.x > hi + 80 {
                    errand = .none
                    arrive()
                    break
                }
                walkTarget = clamp(mouse.x, lo, hi)
                if abs(mouse.x - pos.x) < 50 {
                    // Under the cursor: leap for it if it is overhead.
                    let above = mouse.y - (pos.y + H)
                    errand = .none
                    if above > 20 && above < 340 {
                        hop(height: clamp(above + H * 0.3, 40, 320), withFlip: false)
                    } else {
                        arrive()
                    }
                    break
                }
            } else if errand == .greet || errand == .tag {
                if let b = buddy, b.surfaceID == platformID {
                    let side: CGFloat = pos.x < b.pos.x ? -1 : 1
                    walkTarget = clamp(b.pos.x + side * H * 0.8, lo, hi)
                } else {
                    errand = .none
                    buddy = nil
                }
            }

            if abs(walkTarget - pos.x) > 4 {
                let toward: CGFloat = walkTarget >= pos.x ? 1 : -1
                facing = backward ? -toward : toward
            }
            var speed = m.speed * (backward ? 0.6 : 1)
            var strideAngle = m.stride
            var reach: CGFloat = 1
            switch gait {
            case .walk:
                break
            case .run:
                speed *= 2.3
                strideAngle = min(0.95, m.stride * 1.6)
                reach = 1.5
            case .skip:
                speed *= 1.35
                reach = 1.5
            case .sneak:
                speed *= 0.55
                strideAngle = m.stride * 1.1
            }
            edgeSide = walkTarget <= lo + 2 ? -1 : (walkTarget >= hi - 2 ? 1 : 0)
            // Not getting anywhere: stop and turn round instead of running on the spot.
            stuck = (modeTime > 0.5 && abs(speedX) < 4) ? stuck + dt : 0
            if stuck > 0.25 || (modeTime > 8 && errand != .lap) {
                stuck = 0
                errand = .none
                buddy = nil
                tapWhenThere = false
                if modeTime <= 8 { facing = -facing }
                idleFor = CGFloat.random(in: 6...12)
                setMode(.idle)
                break
            }
            // Someone is in the way: stop short instead of walking through them.
            if errand != .greet && errand != .tag,
               blocker(ahead: backward ? -facing : facing, others: others) != nil {
                errand = .none
                buddy = nil
                tapWhenThere = false
                idleFor = CGFloat.random(in: 6...12)
                setMode(.idle)
                break
            }
            // Wind up before a run, and ease into any walk instead of starting at full speed.
            if gait == .run && modeTime < 0.16 { break }
            let ease = min(1, 0.35 + modeTime / 0.3)
            let step = (backward ? -facing : facing) * speed * ease * dt
            if abs(walkTarget - pos.x) <= abs(step) + 1 {
                pos.x = walkTarget
                arrive()
                break
            }
            pos.x += step
            if gait == .run {
                let side: CGFloat = sin(phase) >= 0 ? 1 : -1
                if side != stepSide {
                    stepSide = side
                    emit(count: 1, sparkle: false, dx: -facing * H * 0.12)
                }
            }
            // Tie the leg cycle to distance covered so feet plant instead of sliding.
            let strideLength = max(8, 2 * body.legLength * sin(strideAngle) * reach)
            phase += abs(step) / strideLength * CGFloat.pi

        case .skidding:
            pos.x += facing * skidSpeed * dt
            skidSpeed *= max(0, 1 - 9 * dt)
            puffClock -= dt
            if puffClock <= 0 {
                puffClock = 0.05
                emit(count: 1, sparkle: false, dx: facing * H * 0.15)
            }
            let (lo, hi) = limits(world)
            if pos.x < lo || pos.x > hi {
                pos.x = clamp(pos.x, lo, hi)
                skidSpeed = 0
            }
            if modeTime > 0.3 {
                if edgeSide != 0 { facing = -edgeSide }
                idleFor = CGFloat.random(in: 5...10) / max(m.tempo, 0.5)
                setMode(.idle)
            }

        case .crouching:
            if modeTime >= 0.16 { setMode(.jumping) }

        case .jumping:
            // Constant sideways speed, constant downward acceleration.
            let air = min(modeTime, jumpDur)
            let s = air / jumpDur
            pos.x = jumpFrom.x + (jumpTo.x - jumpFrom.x) * s
            pos.y = jumpFrom.y + jumpVY * air - 0.5 * gravity * air * air
            if flip {
                // Spin rate = angular momentum / inertia: fast while tucked, slow when opened out.
                roll -= facing * (flipL / inertia(tuck(at: s))) * dt
            }
            if modeTime >= jumpDur {
                pos = jumpTo
                platformID = jumpPlatform
                landImpact = abs(jumpVY - gravity * jumpDur)
                roll = flip ? 0 : wrapAngle(roll)
                emit(count: 5, sparkle: false, spread: 1.6)
                if flip { emit(count: 6, sparkle: true, dy: H * 0.5, spread: 1.5) }
                flip = false
                setMode(.landing)
            }

        case .falling:
            let previousY = pos.y
            vel.dy -= gravity * dt
            pos.y += vel.dy * dt
            pos.x += vel.dx * dt
            vel.dx *= max(0, 1 - 0.8 * dt)
            if tumbling { roll += rollVel * dt }
            // Bounce off the sides and top of the screen.
            let left = world.frame.minX + H * 0.35
            let right = world.frame.maxX - H * 0.35
            if thrown && ((pos.x < left && vel.dx < -420) || (pos.x > right && vel.dx > 420)) {
                goOffstage(side: pos.x < left ? -1 : 1)
                break
            }
            if pos.x < left {
                pos.x = left
                vel.dx = abs(vel.dx) * 0.6
                rollVel = -rollVel * 0.6
            } else if pos.x > right {
                pos.x = right
                vel.dx = -abs(vel.dx) * 0.6
                rollVel = -rollVel * 0.6
            }
            let top = world.frame.maxY - H * 0.6
            if pos.y > top && vel.dy > 0 {
                pos.y = top
                vel.dy = -vel.dy * 0.5
            }
            let g = world.ground(x: pos.x, below: previousY + 1, clearance: H)
            if pos.y <= g.y {
                pos.y = g.y
                let impact = -vel.dy
                let springy = (tumbling && impact > 700) || impact > 1900
                emit(count: impact > 900 ? 7 : 4, sparkle: false, spread: 1.8)
                if springy && bounces < 1 {
                    bounces += 1
                    vel.dy = impact * 0.28
                    vel.dx *= 0.7
                    rollVel *= 0.7
                } else {
                    platformID = g.id
                    let leftover = wrapAngle(roll)
                    let wasTumbling = tumbling
                    let slide = vel.dx
                    vel = CGVector(dx: 0, dy: 0)
                    landImpact = impact
                    tumbling = false
                    bounces = 0
                    if wasTumbling && abs(leftover) > 0.5 {
                        // Not upright: stay tucked and roll along the ground until the turn is finished.
                        rollDir = abs(slide) > 40 ? (slide > 0 ? 1 : -1) : (rollVel < 0 ? 1 : -1)
                        roll = leftover
                        if rollDir > 0 {
                            rollLeft = leftover > 0 ? leftover : leftover + 2 * CGFloat.pi
                        } else {
                            rollLeft = leftover < 0 ? -leftover : 2 * CGFloat.pi - leftover
                        }
                        rollSpeed = max(170, abs(slide) * 0.6)
                        facing = rollDir
                        setMode(.cartwheel)
                    } else {
                        roll = 0
                        if wasTumbling || impact > 1900 {
                            showEmote("✶")
                            setMode(.dizzy)
                        } else {
                            setMode(.landing)
                        }
                    }
                }
            }

        case .landing:
            if modeTime >= landTime {
                if comboHops > 0 && activity == .none && !attention {
                    comboHops -= 1
                    hop(height: H * (comboHops == 0 ? 0.95 : 0.55), withFlip: comboHops == 0)
                    break
                }
                comboHops = 0
                if pendingFlee {
                    pendingFlee = false
                    let (lo, hi) = limits(world)
                    walkTarget = clamp(pos.x + fleeDir * CGFloat.random(in: 260...520), lo, hi)
                    if abs(walkTarget - pos.x) > 40 {
                        facing = fleeDir
                        gait = .run
                        errand = .flee
                        setMode(.walking)
                        break
                    }
                }
                idleFor = CGFloat.random(in: 0.3...1.2)
                setMode(.idle)
            }

        case .held:
            dangleVel += (-60 * dangle - 6 * dangleVel) * dt
            dangle = clamp(dangle + dangleVel * dt, -0.9, 0.9)

        case .offstage:
            // Waiting in the wings: lean out to look, wave now and then, tuck back in.
            let cursorClose = abs(mouse.x - (offSide < 0 ? world.frame.minX : world.frame.maxX)) < 260
                && abs(mouse.y - (pos.y + H * 0.5)) < 320
            peekTimer -= dt
            if cursorClose {
                peekGoal = 1
                if offWave <= 0 && peekOut > 0.8 { offWave = 1.8 }
                peekTimer = max(peekTimer, 2)
            } else if peekTimer <= 0 {
                if peekGoal > 0.5 {
                    peekGoal = 0.3
                    peekTimer = CGFloat.random(in: 3...7)
                } else {
                    peekGoal = 1
                    peekTimer = CGFloat.random(in: 4...9)
                    if Bool.random() { offWave = 1.8 }
                }
            }
            if activity == .waiting || activity == .asking || pendingSpeech != nil { peekGoal = 1 }
            if offWave > 0 { offWave -= dt }
            peekOut += (peekGoal - peekOut) * min(1, 5 * dt)
            let edge = offSide < 0 ? world.frame.minX : world.frame.maxX
            pos.x = edge + offSide * H * (0.44 - 0.4 * peekOut)

        case .sitting:
            sitFor -= dt
            if sitFor <= 0 || (attention && !petting) {
                idleFor = 0.6
                setMode(.idle)
            }

        case .napping:
            napTimer -= dt
            if napTimer <= 0 {
                napTimer = 2.6
                showEmote("z")
            }
            // Stays asleep until hovered, summoned, spoken to, or the person comes back from being away.
            if attention || activity != .none {
                idleFor = 0.8
                setMode(.idle)
            }

        case .dizzy:
            if modeTime > 1.9 {
                idleFor = 0.8
                setMode(.idle)
            }

        case .dancing:
            danceFor -= dt
            puffClock -= dt
            if puffClock <= 0 {
                puffClock = 0.35
                emit(count: 2, sparkle: true, dy: H * 0.7, spread: 2.2)
            }
            if !danceSpun && modeTime >= danceSpinAt {
                danceSpun = true
                spinLeft = 2 * CGFloat.pi
            }
            if danceFor <= 0 && spinLeft <= 0 {
                idleFor = 0.8
                setMode(.idle)
            }

        case .cartwheel:
            // Rolling along the ground after a hard throw, tucked in a ball.
            let (lo, hi) = limits(world)
            let step = rollSpeed * dt
            pos.x = clamp(pos.x + rollDir * step, lo, hi)
            let turned = step / (H * 0.32)   // rolling without slipping on a ball about a third of a body tall
            roll -= rollDir * turned
            rollLeft -= turned
            rollSpeed = max(130, rollSpeed * (1 - 1.2 * dt))
            puffClock -= dt
            if puffClock <= 0 {
                puffClock = 0.09
                emit(count: 1, sparkle: false)
            }
            if rollLeft <= 0 {
                roll = 0
                showEmote("✶")
                setMode(.dizzy)
            }
        }

        // A twirl on the spot.
        if spinLeft > 0 {
            let d = min(spinLeft, 11 * dt)
            spin += d
            spinLeft -= d
            if spinLeft <= 0 { spin = 0 }
        }

        // Settle upright whenever nothing is actively spinning the body.
        let spinning = (mode == .jumping && flip) || mode == .cartwheel || (mode == .falling && tumbling)
        if !spinning {
            if abs(roll) > 0.6 { roll = 0 }
            roll -= roll * min(1, 12 * dt)
        }

        if world.frame.width > H && mode != .offstage {
            pos.x = clamp(pos.x, world.frame.minX + H * 0.35, world.frame.maxX - H * 0.35)
        }
        if grounded { thrown = false }
        speedX = (pos.x - lastX) / max(dt, 0.001)
        lastX = pos.x

        updatePuffs(dt: dt)
        social(dt: dt, others: others, quiet: quiet)
        dartTimer -= dt
        if dartTimer <= 0 {
            dartTimer = CGFloat.random(in: 0.8...2.6)
            dartX = CGFloat.random(in: -0.8...0.8)
            dartY = CGFloat.random(in: -0.3...0.4)
        }

        nextBlink -= dt
        if nextBlink <= 0 {
            blink = 0.13
            nextBlink = CGFloat.random(in: 1.8...5.5)
        }
        if blink > 0 { blink -= dt }

        // Small gestures: always something going on, whenever the character is standing or sitting.
        let settled = mode == .idle || mode == .sitting
        if settled && sulk <= 0 && activity != .error {
            if micro == 0 {
                nextMicro -= dt
                if nextMicro <= 0 {
                    micro = pick(12, avoiding: &microHistory, keep: 5)
                    microTime = 0
                    microDur = CGFloat.random(in: 0.5...1.3)
                    microAmp = CGFloat.random(in: 0.7...1.3)
                    microSide = Bool.random() ? 1 : -1
                }
            } else {
                microTime += dt
                if microTime >= microDur {
                    micro = 0
                    nextMicro = CGFloat.random(in: 1.2...3.6) / (0.6 + 0.6 * m.fidget)
                }
            }
        } else {
            micro = 0
        }

        // Medium gestures: about once a minute, only when there is nothing else to do.
        if mode == .idle && activity == .none && gestureTime <= 0 && !attention && peekTime <= 0 {
            if fidget == 0 {
                nextFidget -= dt
                if nextFidget <= 0 {
                    if isSpecialist {
                        if Bool.random() {
                            // Their own time: the programmer types or reads; the writer scribbles or reads.
                            workKind = Bool.random() ? (isWriter ? "write" : "edit") : "read"
                            workTime = 0
                            hobbyTime = CGFloat.random(in: 5...9)
                            nextFidget = hobbyTime + CGFloat.random(in: 20...50)
                        } else {
                            // Quiet, thoughtful gestures only.
                            let pool = isWriter ? [1, 3, 7, 9, 12, 13] : [1, 2, 3, 7, 8, 13]
                            let quietOnes = pool.filter { !fidgetHistory.contains($0) }
                            fidget = quietOnes.randomElement() ?? 1
                            fidgetHistory.append(fidget)
                            if fidgetHistory.count > 3 { fidgetHistory.removeFirst(fidgetHistory.count - 3) }
                        }
                    } else {
                        fidget = pick(15, avoiding: &fidgetHistory, keep: 6)
                    }
                    fidgetTime = 0
                    fidgetAmp = CGFloat.random(in: 0.8...1.2)
                    fidgetDur = CGFloat.random(in: 1.8...2.8)
                    sneezed = false
                    if fidget == 5 { spinLeft = 2 * CGFloat.pi }
                    if fidget == 11 && !cursorOnScreen { fidget = 1 }
                }
            }
        } else {
            fidget = 0
        }
        if fidget != 0 {
            fidgetTime += dt
            if fidget == 14 && !sneezed && fidgetTime > fidgetDur * 0.6 {
                sneezed = true
                emit(count: 3, sparkle: false, dx: facing * H * 0.25, dy: H * 0.7, spread: 0.6)
            }
            if fidgetTime > fidgetDur {
                fidget = 0
                nextFidget = CGFloat.random(in: 35...80) / (0.5 + m.fidget)
            }
        }

        // A triple spin that ends dizzy.
        if dizzyAfterSpin && spinLeft <= 0 {
            dizzyAfterSpin = false
            if mode == .idle {
                showEmote("✶")
                setMode(.dizzy)
            }
        }

        let target = targetPose(mouse: mouse)
        let quick = mode == .walking || mode == .cartwheel || mode == .dancing
        pose.approach(target, 1 - exp(-(quick ? 22 : 14) * dt))
        pose.roll = roll
        pose.spin = spin
        pose.prop = target.prop
        pose.twitch = target.twitch
        body.apply(pose: pose, clip: clipName(), dt: dt,
                   showProp: (activity == .tool || hobbyTime > 0) && mode == .idle, speed: speedX, time: t)

        shadowAlpha += ((grounded ? 0.22 : 0) - shadowAlpha) * min(1, 10 * dt)
        shadow.opacity = shadowAlpha

        if emoteTime > 0 {
            emoteTime -= dt
            let progress = 1 - max(emoteTime, 0) / 1.7
            let pop = min(1, progress * 8)
            emote.position = v3(H * 0.3, H * 1.05 + 24 * progress, 60)
            emote.scale = v3(pop, pop, pop)
            emote.opacity = min(1, max(emoteTime, 0) * 3)
        } else {
            emote.opacity = 0
        }
    }

    func syncNode(origin: CGPoint) {
        node.position = v3(pos.x - origin.x, pos.y - origin.y, zIndex)
    }

    private func clipName() -> String {
        switch mode {
        case .walking: return gait == .run ? "run" : "walk"
        case .cartwheel: return "run"
        case .crouching, .jumping, .falling, .landing: return "jump"
        case .dancing: return "wave"
        default: return gesture == "wave" ? "wave" : "idle"
        }
    }

    /// Called when a walk reaches where it was going.
    private func arrive() {
        let m = sheet.motion
        let towardBuddy: CGFloat = (buddy?.pos.x ?? pos.x + facing) >= pos.x ? 1 : -1
        switch errand {
        case .greet:
            facing = towardBuddy
            play("wave")
            showEmote("♪")
            buddy?.greeted(from: pos.x)
            idleFor = 2.6
            setMode(.idle)
        case .tag:
            facing = towardBuddy
            buddy?.tagged(from: pos.x)
            idleFor = 1.4
            hop(height: body.height * 0.3, withFlip: false)
        case .lap:
            if lapsLeft > 1 {
                // Far end reached: turn and sprint home.
                lapsLeft -= 1
                walkTarget = lapHome
                facing = walkTarget >= pos.x ? 1 : -1
                setMode(.walking)
                return
            }
            lapsLeft = 0
            skidSpeed = m.speed * 1.6
            setMode(.skidding)
            play("pump")
        case .none, .cursor, .flee:
            if tapWhenThere {
                tapWhenThere = false
                idleFor = 2.5
                setMode(.idle)
                play("tap")
            } else if gait == .run {
                skidSpeed = m.speed * 1.6
                setMode(.skidding)
            } else {
                idleFor = CGFloat.random(in: 6...14) / max(m.tempo, 0.5)
                if edgeSide != 0 {
                    if platformID != 0 {
                        facing = edgeSide
                        peekTime = 1.4
                        idleFor = max(idleFor, 1.8)
                    } else {
                        facing = -edgeSide
                    }
                }
                setMode(.idle)
            }
        }
        errand = .none
        buddy = nil
    }

    /// Picks what to do next. The odds come from the character's motion style.
    private func decide(world: World, mouse: CGPoint, others: [SprytCharacter]) {
        let m = sheet.motion
        let H = body.height
        // Nobody around: settle down, then doze off. Sooner at night.
        // With a workspace open, home is the top of that window. Go there, and stay there.
        if let home = homePlatform, platformID != home,
           let spot = world.spot(on: home, near: pos.x, clearance: H) {
            let d = hypot(spot.x - pos.x, spot.y - pos.y)
            facing = spot.x >= pos.x ? 1 : -1
            launch(to: spot, platform: home, apex: max(0, spot.y - pos.y) + 50 + d * 0.12, withFlip: false)
            return
        }

        // The person is working in this character's window: sit on its edge and watch, most of the time.
        if perched && homePlatform == platformID && activity == .none && CGFloat.random(in: 0...1) < 0.6 {
            sitFor = CGFloat.random(in: 8...16)
            setMode(.sitting)
            return
        }

        // Left alone for a while: get drowsy and sit, then fall asleep until someone comes by.
        let sleepAfter = max(20, sheet.sleepAfter ?? 180)
        if activity == .none && (userIdle > (night ? 200 : 420) || sinceInteraction > sleepAfter) {
            napTimer = 0.5
            setMode(.napping)
            return
        }
        if activity == .none && sinceInteraction > sleepAfter * 0.7 {
            sitFor = max(4, sleepAfter - sinceInteraction)
            setMode(.sitting)
            return
        }
        if activity == .none && userIdle > (night ? 80 : 150) {
            sitFor = CGFloat.random(in: 20...40)
            setMode(.sitting)
            return
        }
        let (lo, hi) = limits(world)
        let roomy = hi - lo >= 30
        let cheerful = mood == "happy" || mood == "playful" || mood == "excited"

        // Staying put is the default. A character only goes somewhere now and then, less often while
        // the person is busy working, and never straight after it has just moved.
        let working = userIdle < 4
        var urge: CGFloat = 0.16 * max(0.5, min(1.6, m.tempo))
        if isSpecialist { urge *= 0.6 }
        if working { urge *= 0.35 }
        if sinceMoved > 120 { urge *= 2.5 }   // time to stretch the legs
        if sinceMoved < 8 { urge = 0 }
        let setPieceDue = nextBig <= 0 && roomy && !working
        if !setPieceDue && CGFloat.random(in: 0...1) > urge {
            if sinceMoved > 12 && CGFloat.random(in: 0...1) < (isSpecialist ? 0.35 : 0.22) {
                sitFor = CGFloat.random(in: 20...50)
                setMode(.sitting)
            } else {
                idleFor = CGFloat.random(in: 6...14)
            }
            return
        }

        var r = CGFloat.random(in: 0...1)

        // Jump to another surface.
        let atHome = homePlatform != nil && homePlatform == platformID
        let pJump = atHome ? 0 : 0.12 * m.jumpiness
        if r < pJump {
            if let j = world.jumpTarget(from: pos, excluding: platformID, clearance: H),
               !taken(j.point.x, on: j.id, others: others) {
                let d = hypot(j.point.x - pos.x, j.point.y - pos.y)
                facing = j.point.x >= pos.x ? 1 : -1
                let wantsFlip = d > 220 && CGFloat.random(in: 0...1) < m.jumpiness * 0.6
                // Farther jumps need a higher arc so the sideways speed stays believable.
                let apex = max(0, j.point.y - pos.y) + 40 + d * 0.14
                launch(to: j.point, platform: j.id, apex: apex, withFlip: wantsFlip)
                return
            }
        }
        r -= pJump

        // Chase the cursor.
        let someoneChasing = others.contains(where: { $0 !== self && $0.chasingCursor })
        let cursorNear = cursorOnScreen && !someoneChasing
            && abs(mouse.x - pos.x) < 900 && abs(mouse.y - pos.y) < 600 && mouseStill < 2
        let pCursor: CGFloat = cursorNear && roomy && !isSpecialist && !working ? 0.05 * (0.5 + m.jumpiness) : 0
        if r >= 0 && r < pCursor {
            errand = .cursor
            chaseTime = CGFloat.random(in: 4...7)
            gait = .run
            walkTarget = clamp(mouse.x, lo, hi)
            facing = walkTarget >= pos.x ? 1 : -1
            setMode(.walking)
            return
        }
        r -= pCursor

        // Go and bother a neighbour.
        let neighbour = others.first(where: {
            $0 !== self && $0.surfaceID == platformID && $0.isFree
                && abs($0.pos.x - pos.x) < 800 && abs($0.pos.x - pos.x) > H * 1.3
        })
        let pSocial: CGFloat = neighbour != nil && roomy ? 0.10 : 0
        if r >= 0 && r < pSocial, let other = neighbour {
            buddy = other
            if !isSpecialist && cheerful && !working && CGFloat.random(in: 0...1) < 0.3 {
                errand = .tag
                gait = .run
            } else {
                errand = .greet
                gait = cheerful ? .skip : .walk
            }
            walkTarget = other.pos.x
            facing = walkTarget >= pos.x ? 1 : -1
            setMode(.walking)
            return
        }
        r -= pSocial

        // Set pieces: rare on purpose, so catching one feels like something. Never the same one twice running.
        if setPieceDue {
            nextBig = CGFloat.random(in: 600...1200) / (0.7 + 0.4 * m.jumpiness)
            var choice = 0
            if isCoder {
                // The programmer's set pieces are about the work, not acrobatics.
                choice = bigHistory.last == 7 ? 8 : 7
                bigHistory.append(choice)
                if bigHistory.count > 3 { bigHistory.removeFirst() }
            } else if isWriter {
                // The writer declaims a line aloud, or loses an afternoon to scribbling.
                choice = bigHistory.last == 9 ? 10 : 9
                bigHistory.append(choice)
                if bigHistory.count > 3 { bigHistory.removeFirst() }
            } else {
                choice = pick(6, avoiding: &bigHistory, keep: 3)
            }
            switch choice {
            case 7:
                // Eureka: a jump and a fist pump, bulbs blazing.
                showEmote("!")
                flashTime = 1.4
                hop(height: H * 0.6, withFlip: false)
                gesture = "pump"
                gestureTime = 2.6
                return
            case 9:
                // Reciting to an imaginary audience.
                showEmote("♪")
                gesture = "recite"
                gestureTime = 4.5
                idleFor = 5
                return
            case 10:
                // A long stretch of scribbling.
                workKind = "write"
                workTime = 0
                hobbyTime = CGFloat.random(in: 12...18)
                idleFor = 1
                return
            case 8:
                // A long, furious coding sprint.
                workKind = "edit"
                workTime = 0
                hobbyTime = CGFloat.random(in: 12...18)
                idleFor = 1
                return
            case 1:
                startDance(seconds: CGFloat.random(in: 4...6))
                return
            case 2:
                // A leaping forward flip. Flips only ever happen inside a real jump.
                let distance = H * CGFloat.random(in: 1.6...2.4)
                var dir: CGFloat = Bool.random() ? 1 : -1
                if pos.x + dir * distance < lo || pos.x + dir * distance > hi { dir = -dir }
                if pos.x + dir * distance >= lo && pos.x + dir * distance <= hi {
                    facing = dir
                    launch(to: CGPoint(x: pos.x + dir * distance, y: pos.y), platform: platformID, apex: H * 0.95, withFlip: true)
                    return
                }
            case 3:
                // Victory lap: sprint to the far end and back, arms in the air.
                lapHome = pos.x
                lapsLeft = 2
                let farEnd = (pos.x - lo) > (hi - pos.x) ? lo : hi
                walkTarget = clamp(farEnd, pos.x - 420, pos.x + 420)   // a short lap, not the width of the screen
                facing = walkTarget >= pos.x ? 1 : -1
                gait = .run
                errand = .lap
                showEmote("♪")
                setMode(.walking)
                return
            case 4:
                // Moonwalk: glide backwards.
                let distance = min(H * 3, (hi - lo) * 0.6)
                var dir: CGFloat = Bool.random() ? 1 : -1
                if pos.x + dir * distance < lo || pos.x + dir * distance > hi { dir = -dir }
                walkTarget = clamp(pos.x + dir * distance, lo, hi)
                facing = walkTarget >= pos.x ? -1 : 1   // facing away from where he is going
                backward = true
                gait = .walk
                errand = .none
                setMode(.walking)
                return
            case 5:
                // Three hops, each higher, the last with a flip.
                comboHops = 2
                hop(height: H * 0.3, withFlip: false)
                return
            default:
                // Spin until dizzy.
                spinLeft = 6 * CGFloat.pi
                dizzyAfterSpin = true
                idleFor = 2.2
                return
            }
        }

        let pSit: CGFloat = isCoder ? 0.3 : (isWriter ? 0.2 : 0.09)
        if r >= 0 && r < pSit {
            sitFor = CGFloat.random(in: 4...9) * (isSpecialist ? 2 : 1)
            setMode(.sitting)
            return
        }
        r -= pSit

        if r >= 0 && r < 0.45 && roomy {
            var heading: CGFloat = Bool.random() ? 1 : -1
            let stride = CGFloat.random(in: 80...280)
            let margin = H * 1.6
            if pos.x - lo < margin { heading = 1 } else if hi - pos.x < margin { heading = -1 }
            var target = pos.x + heading * stride
            if target < lo || target > hi { target = pos.x - heading * stride }
            if platformID == 0 {
                // On the floor, head back toward this character's own stretch if it has strayed.
                let width = hi - lo
                let center = lo + width * zone
                let half = max(120, width * zoneSpan * 0.42)
                if abs(pos.x - center) > half || abs(target - center) > half {
                    let home = center + CGFloat.random(in: -half...half) * 0.8
                    let reach = min(abs(home - pos.x), 300)
                    target = pos.x + (home >= pos.x ? reach : -reach)
                }
            }
            // Drift toward wherever the person is working; more so the closer you are.
            let bond = clamp(CGFloat(session.affection) / 20, 0, 1)
            if !isSpecialist && cursorOnScreen && userIdle < 30 && abs(pos.x - mouse.x) > 520
                && CGFloat.random(in: 0...1) < 0.25 + 0.3 * bond {
                target = mouse.x + orbit + CGFloat.random(in: -90...90)
                if target < lo + H || target > hi - H { target = mouse.x - orbit }
                target = clamp(target, min(lo + H, hi), max(hi - H, lo))
            }
            target = clamp(target, lo, hi)
            if abs(target - pos.x) < 30 { target = CGFloat.random(in: lo...hi) }
            target = spaced(target, others: others, lo: lo, hi: hi)
            if taken(target, on: platformID, others: others) {
                // Nowhere clear to go: stay put.
                idleFor = CGFloat.random(in: 6...12)
                return
            }
            walkTarget = target
            facing = target >= pos.x ? 1 : -1
            errand = .none
            let far = abs(target - pos.x) > 320
            let g: CGFloat = isSpecialist ? 0.6 : CGFloat.random(in: 0...1)   // specialists just walk
            if g < 0.12 + 0.28 * m.jumpiness + (far ? 0.15 : 0) {
                gait = .run
            } else if g < 0.12 + 0.28 * m.jumpiness + (far ? 0.15 : 0) + (cheerful ? 0.3 : 0.1) * m.fidget {
                gait = .skip
            } else if g > 0.92 - (m.tempo < 0.9 ? 0.1 : 0) {
                gait = .sneak
            } else {
                gait = .walk
            }
            setMode(.walking)
            return
        }

        idleFor = CGFloat.random(in: 5...10)
    }

    // MARK: Pose for this frame

    private func targetPose(mouse: CGPoint) -> Pose {
        var p = Pose()
        let m = sheet.motion
        let H = body.height
        let L = body.legLength
        let breathe = sin(t * 2.2)

        p.yaw = facing * 0.5
        p.squash = 1 + 0.012 * breathe
        p.armOutL = 0.12 + 0.02 * breathe
        p.armOutR = 0.12 + 0.02 * breathe
        p.tilt = m.sway * 0.4 * sin(t * 0.7)
        p.lean = m.lean * 0.4

        switch mode {
        case .walking:
            let s = sin(phase)
            let c = cos(phase)
            p.yaw = facing * 1.15
            switch gait {
            case .walk:
                p.legL = m.stride * s
                p.legR = -m.stride * s
                p.kneeL = 1.2 * m.stride * max(0, c)
                p.kneeR = 1.2 * m.stride * max(0, -c)
                p.armL = -m.armSwing * s
                p.armR = m.armSwing * s
                p.elbowL = 0.25 + 0.35 * max(0, -s)
                p.elbowR = 0.25 + 0.35 * max(0, s)
                p.bodyY = m.bounce * (abs(c) - 0.6)
                p.lean = m.lean
                p.twist = 0.15 * m.armSwing * s
                p.tilt = m.sway * s
                p.headPitch = -m.lean * 0.6
            case .run:
                let a = min(0.95, m.stride * 1.6)
                let arm = min(1.3, m.armSwing * 1.5 + 0.3)
                p.yaw = facing * 1.25
                p.legL = a * s + 0.15
                p.legR = -a * s + 0.15
                p.kneeL = 0.3 + 1.5 * a * max(0, c)
                p.kneeR = 0.3 + 1.5 * a * max(0, -c)
                p.armL = -arm * s
                p.armR = arm * s
                p.elbowL = 1.5
                p.elbowR = 1.5
                p.bodyY = (m.bounce + 2) * 1.8 * (abs(c) - 0.5)
                p.lean = m.lean + 0.3
                p.twist = 0.2 * s
                p.headPitch = -0.2
            case .skip:
                p.legL = max(0, s) - 0.2 * max(0, -s)
                p.legR = max(0, -s) - 0.2 * max(0, s)
                p.kneeL = 1.5 * max(0, s)
                p.kneeR = 1.5 * max(0, -s)
                p.armL = -0.9 * s
                p.armR = 0.9 * s
                p.elbowL = 0.6
                p.elbowR = 0.6
                p.bodyY = (m.bounce + 2) * 2.6 * abs(s)
                p.headTilt = 0.12 * s
                p.lean = 0.02
            case .sneak:
                p.legL = m.stride * 1.1 * s
                p.legR = -m.stride * 1.1 * s
                p.kneeL = 0.5 + 1.6 * m.stride * max(0, c)
                p.kneeR = 0.5 + 1.6 * m.stride * max(0, -c)
                p.armL = 0.7
                p.armR = 0.7
                p.elbowL = 1.7 + 0.1 * s
                p.elbowR = 1.7 - 0.1 * s
                p.bodyY = -L * 0.1
                p.lean = 0.32
                p.headYaw = 0.5 * sin(t * 2.2)
                p.headPitch = -0.25
            }
            if errand == .lap {
                // Victory lap: both arms in the air.
                p.armOutL = 2.5 + 0.2 * s
                p.armOutR = 2.5 - 0.2 * s
                p.armL = 0
                p.armR = 0
                p.elbowL = 0.3
                p.elbowR = 0.3
                p.headPitch = -0.25
            }
            if backward {
                // Moonwalk: feet slide, body leans back, head bobs.
                p.legL = 0.35 * s
                p.legR = -0.35 * s
                p.kneeL = 0.5 * max(0, -c)
                p.kneeR = 0.5 * max(0, c)
                p.lean = -0.12
                p.bodyY = 1.5 * sin(phase * 2)
                p.armL = 0.4 * s
                p.armR = -0.4 * s
                p.headPitch = 0.1 * sin(phase * 2)
            }
            if gait == .run && modeTime < 0.16 {
                // Anticipation: rock back before taking off.
                p.lean = -0.32
                p.legL = 0.35
                p.legR = -0.4
                p.kneeL = 0.3
                p.kneeR = 0.5
                p.armL = 0.9
                p.armR = -0.9
                p.elbowL = 1.5
                p.elbowR = 1.5
                p.bodyY = -L * 0.06
                p.squash = 0.92
            }

        case .skidding:
            p.yaw = facing * 1.15
            p.lean = -0.35
            p.legL = 0.55
            p.legR = 0.25
            p.kneeL = 0.1
            p.kneeR = 0.5
            p.armOutL = 0.9
            p.armOutR = 0.9
            p.armL = 0.4
            p.armR = 0.4
            p.bodyY = -L * 0.06

        case .crouching:
            p.legL = 0.6
            p.legR = 0.6
            p.kneeL = 1.2
            p.kneeR = 1.2
            p.bodyY = -L * (1 - cos(0.6))
            p.squash = 0.76
            p.armL = -0.8
            p.armR = -0.8
            p.lean = flip ? 0.4 : 0.25
            p.yaw = jumpTo.x == jumpFrom.x ? 0.2 * facing : facing * 1.0

        case .jumping:
            let air = min(modeTime, jumpDur)
            let s = air / jumpDur
            p.yaw = jumpTo.x == jumpFrom.x ? 0.2 * facing : facing * 1.0
            // Stretch along the direction of travel: most at take-off and touchdown, none at the top.
            p.squash = 1 + clamp(abs(jumpVY - gravity * air) / 5500, 0, 0.18)
            if flip {
                // Arms up at take-off, pulled into a ball mid-air, opened out again to land.
                let u = tuck(at: s)
                p.legL = 0.1 + 1.25 * u
                p.legR = 0.1 + 1.25 * u
                p.kneeL = 0.15 + 1.8 * u
                p.kneeR = 0.15 + 1.8 * u
                p.armOutL = 2.5 * (1 - u) + 0.2 * u
                p.armOutR = 2.5 * (1 - u) + 0.2 * u
                p.armL = 1.0 * u
                p.armR = 1.0 * u
                p.elbowL = 0.2 + 1.4 * u
                p.elbowR = 0.2 + 1.4 * u
                p.lean = 0.3 * u
                p.squash = 1 + (p.squash - 1) * (1 - u)
            } else {
                p.armOutL = s < 0.6 ? 2.5 : 1.4
                p.armOutR = s < 0.6 ? 2.5 : 1.4
                p.legL = 0.55
                p.legR = 0.25
                p.kneeL = 1.1
                p.kneeR = 0.6
                p.lean = 0.1
            }

        case .falling:
            p.squash = 1 + clamp(abs(vel.dy) / 9000, 0, 0.16)
            p.armOutL = 2.2 + 0.3 * sin(t * 18)
            p.armOutR = 2.2 + 0.3 * sin(t * 18 + 1.5)
            p.legL = 0.3 * sin(t * 14)
            p.legR = -0.3 * sin(t * 14)
            p.kneeL = 0.4
            p.kneeR = 0.4
            p.eyeOpen = 1.2

        case .landing:
            // Knees absorb the landing in proportion to how fast it came down.
            let k = max(0, 1 - modeTime / landTime) * clamp(landImpact / 900, 0.4, 1.2)
            p.legL = 0.6 * k
            p.legR = 0.6 * k
            p.kneeL = 1.2 * k
            p.kneeR = 1.2 * k
            p.bodyY = -L * (1 - cos(0.6 * k))
            p.squash = 1 - 0.3 * k
            p.armOutL = 0.12 + 0.7 * k
            p.armOutR = 0.12 + 0.7 * k

        case .offstage:
            // Leaning in around the edge of the screen, one hand on it.
            p.yaw = -offSide * 0.3
            p.tilt = offSide * 0.32 * peekOut
            p.headTilt = offSide * 0.15 * peekOut
            let reach: CGFloat = offWave > 0 ? 2.4 + 0.35 * sin(t * 14) : 1.5
            let bend: CGFloat = offWave > 0 ? 0.5 + 0.3 * sin(t * 14 + 1) : 1.2
            if offSide > 0 {
                p.armOutL = reach
                p.elbowL = bend
            } else {
                p.armOutR = reach
                p.elbowR = bend
            }
            p.eyeOpen = 1.1

        case .held:
            p.yaw = 0
            p.armOutL = 2.7
            p.armOutR = 2.7
            p.legL = dangle
            p.legR = dangle * 0.7
            p.kneeL = 0.3
            p.kneeR = 0.3
            p.tilt = dangle * 0.5
            p.squash = 1.06
            p.eyeOpen = 1.2

        case .sitting, .napping:
            p.yaw = facing * 0.6
            p.legL = 1.5 + 0.12 * sin(t * 2.5)
            p.legR = 1.4 - 0.12 * sin(t * 2.5)
            p.kneeL = 0.15 + 0.3 * max(0, sin(t * 2.5))
            p.kneeR = 0.1 + 0.3 * max(0, -sin(t * 2.5))
            p.bodyY = -L * 0.92
            p.armL = -0.3
            p.armR = -0.3
            p.armOutL = 0.3
            p.armOutR = 0.3
            p.lean = -0.08
            if perched && mode == .sitting {
                // Facing out, looking down into the window.
                p.yaw = 0
                p.headPitch = 0.32
                p.lean = 0.1
            }
            if mode == .napping {
                p.legL = 1.5
                p.legR = 1.4
                p.kneeL = 0.15
                p.kneeR = 0.1
                p.headPitch = 0.5
                p.eyeOpen = 0.05
                p.squash = 1 + 0.03 * sin(t * 1.1)
                p.lean = 0.12
            }

        case .dizzy:
            p.yaw = 0
            p.headYaw = 0.5 * sin(t * 9)
            p.headTilt = 0.3 * cos(t * 9)
            p.tilt = 0.16 * sin(t * 4.5)
            p.armOutL = 0.8 + 0.3 * sin(t * 4.5)
            p.armOutR = 0.8 - 0.3 * sin(t * 4.5)
            p.legL = 0.12 * sin(t * 4.5)
            p.legR = -0.12 * sin(t * 4.5)
            p.eyeOpen = 0.5

        case .dancing:
            let beat = t * 8
            p.yaw = 0.5 * sin(t * 2)
            p.bodyY = (m.bounce + 3) * 1.4 * abs(sin(beat))
            p.tilt = 0.18 * sin(beat / 2)
            p.armOutL = 1.6 + 0.9 * sin(beat)
            p.armOutR = 1.6 - 0.9 * sin(beat)
            p.elbowL = 1.0
            p.elbowR = 1.0
            p.legL = 0.3 * max(0, sin(beat / 2))
            p.legR = 0.3 * max(0, -sin(beat / 2))
            p.kneeL = 0.6 * max(0, sin(beat / 2))
            p.kneeR = 0.6 * max(0, -sin(beat / 2))
            p.headTilt = 0.15 * sin(beat / 2)
            p.eyeOpen = 0.75

        case .cartwheel:
            // Tucked into a ball, low to the ground.
            p.yaw = facing * 1.2
            p.legL = 1.35
            p.legR = 1.35
            p.kneeL = 1.95
            p.kneeR = 1.95
            p.armL = 1.0
            p.armR = 1.0
            p.elbowL = 1.6
            p.elbowR = 1.6
            p.armOutL = 0.2
            p.armOutR = 0.2
            p.lean = 0.3
            p.bodyY = -H * 0.14

        case .idle:
            switch fidget {
            case 1:   // look around
                p.headYaw = 0.7 * sin(fidgetTime * 3)
            case 2:   // scratch head
                p.armOutR = 2.3
                p.armR = 0.3
                p.elbowR = 2.2 + 0.25 * sin(fidgetTime * 16)
                p.headTilt = -0.15
            case 3:   // stretch
                p.armOutL = 2.8
                p.armOutR = 2.8
                p.lean = -0.18
                p.bodyY = 2
                p.eyeOpen = 0.3
            case 4:   // tap a foot
                p.legR = 0.28 * abs(sin(fidgetTime * 8))
                p.armL = -0.4
                p.armR = -0.4
            case 5:   // twirl
                p.armOutL = 1.5
                p.armOutR = 1.5
                p.bodyY = 3
            case 6:   // bounce on the spot
                p.bodyY = (m.bounce + 3) * abs(sin(fidgetTime * 9))
                p.armL = 0.5
                p.armR = 0.5
                p.elbowL = 1.4
                p.elbowR = 1.4
            case 7:   // yawn and stretch
                let e = sin(CGFloat.pi * min(1, fidgetTime / fidgetDur))
                p.armOutL = 0.12 + 2.5 * e
                p.armOutR = 0.12 + 2.3 * e
                p.lean = -0.2 * e
                p.headPitch = -0.25 * e
                p.eyeOpen = 1 - 0.9 * e
                p.squash = 1 + 0.05 * e
            case 8:   // check the wrist, tap a foot
                p.armL = 0.9
                p.elbowL = 1.7
                p.headPitch = 0.3
                p.headYaw = -0.3
                p.legR = 0.2 * abs(sin(fidgetTime * 9))
            case 9:   // dust off a shoulder
                p.armR = 0.9
                p.elbowR = 2.2 + 0.2 * sin(fidgetTime * 18)
                p.armOutR = -0.2
                p.headYaw = -0.45
                p.headPitch = 0.15
            case 10:  // balance on one foot
                p.legR = 0.6
                p.kneeR = 1.2
                p.armOutL = 1.3 + 0.2 * sin(fidgetTime * 5)
                p.armOutR = 1.3 - 0.2 * sin(fidgetTime * 5)
                p.tilt = 0.12 * sin(fidgetTime * 5)
            case 11:  // wave at the cursor
                p.yaw = 0
                p.armOutR = 2.5 + 0.35 * sin(t * 14)
                p.elbowR = 0.5 + 0.3 * sin(t * 14 + 1)
            case 12:  // kick a pebble
                p.legR = 0.75 * sin(min(fidgetTime * 4, CGFloat.pi))
                p.kneeR = 0.3
                p.headPitch = 0.3
                p.armL = 0.3
                p.armR = -0.3
            case 13:  // hand to ear, listening
                p.armOutR = 1.7
                p.armR = 0.2
                p.elbowR = 2.3
                p.headTilt = 0.25
                p.lean = 0.08
            case 14:  // sneeze: wind up, then snap forward
                if fidgetTime < fidgetDur * 0.6 {
                    let w = fidgetTime / (fidgetDur * 0.6)
                    p.headPitch = -0.4 * w
                    p.lean = -0.12 * w
                    p.eyeOpen = 1 - 0.7 * w
                } else {
                    p.headPitch = 0.5
                    p.lean = 0.25
                    p.squash = 0.9
                    p.eyeOpen = 0.06
                }
            case 15:  // shadow-box
                let jab = sin(fidgetTime * 11)
                p.armL = 1.3 * max(0, jab)
                p.armR = 1.3 * max(0, -jab)
                p.elbowL = 1.7 - 1.5 * max(0, jab)
                p.elbowR = 1.7 - 1.5 * max(0, -jab)
                p.bodyY = 2 * abs(sin(fidgetTime * 11))
                p.lean = 0.12
            default:
                break
            }
            if fidget != 0 && fidget != 5 {
                // The same move never looks identical twice.
                p.bodyY *= fidgetAmp
                p.headYaw *= fidgetAmp
                p.tilt *= fidgetAmp
            }
        }

        if mode == .idle && peekTime > 0 && activity == .none {
            // Leaning out to look over the ledge, arms back for balance.
            p.yaw = facing * 1.05
            p.lean = 0.32
            p.headPitch = 0.4
            p.armL = -0.6
            p.armR = -0.6
            p.armOutL = 0.35
            p.armOutR = 0.35
            p.legL = -0.1
            p.legR = 0.15
            p.bodyY = -L * 0.03
        }

        let acting: Activity = (activity == .none && hobbyTime > 0) ? .tool : activity
        if mode == .idle {
            switch acting {
            case .thinking:
                p.yaw = facing * 0.35
                p.armR = 0.95
                p.elbowR = 2.2
                p.armOutR = 0.05
                p.armL = 0.2
                p.elbowL = 1.3
                p.headPitch = 0.12
                p.headTilt = 0.15
                p.legL = 0.2 * max(0, sin(t * 7))
            case .talking:
                p.yaw = 0
                p.armR = 0.7 + 0.25 * sin(t * 5.5)
                p.elbowR = 1.3 + 0.3 * sin(t * 4.1 + 1)
                p.armOutR = 0.35
                p.armL = 0.4 + 0.15 * sin(t * 3.7)
                p.elbowL = 1.1
                p.headPitch = 0.05 * sin(t * 6)
                p.headTilt = 0.08 * sin(t * 2.3)
                p.bodyY = 1.2 * sin(t * 5.5)
            case .tool:
                p.yaw = facing * 0.8
                let waitingOnIt = (workKind == "run" || workKind == "build" || workKind == "test") && workTime > 1.4
                if workKind == "write" {
                    p.prop = 2
                    if sin(t * 0.55) > 0.72 {
                        // Stuck on a word: pen to the chin, eyes to the sky.
                        p.armL = 0.6
                        p.elbowL = 1.5
                        p.armR = 0.95
                        p.elbowR = 2.2
                        p.headPitch = -0.3
                        p.headTilt = 0.15
                    } else {
                        p.armL = 0.85
                        p.elbowL = 1.6
                        p.armR = 0.9 + 0.05 * sin(t * 19)
                        p.elbowR = 1.5 + 0.18 * sin(t * 19)
                        p.headPitch = 0.3
                        p.lean = 0.08
                    }
                } else if workKind == "read" {
                    // Holding the page up and scanning it line by line.
                    p.prop = 2
                    p.armL = 0.85
                    p.armR = 0.85
                    p.elbowL = 1.6
                    p.elbowR = 1.6
                    p.headPitch = 0.22 + 0.1 * sin(t * 0.9)
                    p.headYaw = 0.22 * sin(t * 2.4)
                    p.lean = 0.06
                } else if workKind == "search" || workKind == "web" {
                    // Hand shading the eyes, sweeping the horizon.
                    p.yaw = 0.5 * sin(t * 0.8)
                    p.armOutR = 1.2
                    p.armR = 0.9
                    p.elbowR = 2.0
                    p.headYaw = 0.5 * sin(t * 1.3)
                    p.lean = 0.12
                    p.armL = -0.3
                } else if waitingOnIt && workKind == "test" {
                    // Tests running: biting nails, knees jittering.
                    p.prop = 1
                    p.yaw = facing * 0.5
                    p.armR = 1.1
                    p.elbowR = 2.3
                    p.armOutR = 0.05
                    p.legL = 0.08 * sin(t * 20)
                    p.legR = -0.08 * sin(t * 20)
                    p.headPitch = 0.2
                    p.headTilt = 0.08 * sin(t * 3)
                } else if waitingOnIt {
                    // Something is running: arms folded, foot tapping, eyes on the screen.
                    p.prop = 1
                    p.yaw = facing * 0.55
                    p.armL = 0.6
                    p.armR = 0.6
                    p.elbowL = 2.0
                    p.elbowR = 2.0
                    p.armOutL = -0.25
                    p.armOutR = -0.25
                    p.legR = 0.22 * abs(sin(t * 7))
                    p.headPitch = 0.25
                } else {
                    // Typing. Editing is faster and more hunched than starting a command.
                    let rate: CGFloat = workKind == "edit" ? 26 : 20
                    p.prop = 1
                    p.armL = 0.95
                    p.armR = 0.95
                    p.elbowL = 1.2 + 0.25 * sin(t * rate)
                    p.elbowR = 1.2 - 0.25 * sin(t * rate)
                    p.headPitch = workKind == "edit" ? 0.36 : 0.3
                    p.legL = 0.35
                    p.legR = 0.35
                    p.kneeL = 0.7
                    p.kneeR = 0.7
                    p.bodyY = -L * (1 - cos(0.35))
                    p.lean = workKind == "edit" ? 0.22 : 0.15
                }
            case .error:
                p.yaw = 0
                p.armR = 1.3
                p.elbowR = 2.4
                p.armOutR = 0
                p.headPitch = 0.45
                p.lean = 0.18
                p.squash = 0.96
                p.eyeOpen = 0.1
            case .waiting:
                p.yaw = 0
            case .asking:
                // Hand up, waiting for a yes or no.
                p.yaw = 0
                p.armOutR = 2.6
                p.armR = 0.1
                p.elbowR = 0.25 + 0.1 * sin(t * 5)
                p.bodyY = 1.5 * abs(sin(t * 3))
                p.headTilt = 0.12
            case .none:
                break
            }
        }

        // Turn to face whoever is hovering.
        let headPoint = CGPoint(x: pos.x, y: pos.y + H * 0.8)
        let dx = mouse.x - headPoint.x
        let dy = mouse.y - headPoint.y
        if attention && mode == .idle && activity != .tool {
            p.yaw = clamp(dx / 600, -0.4, 0.4)
        }

        // Eyes and head follow the cursor when it is close.
        let near = hypot(dx, dy) < 520
        let calm = mode == .idle || mode == .walking || mode == .sitting || mode == .landing || mode == .crouching
        if (attention || near) && calm && activity != .error {
            let worldYaw = clamp(dx / 260, -1, 1)
            p.headYaw += clamp(worldYaw - p.yaw, -1.1, 1.1) * 0.9
            p.headPitch += clamp(-dy / 420, -0.45, 0.45)
        }

        // One-shot gestures chosen by the bot's reply or by a neighbour.
        if gestureTime > 0 && (mode == .idle || mode == .landing) {
            switch gesture {
            case "wave":
                p.armOutR = 2.5 + 0.35 * sin(t * 14)
                p.armR = 0.1
                p.elbowR = 0.5 + 0.3 * sin(t * 14 + 1)
            case "nod":
                p.headPitch += 0.25 * sin(t * 12)
            case "shrug":
                p.armOutL = 0.6
                p.armOutR = 0.6
                p.armL = 0.3
                p.armR = 0.3
                p.elbowL = 1.7
                p.elbowR = 1.7
                p.headTilt = 0.2
                p.bodyY += 2
            case "kiss":
                // Hand to the mouth, then out toward whoever it is for.
                if gestureTime > 1.25 {
                    p.armR = 1.1
                    p.elbowR = 2.4
                    p.headTilt = 0.12
                } else {
                    p.armR = 1.35
                    p.elbowR = 0.3
                }
            case "think":
                p.armR = 0.95
                p.elbowR = 2.2
                p.headTilt = 0.15
            case "pump":
                // Fist pump.
                p.yaw = 0
                p.armR = 2.3
                p.armOutR = 0.3
                p.elbowR = 0.9 + 0.7 * sin(t * 13)
                p.bodyY += 4 * abs(sin(t * 13))
                p.lean = -0.1
            case "facepalm":
                p.yaw = 0
                p.armR = 1.3
                p.elbowR = 2.4
                p.armOutR = 0
                p.headPitch = 0.45
                p.lean = 0.18
                p.eyeOpen = 0.1
            case "recite":
                // One hand on the chest, the other sweeping out to the audience.
                p.yaw = 0.3 * sin(t * 0.9)
                p.armL = 0.7
                p.elbowL = 2.0
                p.armOutL = -0.1
                p.armOutR = 1.5 + 0.6 * sin(t * 2.4)
                p.armR = 0.5
                p.elbowR = 0.4
                p.headPitch = -0.18
                p.lean = -0.06
            case "tap":
                // Leaning out to tap on the glass.
                p.yaw = 0
                p.armR = 1.5 + 0.2 * sin(t * 12)
                p.elbowR = 0.15
                p.armOutR = 0.1
                p.lean = 0.18
                p.headTilt = 0.1
            default:
                break
            }
        }

        // Small gestures, layered over the current pose.
        if micro != 0 && (mode == .idle || mode == .sitting) && !petting {
            let e = sin(CGFloat.pi * min(1, microTime / microDur)) * microAmp
            switch micro {
            case 1:   // glance to one side
                p.headYaw += 0.5 * e * microSide
            case 2:   // glance up
                p.headPitch -= 0.3 * e
            case 3:   // tilt the head
                p.headTilt += 0.22 * e * microSide
            case 4:   // shift weight
                p.tilt += 0.08 * e * microSide
                p.kneeL += microSide > 0 ? 0.25 * e : 0
                p.kneeR += microSide < 0 ? 0.25 * e : 0
                p.bodyY -= e
            case 5:   // shoulders up and down
                p.bodyY += 2 * e
                p.armOutL += 0.15 * e
                p.armOutR += 0.15 * e
            case 6:   // wiggle a hand
                p.elbowR += 0.5 * e + 0.15 * e * sin(t * 24)
                p.armR += 0.25 * e
            case 7:   // tap a toe
                p.legR += 0.2 * e * abs(sin(t * 14))
            case 8:   // twitch the ears or antenna
                p.twitch = e
            case 9:   // a small sigh
                p.squash += 0.04 * e
                p.lean += 0.05 * e
            case 10:  // scrunch the face
                p.eyeOpen *= 1 - 0.4 * e
                p.headPitch -= 0.08 * e
            case 11:  // rock on the heels
                p.lean += 0.07 * sin(microTime / microDur * 2 * CGFloat.pi) * microAmp
            default:  // roll a shoulder
                p.armOutL += 0.25 * e
                p.twist += 0.1 * e * microSide
            }
        }

        // Being stroked: lean into the hand, eyes shut.
        if petting {
            p.eyeOpen = 0.12
            p.headTilt += clamp(dx / 200, -0.3, 0.3)
            p.tilt += clamp(dx / 400, -0.15, 0.15)
            p.bodyY += 1.5 * sin(t * 9)
            p.squash *= 0.97
            p.armOutL = 0.5
            p.armOutR = 0.5
        }
        if pokeTime > 0 {
            p.squash = 0.86
            p.armOutL = 1.3
            p.armOutR = 1.3
            p.eyeOpen = 1.25
        }
        // Poked once too often: turn away, arms folded.
        if sulk > 0 && mode == .idle {
            p.yaw = CGFloat.pi * 0.85 * facing
            p.armL = 0.6
            p.armR = 0.6
            p.elbowL = 2.0
            p.elbowR = 2.0
            p.armOutL = -0.3
            p.armOutR = -0.3
            p.headYaw = 0
            p.headPitch = 0.2
        }

        // Mood colours the resting face and posture.
        switch mood {
        case "happy", "excited", "playful":
            p.eyeOpen *= 0.75
        case "sorry":
            p.headPitch += 0.12
        case "curious":
            p.headTilt += 0.18
        case "proud":
            p.lean -= 0.08
        default:
            break
        }

        // Face: mood sets the baseline, then whatever is happening right now takes over.
        var smile: CGFloat = 0.25
        var mouth: CGFloat = 0
        var brow: CGFloat = 0
        var lift: CGFloat = 0
        var cock: CGFloat = 0
        var blush: CGFloat = 0
        var glow: CGFloat = 0.25
        switch mood {
        case "happy":
            smile = 0.8
        case "playful":
            smile = 0.7
            cock = 0.4
        case "excited":
            smile = 0.9
            mouth = 0.25
            lift = 0.5
            glow = 0.8
        case "sorry":
            smile = -0.6
            brow = -0.6
        case "curious":
            smile = 0.1
            cock = 0.8
            mouth = 0.12
        case "proud":
            smile = 0.6
            brow = 0.2
        default:
            break
        }
        switch mode {
        case .falling, .held:
            mouth = 0.85
            smile = 0
            lift = 1
        case .jumping, .crouching:
            mouth = mode == .jumping ? 0.4 : 0.1
            smile = 0.8
            lift = 0.6
        case .walking:
            if gait == .run {
                smile = 0.6
                mouth = 0.3
                brow = 0.35
            } else if gait == .skip {
                smile = 0.9
                mouth = 0.2
            } else if gait == .sneak {
                smile = -0.1
                brow = 0.3
                mouth = 0.1
            }
        case .skidding:
            mouth = 0.6
            lift = 0.8
            smile = 0
        case .dizzy:
            smile = -0.2 + 0.2 * sin(t * 9)
            mouth = 0.3
            brow = -0.4
        case .cartwheel:
            mouth = 0.7
            smile = 0
            lift = 1
        case .dancing:
            smile = 1
            mouth = 0.35
            glow = 1
        case .offstage:
            smile = offWave > 0 ? 0.9 : 0.4
            lift = 0.5
            cock = 0.5
        case .napping:
            smile = 0.1
            mouth = 0.15 + 0.1 * sin(t * 1.1)
            glow = 0.05
        default:
            break
        }
        if mode == .idle {
            switch activity {
            case .thinking:
                smile = 0
                cock = 1
                glow = 0.6 + 0.4 * sin(t * 5)
            case .talking:
                // Lips move while the words arrive.
                mouth = 0.15 + 0.55 * abs(sin(t * 13)) * (0.6 + 0.4 * sin(t * 3.1))
                glow = 0.7
            case .tool:
                brow = 0.4
                smile = 0.1
                glow = sin(t * 20) > 0 ? 1 : 0.3
            case .error:
                smile = -0.8
                brow = -0.8
                glow = 0.02
            case .waiting:
                glow = 0.5
            case .asking:
                smile = 0.2
                cock = 1
                lift = 0.4
                glow = 0.6 + 0.4 * sin(t * 6)
            case .none:
                break
            }
        }
        if gestureTime > 0 && gesture == "wave" { smile = max(smile, 0.85) }
        if petting {
            smile = 1
            mouth = 0
            blush = 1
            lift = 0.3
            glow = 0.9
        }
        if pokeTime > 0 {
            mouth = 0.9
            smile = 0
            lift = 1
        }
        if sulk > 0 {
            smile = -0.7
            brow = 0.9
            mouth = 0
        }
        if mode == .idle && fidget == 7 {
            mouth = 0.95 * sin(CGFloat.pi * min(1, fidgetTime / fidgetDur))   // the yawn
            smile = 0
        }
        if mode == .idle && fidget == 14 && fidgetTime >= fidgetDur * 0.6 { mouth = 0.8 }
        if mode == .idle && fidget == 15 { brow = 0.6 }
        if mode == .walking && errand == .lap {
            smile = 1
            mouth = 0.5
        }
        if gestureTime > 0 && gesture == "pump" {
            smile = 1
            mouth = 0.5
            lift = 0.5
        }
        if gestureTime > 0 && gesture == "recite" {
            mouth = 0.2 + 0.5 * abs(sin(t * 11)) * (0.6 + 0.4 * sin(t * 2.7))
            lift = 0.6
            smile = 0.4
        }
        if smokeTime > 0 { brow = max(brow, 0.7) }
        if flashTime > 0 { glow = 1.5 }
        // Signatures: ears go flat when startled; stalks flicker in turn while working something out.
        let startled = pokeTime > 0 || mode == .falling || mode == .held || mode == .crouching || mode == .dizzy
            || (mode == .idle && fidget == 14)
        p.earsBack = startled ? 1 : 0
        p.glowAlt = (activity == .thinking || activity == .tool || activity == .asking) ? 1 : 0
        if p.glowAlt > 0 { glow = max(glow, 0.8) }
        p.smile = swoon > 0 ? max(smile, 0.9) : smile
        p.mouthOpen = mouth
        p.browAngle = brow
        p.browLift = lift
        p.browCock = cock
        p.blush = swoon > 0 ? 1 : blush
        p.glow = glow

        // Wings beat in the air and settle on the ground.
        switch mode {
        case .jumping, .falling, .held, .cartwheel:
            p.flap = 1
        case .dancing, .skidding, .crouching:
            p.flap = 0.6
        default:
            p.flap = petting ? 0.3 : 0.04
        }

        // Pupils follow the cursor; when it is far away they wander on their own.
        if cursorOnScreen && hypot(dx, dy) < 1200 && mode != .napping {
            p.lookX = clamp(dx / 260, -1, 1) * cos(p.yaw)
            p.lookY = clamp(dy / 260, -1, 1)
        } else {
            p.lookX = dartX
            p.lookY = dartY
        }

        if blink > 0 { p.eyeOpen = 0.06 }
        return p
    }
}
