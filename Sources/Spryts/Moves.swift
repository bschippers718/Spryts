import CoreGraphics
import Foundation

// The moves a Spryt can be given in the maker: ways of walking, ways of getting around, and the things
// it does in a spare moment. Everything here is a pure function of time, so the maker's preview and the
// stage draw exactly the same motion. A move is only ever a pose: it cannot reach anything but the body.

struct MoveInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String      // SF Symbol for its tile in the maker
    let seconds: CGFloat    // how long one performance lasts
    let hint: String
}

struct WalkInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let hint: String
}

enum Moves {
    // MARK: The catalogue

    static let walks: [WalkInfo] = [
        WalkInfo(id: "natural", name: "Natural", hint: "An easy, everyday walk"),
        WalkInfo(id: "strut", name: "Strut", hint: "Chest out, shoulders rolling"),
        WalkInfo(id: "march", name: "March", hint: "Knees high, arms straight"),
        WalkInfo(id: "bounce", name: "Bounce", hint: "A spring in every step"),
        WalkInfo(id: "swing", name: "Swing", hint: "Arms swinging wide and carefree"),
        WalkInfo(id: "waddle", name: "Waddle", hint: "Rocking from side to side"),
        WalkInfo(id: "glide", name: "Glide", hint: "Smooth, as if on skates"),
        WalkInfo(id: "shuffle", name: "Shuffle", hint: "Small, sleepy steps"),
    ]

    static let travels: [WalkInfo] = [
        WalkInfo(id: "mix", name: "A Bit of Everything", hint: "Walks mostly, with the odd skip, dash or tiptoe"),
        WalkInfo(id: "walk", name: "Walking", hint: "Takes its time"),
        WalkInfo(id: "skip", name: "Skipping", hint: "Skips almost everywhere"),
        WalkInfo(id: "run", name: "Running", hint: "Always in a hurry"),
        WalkInfo(id: "sneak", name: "Tiptoeing", hint: "Creeps about quietly"),
    ]

    static let library: [MoveInfo] = [
        MoveInfo(id: "jump", name: "Jump", symbol: "arrow.up", seconds: 1.1, hint: "A happy hop on the spot"),
        MoveInfo(id: "hops", name: "Triple Hop", symbol: "arrow.up.forward", seconds: 3.0, hint: "Three hops, each one higher"),
        MoveInfo(id: "flip", name: "Flip", symbol: "arrow.trianglehead.2.clockwise.rotate.90", seconds: 1.5, hint: "A full somersault in the air"),
        MoveInfo(id: "twirl", name: "Twirl", symbol: "arrow.trianglehead.clockwise", seconds: 1.3, hint: "One neat turn"),
        MoveInfo(id: "spin", name: "Dizzy Spin", symbol: "tornado", seconds: 3.4, hint: "Spins until the room does too"),
        MoveInfo(id: "dance", name: "Dance", symbol: "music.note", seconds: 4.0, hint: "A little dance, with a turn"),
        MoveInfo(id: "swing", name: "Swing", symbol: "figure.play", seconds: 3.2, hint: "Swings from an invisible bar"),
        MoveInfo(id: "jacks", name: "Jumping Jacks", symbol: "figure.mixed.cardio", seconds: 3.0, hint: "Arms up, arms down"),
        MoveInfo(id: "kicks", name: "High Kicks", symbol: "figure.kickboxing", seconds: 2.8, hint: "A chorus line of one"),
        MoveInfo(id: "stomp", name: "Stomp", symbol: "shoeprints.fill", seconds: 2.4, hint: "Marching on the spot, hands on hips"),
        MoveInfo(id: "shimmy", name: "Shimmy", symbol: "waveform", seconds: 2.2, hint: "A quick shake of the shoulders"),
        MoveInfo(id: "wiggle", name: "Wiggle", symbol: "water.waves", seconds: 2.2, hint: "A pleased little wiggle"),
        MoveInfo(id: "flex", name: "Flex", symbol: "figure.strengthtraining.traditional", seconds: 2.2, hint: "Shows off both arms"),
        MoveInfo(id: "stretch", name: "Stretch", symbol: "figure.cooldown", seconds: 3.0, hint: "A long stretch and a yawn"),
        MoveInfo(id: "bow", name: "Bow", symbol: "figure.mind.and.body", seconds: 1.9, hint: "A small, unhurried bow"),
        MoveInfo(id: "wave", name: "Wave", symbol: "hand.wave", seconds: 2.2, hint: "A big friendly wave"),
        MoveInfo(id: "lap", name: "Victory Lap", symbol: "flag.checkered", seconds: 3.0, hint: "A sprint there and back, arms in the air"),
        MoveInfo(id: "moonwalk", name: "Moonwalk", symbol: "moon.stars", seconds: 3.0, hint: "Glides backwards"),
    ]

    /// What every Spryt did before moves could be chosen. A Spryt with no list of its own gets these.
    static let standard = ["dance", "flip", "lap", "moonwalk", "hops", "spin"]

    static func info(_ id: String) -> MoveInfo? { library.first { $0.id == id } }

    static func seconds(_ id: String) -> CGFloat { info(id)?.seconds ?? 2 }

    /// Keeps only moves this version knows, once each, in the catalogue's order.
    static func known(_ ids: [String]) -> [String] {
        library.map { $0.id }.filter { ids.contains($0) }
    }

    static func walkID(_ value: String?) -> String {
        walks.contains { $0.id == value } ? (value ?? "natural") : "natural"
    }

    static func travelID(_ value: String?) -> String {
        travels.contains { $0.id == value } ? (value ?? "mix") : "mix"
    }

    // MARK: What the stage asks

    /// The stage's own set pieces by number, as `SprytCharacter.decide` knows them. Moves that are only a pose
    /// return nil and play as a gesture.
    static func setPiece(_ id: String) -> Int? {
        switch id {
        case "spin": return 0
        case "dance": return 1
        case "flip": return 2
        case "lap": return 3
        case "moonwalk": return 4
        case "hops": return 5
        case "jump": return 12
        case "twirl": return 13
        default: return nil
        }
    }

    /// The next move for a Spryt with its own list: any of them but the one it did last.
    static func next(from ids: [String], last: String) -> String? {
        let mine = known(ids)
        if mine.isEmpty { return nil }
        let fresh = mine.filter { $0 != last }
        return (fresh.isEmpty ? mine : fresh).randomElement()
    }

    /// How much sooner or later the next move comes. 1 leaves the standard wait alone.
    /// Even at its most eager a Spryt waits minutes, so the screen stays calm.
    static func eagerness(_ m: MotionStyle) -> CGFloat {
        guard let value = m.showOff, value.isFinite else { return 1 }
        return 0.6 + 2.4 * min(1, max(0, value))        // 0.6× to 3× as often
    }

    static func spring(_ m: MotionStyle) -> CGFloat {
        guard let value = m.spring, value.isFinite else { return 1 }
        return min(1.8, max(0.6, value))
    }

    /// Which gait a made Spryt takes for an ordinary trip, or nil to let the stage choose as it always has.
    /// 0 walk, 1 run, 2 skip, 3 sneak.
    static func favouriteGait(_ m: MotionStyle) -> Int? {
        let roll = CGFloat.random(in: 0...1)
        switch travelID(m.travel) {
        case "walk": return roll < 0.85 ? 0 : nil
        case "run": return roll < 0.7 ? 1 : nil
        case "skip": return roll < 0.75 ? 2 : nil
        case "sneak": return roll < 0.7 ? 3 : nil
        default: return nil
        }
    }

    // MARK: Walking

    /// Reshapes an ordinary walk into this Spryt's own. `s` and `c` are the sine and cosine of the step.
    static func shape(_ p: inout Pose, walk: String?, s: CGFloat, c: CGFloat, t: CGFloat, m: MotionStyle, L: CGFloat) {
        switch walkID(walk) {
        case "strut":
            p.lean = -0.08
            p.armL *= 1.3
            p.armR *= 1.3
            p.armOutL = 0.36
            p.armOutR = 0.36
            p.tilt = (m.sway + 0.07) * s
            p.twist = 0.26 * s
            p.headPitch = -0.16
        case "march":
            let reach = max(0.5, m.stride)
            p.legL = reach * 1.15 * s
            p.legR = -reach * 1.15 * s
            p.kneeL = 1.7 * max(0, c)
            p.kneeR = 1.7 * max(0, -c)
            p.armL = -0.95 * s
            p.armR = 0.95 * s
            p.elbowL = 0.08
            p.elbowR = 0.08
            p.bodyY *= 0.4
            p.lean = 0
            p.tilt = 0
            p.headPitch = -0.06
        case "bounce":
            p.bodyY = (m.bounce + 3) * 1.9 * abs(c) - m.bounce * 0.4
            p.kneeL += 0.25 * max(0, c)
            p.kneeR += 0.25 * max(0, -c)
            p.armOutL = 0.3
            p.armOutR = 0.3
            p.headTilt = 0.07 * s
        case "swing":
            p.armL = -1.25 * s
            p.armR = 1.25 * s
            p.elbowL = 0.06
            p.elbowR = 0.06
            p.armOutL = 0.26
            p.armOutR = 0.26
            p.bodyY *= 1.3
            p.headTilt = 0.1 * s
            p.twist = 0.22 * s
        case "waddle":
            p.legL *= 0.6
            p.legR *= 0.6
            p.tilt = 0.17 * s
            p.twist = 0.2 * s
            p.armL *= 0.35
            p.armR *= 0.35
            p.armOutL = 0.5
            p.armOutR = 0.5
            p.bodyY = m.bounce * 0.5 * abs(s) - 1
            p.headTilt = -0.08 * s
        case "glide":
            p.legL *= 0.25
            p.legR *= 0.25
            p.kneeL *= 0.3
            p.kneeR *= 0.3
            p.armL = -0.5 + 0.08 * s
            p.armR = -0.5 - 0.08 * s
            p.elbowL = 0.15
            p.elbowR = 0.15
            p.armOutL = 0.32
            p.armOutR = 0.32
            p.bodyY = 1.2 * sin(t * 2.2)
            p.lean = 0.14
            p.tilt = 0.04 * sin(t * 1.6)
        case "shuffle":
            p.legL *= 0.45
            p.legR *= 0.45
            p.kneeL = 0.2
            p.kneeR = 0.2
            p.armL *= 0.3
            p.armR *= 0.3
            p.bodyY = -L * 0.04
            p.lean = 0.1
            p.headPitch = 0.12
        default:
            break
        }
    }

    /// A whole travelling pose, on the spot, for the maker's preview. The formulas match the stage's.
    static func travelPose(_ gait: String, phase: CGFloat, t: CGFloat, m: MotionStyle, L: CGFloat) -> Pose {
        var p = Pose()
        let s = sin(phase)
        let c = cos(phase)
        p.yaw = 0.8
        p.smile = 0.5
        switch gait {
        case "run":
            let a = min(0.95, m.stride * 1.6)
            let arm = min(1.3, m.armSwing * 1.5 + 0.3)
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
            p.smile = 0.6
            p.mouthOpen = 0.3
        case "skip":
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
            p.smile = 0.9
        case "sneak":
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
            p.smile = 0
        default:
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
            shape(&p, walk: m.walk, s: s, c: c, t: t, m: m, L: L)
        }
        return p
    }

    /// How fast the step cycle turns for each way of getting around, relative to a walk.
    static func cadence(_ gait: String) -> CGFloat {
        switch gait {
        case "run": return 1.7
        case "skip": return 1.15
        case "sneak": return 0.6
        default: return 1
        }
    }

    // MARK: Moves that are a pose

    private static func ease(_ x: CGFloat) -> CGFloat {
        let v = min(1, max(0, x))
        return v * v * (3 - 2 * v)
    }

    /// Layers a pose move over a standing pose. `u` is seconds since it began. Unknown names change nothing.
    static func pose(_ move: String, at u: CGFloat, into p: inout Pose, m: MotionStyle, H: CGFloat, L: CGFloat) {
        let d = seconds(move)
        // Every move eases in and out, so nothing snaps.
        let e = ease(u / 0.3) * ease((d - u) / 0.3)
        switch move {
        case "swing":
            // Hanging from a bar nobody else can see, legs swinging like a pendulum.
            let w = sin(u * 4.4)
            p.yaw = 0.9
            p.armOutL = 0.12 + 2.75 * e
            p.armOutR = 0.12 + 2.75 * e
            p.armL = 0
            p.armR = 0
            p.elbowL = 0.1
            p.elbowR = 0.1
            p.legL = 0.75 * w * e
            p.legR = 0.75 * w * e
            p.kneeL = 0.7 * max(0, -w) * e
            p.kneeR = 0.7 * max(0, -w) * e
            p.lean = -0.2 * w * e
            p.bodyY += H * 0.09 * e
            p.headPitch = -0.18 * e
            p.smile = 1
        case "jacks":
            let open = (0.5 - 0.5 * cos(u * 10)) * e
            p.yaw = 0
            p.armOutL = 0.15 + 2.5 * open
            p.armOutR = 0.15 + 2.5 * open
            p.elbowL = 0.1
            p.elbowR = 0.1
            p.legL = 0.28 * open
            p.legR = -0.28 * open
            p.bodyY += (m.bounce + 3) * 1.5 * abs(sin(u * 5)) * e
            p.smile = 0.9
            p.mouthOpen = 0.2 * open
        case "kicks":
            let w = sin(u * 6)
            p.yaw = 0.55
            p.legL = 1.35 * max(0, w) * e
            p.legR = 1.35 * max(0, -w) * e
            p.kneeL = 0.15
            p.kneeR = 0.15
            p.armOutL = 0.12 + 1.3 * e
            p.armOutR = 0.12 + 1.3 * e
            p.lean = -0.12 * e
            p.bodyY += 3 * abs(w) * e
            p.smile = 1
        case "stomp":
            let w = sin(u * 7)
            p.yaw = 0.3
            p.legL = 0.9 * max(0, w) * e
            p.legR = 0.9 * max(0, -w) * e
            p.kneeL = 1.4 * max(0, w) * e
            p.kneeR = 1.4 * max(0, -w) * e
            p.armOutL = 0.12 + 0.6 * e
            p.armOutR = 0.12 + 0.6 * e
            p.elbowL = 0.2 + 1.6 * e
            p.elbowR = 0.2 + 1.6 * e
            p.bodyY -= 1.5 * abs(cos(u * 7)) * e
            p.browAngle = 0.3 * e
        case "shimmy":
            p.yaw = 0
            p.twist = 0.36 * sin(u * 16) * e
            p.armOutL = 0.12 + 0.8 * e
            p.armOutR = 0.12 + 0.8 * e
            p.elbowL = 1.3
            p.elbowR = 1.3
            p.headTilt = -0.1 * sin(u * 16) * e
            p.bodyY += 2 * abs(sin(u * 8)) * e
            p.smile = 1
        case "wiggle":
            let w = sin(u * 10)
            p.yaw = 0.2
            p.tilt = 0.14 * w * e
            p.headTilt = -0.2 * w * e
            p.twist = 0.15 * cos(u * 10) * e
            p.armOutL = 0.12 + 0.4 * e
            p.armOutR = 0.12 + 0.4 * e
            p.elbowL = 1.5
            p.elbowR = 1.5
            p.kneeL = 0.2 * max(0, w) * e
            p.kneeR = 0.2 * max(0, -w) * e
            p.smile = 1
            p.blush = 0.5 * e
        case "flex":
            let pulse = 0.5 + 0.5 * sin(u * 9)
            p.yaw = 0
            p.armOutL = 0.12 + 1.4 * e
            p.armOutR = 0.12 + 1.4 * e
            p.elbowL = 0.2 + (1.9 + 0.3 * pulse) * e
            p.elbowR = 0.2 + (1.9 + 0.3 * pulse) * e
            p.lean = -0.08 * e
            p.squash = 1 + 0.03 * pulse * e
            p.browAngle = 0.25 * e
            p.smile = 0.8
        case "stretch":
            p.yaw = 0.2
            p.armOutL = 0.12 + 2.6 * e
            p.armOutR = 0.12 + 2.6 * e
            p.elbowL = 0.15
            p.elbowR = 0.15
            p.lean = -0.13 * e
            p.tilt = 0.12 * sin(u * 2.1) * e
            p.headPitch = -0.22 * e
            p.bodyY += 3 * e
            p.eyeOpen = 1 - 0.9 * e
            p.mouthOpen = 0.55 * e
        case "bow":
            let b = sin(CGFloat.pi * min(1, max(0, u / d)))
            p.lean += 0.24 * b
            p.headPitch += 0.18 * b
            p.armL = 0.55 * b
            p.elbowL = 0.2 + 1.1 * b
            p.armR = -0.35 * b
            p.bodyY -= 2 * b
        case "wave":
            p.armOutR = 0.12 + (2.4 + 0.35 * sin(u * 14)) * e
            p.armR = 0.1
            p.elbowR = 0.5 + 0.3 * sin(u * 14 + 1)
            p.smile = 1
            p.mouthOpen = 0.3 * e
        case "nod":
            p.headPitch += 0.25 * sin(u * 12) * e
        case "think":
            p.armR = 0.95 * e
            p.elbowR = 0.2 + 2.0 * e
            p.headTilt = 0.16 * e
            p.headPitch = (0.08 + 0.05 * sin(u * 3)) * e
            p.browCock = e
            p.smile = 0.1
        case "shrug":
            p.armOutL = 0.12 + 0.5 * e
            p.armOutR = 0.12 + 0.5 * e
            p.armL = 0.3 * e
            p.armR = 0.3 * e
            p.elbowL = 0.2 + 1.5 * e
            p.elbowR = 0.2 + 1.5 * e
            p.headTilt = 0.2 * e
            p.bodyY += 2 * e
        case "pump":
            p.yaw = 0
            p.armR = 2.3 * e
            p.armOutR = 0.3
            p.elbowR = 0.9 + 0.7 * sin(u * 13)
            p.bodyY += 4 * abs(sin(u * 13)) * e
            p.lean = -0.1 * e
            p.smile = 1
        default:
            break
        }
    }

    // MARK: The maker's preview of the stage's own set pieces

    /// A frame of a move as the preview draws it: the pose, plus how far the whole body has lifted,
    /// rolled and turned. On the stage these three come from the real jump and spin; here they are re-enacted.
    struct Frame {
        var pose = Pose()
        var lift: CGFloat = 0
        var roll: CGFloat = 0
        var spin: CGFloat = 0
    }

    /// One hop: crouch, a ballistic arc, a soft landing. `x` runs 0...1 over the whole hop.
    private static func hop(_ f: inout Frame, x: CGFloat, height: CGFloat, flip: Bool) {
        let crouch: CGFloat = 0.18
        let land: CGFloat = 0.14
        if x < crouch {
            let k = ease(x / crouch)
            f.pose.kneeL = 1.1 * k
            f.pose.kneeR = 1.1 * k
            f.pose.legL = 0.5 * k
            f.pose.legR = 0.5 * k
            f.pose.lean = 0.2 * k
            f.pose.armL = -0.6 * k
            f.pose.armR = -0.6 * k
            f.pose.squash = 1 - 0.1 * k
        } else if x < 1 - land {
            let a = (x - crouch) / (1 - land - crouch)
            f.lift = 4 * height * a * (1 - a)
            f.pose.squash = 1.05
            f.pose.smile = 0.9
            f.pose.mouthOpen = 0.4
            if flip {
                let tuck = ease(a / 0.22) * ease((1 - a) / 0.28)
                f.roll = -2 * CGFloat.pi * ease(a)
                f.pose.kneeL = 1.7 * tuck
                f.pose.kneeR = 1.7 * tuck
                f.pose.legL = 1.1 * tuck
                f.pose.legR = 1.1 * tuck
                f.pose.armL = 0.9 * tuck
                f.pose.armR = 0.9 * tuck
                f.pose.elbowL = 1.6 * tuck
                f.pose.elbowR = 1.6 * tuck
            } else {
                f.pose.armOutL = 2.2
                f.pose.armOutR = 2.2
                f.pose.kneeL = 0.4
                f.pose.kneeR = 0.4
            }
        } else {
            let k = 1 - ease((x - (1 - land)) / land)
            f.pose.kneeL = 0.9 * k
            f.pose.kneeR = 0.9 * k
            f.pose.legL = 0.4 * k
            f.pose.legR = 0.4 * k
            f.pose.squash = 1 - 0.12 * k
        }
    }

    /// The frame `u` seconds into a move, for a Spryt `H` tall with legs `L` long.
    static func frame(_ move: String, at u: CGFloat, m: MotionStyle, H: CGFloat, L: CGFloat) -> Frame {
        var f = Frame()
        f.pose.yaw = 0.5
        f.pose.smile = 0.6
        let d = seconds(move)
        let jumpHeight = spring(m)
        switch move {
        case "jump":
            hop(&f, x: u / d, height: H * 0.5 * jumpHeight, flip: false)
        case "flip":
            f.pose.yaw = 1.1
            hop(&f, x: u / d, height: max(H * 0.95, H * 0.5 * jumpHeight), flip: true)
        case "hops":
            let each = d / 3
            let index = min(2, Int(u / each))
            let heights: [CGFloat] = [0.3, 0.45, 0.95]
            f.pose.yaw = index == 2 ? 1.1 : 0.5
            hop(&f, x: (u - CGFloat(index) * each) / each, height: H * heights[index] * (index == 2 ? 1 : jumpHeight), flip: index == 2)
        case "twirl":
            f.spin = 2 * CGFloat.pi * ease(u / (d - 0.2))
            let e = ease(u / 0.25) * ease((d - u) / 0.25)
            f.pose.armOutL = 0.12 + 1.4 * e
            f.pose.armOutR = 0.12 + 1.4 * e
            f.pose.bodyY = 2 * e
            f.pose.smile = 1
        case "spin":
            let turning: CGFloat = 2.2
            if u < turning {
                f.spin = 6 * CGFloat.pi * ease(u / turning)
                f.pose.armOutL = 1.2
                f.pose.armOutR = 1.2
            } else {
                // Dizzy: the head keeps going after the feet have stopped.
                let wobble = sin((u - turning) * 9) * max(0, 1 - (u - turning) / (d - turning))
                f.pose.headTilt = 0.3 * wobble
                f.pose.tilt = 0.12 * wobble
                f.pose.headYaw = 0.3 * wobble
                f.pose.eyeOpen = 0.5
                f.pose.smile = 0.1
                f.pose.mouthOpen = 0.3
            }
        case "dance":
            let beat = u * 8
            f.pose.yaw = 0.5 * sin(u * 2)
            f.pose.bodyY = (m.bounce + 3) * 1.4 * abs(sin(beat))
            f.pose.tilt = 0.18 * sin(beat / 2)
            f.pose.armOutL = 1.6 + 0.9 * sin(beat)
            f.pose.armOutR = 1.6 - 0.9 * sin(beat)
            f.pose.elbowL = 1.0
            f.pose.elbowR = 1.0
            f.pose.legL = 0.3 * max(0, sin(beat / 2))
            f.pose.legR = 0.3 * max(0, -sin(beat / 2))
            f.pose.kneeL = 0.6 * max(0, sin(beat / 2))
            f.pose.kneeR = 0.6 * max(0, -sin(beat / 2))
            f.pose.headTilt = 0.15 * sin(beat / 2)
            f.pose.smile = 1
            if u > d * 0.45 && u < d * 0.45 + 0.8 { f.spin = 2 * CGFloat.pi * ease((u - d * 0.45) / 0.8) }
        case "lap":
            let phase = u * m.speed / 11 * cadence("run")
            f.pose = travelPose("run", phase: phase, t: u, m: m, L: L)
            // Out and back: it turns round halfway.
            f.pose.yaw = u < d / 2 ? 1.0 : -1.0
            f.pose.armOutL = 2.5 + 0.2 * sin(phase)
            f.pose.armOutR = 2.5 - 0.2 * sin(phase)
            f.pose.armL = 0
            f.pose.armR = 0
            f.pose.elbowL = 0.3
            f.pose.elbowR = 0.3
            f.pose.headPitch = -0.25
            f.pose.smile = 1
        case "moonwalk":
            let phase = u * m.speed / 11 * 0.8
            let s = sin(phase)
            let c = cos(phase)
            f.pose.yaw = 1.1
            f.pose.legL = 0.35 * s
            f.pose.legR = -0.35 * s
            f.pose.kneeL = 0.5 * max(0, -c)
            f.pose.kneeR = 0.5 * max(0, c)
            f.pose.lean = -0.12
            f.pose.bodyY = 1.5 * sin(phase * 2)
            f.pose.armL = 0.4 * s
            f.pose.armR = -0.4 * s
            f.pose.headPitch = 0.1 * sin(phase * 2)
        default:
            // Breathing underneath, the move on top.
            f.pose.bodyY = 1.2 * sin(u * 2.2)
            pose(move, at: u, into: &f.pose, m: m, H: H, L: L)
        }
        return f
    }
}
