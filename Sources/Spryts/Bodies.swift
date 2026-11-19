import AppKit
import SceneKit

func v3(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> SCNVector3 {
    SCNVector3(x: x, y: y, z: z)
}

/// Every joint value for one frame. Angles are radians; "forward" means toward the character's front.
struct Pose {
    var yaw: CGFloat = 0          // 0 faces the viewer, positive turns toward screen right
    var bodyY: CGFloat = 0
    var squash: CGFloat = 1
    var lean: CGFloat = 0
    var tilt: CGFloat = 0
    var twist: CGFloat = 0
    var legL: CGFloat = 0
    var legR: CGFloat = 0
    var kneeL: CGFloat = 0
    var kneeR: CGFloat = 0
    var armL: CGFloat = 0
    var armR: CGFloat = 0
    var armOutL: CGFloat = 0.12
    var armOutR: CGFloat = 0.12
    var elbowL: CGFloat = 0.2
    var elbowR: CGFloat = 0.2
    var headYaw: CGFloat = 0
    var headPitch: CGFloat = 0    // positive looks down
    var headTilt: CGFloat = 0
    var eyeOpen: CGFloat = 1
    var lookX: CGFloat = 0        // where the pupils point, -1...1
    var lookY: CGFloat = 0
    var browAngle: CGFloat = 0    // positive frowns, negative looks worried
    var browLift: CGFloat = 0
    var browCock: CGFloat = 0     // raises one brow
    var mouthOpen: CGFloat = 0
    var smile: CGFloat = 0.25     // -1 frown ... 1 grin
    var blush: CGFloat = 0
    var glow: CGFloat = 0.25      // antenna bulb
    var flap: CGFloat = 0         // wings, for characters that have them
    var earsBack: CGFloat = 0     // ears pinned flat (startled)
    var glowAlt: CGFloat = 0      // paired bulbs flicker in turn
    var prop: Int = 0             // 0 nothing, 1 laptop, 2 a page; not eased
    var twitch: CGFloat = 0       // a quick flick of ears and antenna; not eased
    var roll: CGFloat = 0         // whole-body rotation in the screen plane (flips, cartwheels); not eased
    var spin: CGFloat = 0         // extra turn on the spot (twirls); not eased

    static let keys: [WritableKeyPath<Pose, CGFloat>] = [
        \Pose.yaw, \Pose.bodyY, \Pose.squash, \Pose.lean, \Pose.tilt, \Pose.twist,
        \Pose.legL, \Pose.legR, \Pose.kneeL, \Pose.kneeR,
        \Pose.armL, \Pose.armR, \Pose.armOutL, \Pose.armOutR, \Pose.elbowL, \Pose.elbowR,
        \Pose.headYaw, \Pose.headPitch, \Pose.headTilt, \Pose.eyeOpen,
        \Pose.lookX, \Pose.lookY, \Pose.browAngle, \Pose.browLift, \Pose.browCock,
        \Pose.mouthOpen, \Pose.smile, \Pose.blush, \Pose.glow, \Pose.flap,
        \Pose.earsBack, \Pose.glowAlt
    ]

    /// Ease every joint toward the target. This is what blends one behaviour into the next.
    mutating func approach(_ target: Pose, _ k: CGFloat) {
        let blend = max(0, min(1, k))
        for key in Pose.keys {
            let current = self[keyPath: key]
            // Eyes lead the head. Blinks close crisply, then reopen with a softer release.
            let rate: CGFloat
            if key == \Pose.eyeOpen {
                rate = target[keyPath: key] < current ? 2.8 : 1.5
            } else if key == \Pose.lookX || key == \Pose.lookY {
                rate = 1.7
            } else {
                rate = 1
            }
            let amount = 1 - pow(1 - blend, rate)
            self[keyPath: key] = current + (target[keyPath: key] - current) * amount
        }
    }
}

protocol CharacterBody: AnyObject {
    var root: SCNNode { get }
    var height: CGFloat { get }
    var legLength: CGFloat { get }
    func apply(pose: Pose, clip: String, dt: CGFloat, showProp: Bool, speed: CGFloat, time: CGFloat)
    /// How heavy the weather is, 0...1. Only the cloud uses it.
    func setStorm(_ level: CGFloat)
}

private func material(_ color: NSColor, glow: Bool = false) -> SCNMaterial {
    let m = SCNMaterial()
    m.diffuse.contents = color
    m.specular.contents = NSColor(white: 1, alpha: 0.35)
    m.shininess = 0.4
    m.lightingModel = .blinn
    if glow { m.emission.contents = color }
    return m
}

private func shape(_ geometry: SCNGeometry, _ color: NSColor, glow: Bool = false) -> SCNNode {
    geometry.firstMaterial = material(color, glow: glow)
    return SCNNode(geometry: geometry)
}

/// An underdamped attachment that settles exactly for the elapsed time, including a slow frame.
/// Separate instances give ears, stalks and cloth their own weight without scheduling more movement.
private struct AttachmentSpring {
    private(set) var value: CGFloat = 0
    private(set) var velocity: CGFloat = 0

    mutating func advance(to target: CGFloat, dt: CGFloat, frequency: CGFloat, damping: CGFloat) {
        guard dt.isFinite, dt > 0 else { return }
        let decay = damping * frequency
        let oscillation = frequency * sqrt(1 - damping * damping)
        let offset = value - target
        let envelope = exp(-decay * dt)
        let cosine = cos(oscillation * dt)
        let sine = sin(oscillation * dt)
        let wave = (velocity + decay * offset) / oscillation
        value = target + envelope * (offset * cosine + wave * sine)
        velocity = envelope * (velocity * cosine - (decay * velocity + frequency * frequency * offset) / oscillation * sine)
    }
}

// MARK: - Built-in body made of simple shapes, animated entirely in code

final class ProceduralBody: CharacterBody {
    let root = SCNNode()
    let height: CGFloat
    let legLength: CGFloat

    private let rollNode = SCNNode()
    private let squashNode = SCNNode()
    private let yawNode = SCNNode()
    private let hips = SCNNode()
    private let torso = SCNNode()
    private let head = SCNNode()
    private var eyes: [SCNNode] = []
    private var pupils: [SCNNode] = []
    private var brows: [SCNNode] = []
    private var browX: [CGFloat] = []
    private var browSign: [CGFloat] = []
    private var browY: CGFloat = 0
    private var pupilZ: CGFloat = 0
    private var pupilTravel: CGFloat = 1
    private var cheeks: [SCNNode] = []
    private let mouthDark = SCNNode()
    private let mouthMask = SCNNode()
    private var mouthVisible = true
    private var beakLower: SCNNode?
    private var bulbNodes: [SCNNode] = []
    private var scarfSegments: [SCNNode] = []
    private var headRadius: CGFloat = 10
    private var legUpper: [SCNNode] = []
    private var legLower: [SCNNode] = []
    private var armUpper: [SCNNode] = []
    private var armLower: [SCNNode] = []
    private var antennas: [SCNNode] = []
    private var cape: SCNNode?
    private var tail: SCNNode?
    private var tailWag: CGFloat = 0.5
    private var ears: [SCNNode] = []
    private var earTilt: CGFloat = 0.35
    private var earFlop: CGFloat = 0.8
    private var wings: [SCNNode] = []
    private let prop = SCNNode()
    private let page = SCNNode()
    private let hipBase: CGFloat

    private var antennaPitch = AttachmentSpring()
    private var antennaSway = AttachmentSpring()
    private var earPitch = AttachmentSpring()
    private var earSway = AttachmentSpring()
    private var clothPitch = AttachmentSpring()
    private var clothSway = AttachmentSpring()
    private var scarfTip = AttachmentSpring()
    private var tailMotion = AttachmentSpring()
    private var lastAttachmentPose: Pose?
    private var tailPhase = CGFloat.random(in: 0...(2 * .pi))

    init(look: Look) {
        let H = look.height
        height = H
        let legScale = look.legs ?? 1
        let armScale = look.arms ?? 1
        let girth = look.torso ?? 1
        let thick = look.limbs ?? 1
        let footScale = look.feet ?? 1
        legLength = H * 0.27 * legScale
        let bodyColor = NSColor(hex: look.body)
        let accent = NSColor(hex: look.accent)
        let skin = NSColor(hex: look.skin)
        let trim = NSColor(hex: look.trim ?? look.accent)
        let dark = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.14, alpha: 1)
        let features = look.features

        let headR = H * 0.2 * look.headScale
        headRadius = headR
        let torsoH = H * 0.3
        let torsoW = H * 0.3 * girth
        let armLen = H * 0.3 * armScale
        let limbR = H * 0.045 * thick
        let footH = H * 0.05
        hipBase = legLength + footH * 0.5

        rollNode.position = v3(0, H * 0.45, 0)
        root.addChildNode(rollNode)
        squashNode.position = v3(0, -H * 0.45, 0)
        rollNode.addChildNode(squashNode)
        squashNode.addChildNode(yawNode)
        hips.position = v3(0, hipBase, 0)
        yawNode.addChildNode(hips)

        // Legs
        for side in [CGFloat(-1), CGFloat(1)] {
            let foot = shape(SCNBox(width: H * 0.1 * footScale, height: footH, length: H * 0.15 * footScale, chamferRadius: footH * 0.45), accent)
            foot.position = v3(0, 0, H * 0.035 * footScale)
            let (upper, lower) = ProceduralBody.limb(length: legLength, radius: limbR * 1.15, color: bodyColor, end: foot)
            upper.position = v3(side * torsoW * 0.27, 0, 0)
            hips.addChildNode(upper)
            legUpper.append(upper)
            legLower.append(lower)
        }

        // Torso
        hips.addChildNode(torso)
        let trunk: SCNNode
        switch look.build ?? "bean" {
        case "round":
            trunk = shape(SCNSphere(radius: torsoW * 0.62), bodyColor)
            trunk.scale = v3(1, (torsoH + torsoW * 0.55) / (torsoW * 1.24), 0.9)
        case "block":
            trunk = shape(SCNBox(width: torsoW * 1.02, height: torsoH + torsoW * 0.5, length: torsoW * 0.86,
                                 chamferRadius: torsoW * 0.2), bodyColor)
            trunk.scale = v3(1, 1, 1)
        default:
            trunk = shape(SCNCapsule(capRadius: torsoW * 0.5, height: torsoH + torsoW * 0.55), bodyColor)
            trunk.scale = v3(1, 1, 0.82)
        }
        trunk.position = v3(0, torsoH * 0.5, 0)
        torso.addChildNode(trunk)
        if look.belly != false {
            let belly = shape(SCNSphere(radius: torsoW * 0.3), accent)
            belly.position = v3(0, torsoH * 0.45, torsoW * 0.27)
            belly.scale = v3(1, 1.1, 0.45)
            torso.addChildNode(belly)
        }

        // Arms
        for side in [CGFloat(-1), CGFloat(1)] {
            let hand = shape(SCNSphere(radius: limbR * 1.35), accent)
            let (upper, lower) = ProceduralBody.limb(length: armLen, radius: limbR, color: bodyColor, end: hand)
            upper.position = v3(side * (torsoW * 0.5 + limbR * 0.6), torsoH * 0.86, 0)
            torso.addChildNode(upper)
            armUpper.append(upper)
            armLower.append(lower)
        }

        // Head: round, wide, tall or boxy
        head.position = v3(0, torsoH * 0.98, 0)
        torso.addChildNode(head)
        let headShape = look.head ?? "round"
        let skull: SCNNode
        if headShape == "box" {
            skull = shape(SCNBox(width: headR * 1.95, height: headR * 1.75, length: headR * 1.75, chamferRadius: headR * 0.4), skin)
        } else {
            skull = shape(SCNSphere(radius: headR), skin)
            if headShape == "wide" {
                skull.scale = v3(1.28, 0.88, 1)
            } else if headShape == "tall" {
                skull.scale = v3(0.92, 1.18, 0.96)
            } else if headShape == "flat" {
                skull.scale = v3(1.22, 0.74, 1.04)
            } else {
                skull.scale = v3(1.06, 0.96, 1)
            }
        }
        skull.position = v3(0, headR * 0.9, 0)
        head.addChildNode(skull)

        // Eyes: a pair, or one big one
        let oneEye = (look.eyes ?? "two") == "one"
        let threeEyes = (look.eyes ?? "two") == "three"
        let eyeSides: [CGFloat] = oneEye ? [0] : (threeEyes ? [-1, 0, 1] : [-1, 1])
        let big = (oneEye ? 1.9 : (threeEyes ? 0.82 : 1)) * (look.eyeSize ?? 1)
        let spread: CGFloat = (headShape == "wide" || headShape == "flat" || threeEyes) ? 0.5 : 0.38
        pupilZ = headR * 0.09 * big
        pupilTravel = big
        browY = headR * (1.0 + 0.32 * big)
        for side in eyeSides {
            let eye = SCNNode()
            eye.position = v3(side * headR * spread, headR * 1.0, headR * 0.84)
            let white = shape(SCNSphere(radius: headR * 0.21 * big), NSColor.white)
            white.scale = v3(1, 1, 0.5)
            eye.addChildNode(white)
            // The pupil sits in its own node so it can slide around to look at things.
            let pupilNode = SCNNode()
            pupilNode.position = v3(0, 0, pupilZ)
            let pupil = shape(SCNSphere(radius: headR * 0.12 * big), dark)
            pupil.scale = v3(1, 1, 0.5)
            pupilNode.addChildNode(pupil)
            let glint = shape(SCNSphere(radius: headR * 0.04 * big), NSColor.white, glow: true)
            glint.position = v3(headR * 0.04 * big, headR * 0.05 * big, headR * 0.06 * big)
            pupilNode.addChildNode(glint)
            eye.addChildNode(pupilNode)
            pupils.append(pupilNode)
            head.addChildNode(eye)
            eyes.append(eye)

            let brow = SCNNode()
            brow.position = v3(side * headR * spread, browY, headR * 0.86)
            let bar = shape(SCNCapsule(capRadius: headR * 0.032, height: headR * 0.28 * min(big, 1.6)), dark)
            bar.eulerAngles = v3(0, 0, CGFloat.pi / 2)
            brow.addChildNode(bar)
            head.addChildNode(brow)
            brows.append(brow)
            browX.append(side * headR * spread)
            browSign.append(side)
        }
        for side in [CGFloat(-1), CGFloat(1)] {
            let cheek = shape(SCNSphere(radius: headR * 0.14), NSColor(srgbRed: 1.0, green: 0.45, blue: 0.5, alpha: 1))
            cheek.position = v3(side * headR * 0.62, headR * 0.66, headR * 0.74)
            cheek.scale = v3(1, 0.7, 0.3)
            cheek.opacity = 0
            head.addChildNode(cheek)
            cheeks.append(cheek)
        }

        // Snout: none, a small nose, a muzzle, or a beak
        let snout = look.snout ?? "none"
        var mouthY = headR * 0.58
        var mouthZ = headR * 0.92
        var maskColor = skin
        if snout == "muzzle" {
            let bump = shape(SCNSphere(radius: headR * 0.42), accent)
            bump.position = v3(0, headR * 0.6, headR * 0.7)
            bump.scale = v3(1.15, 0.8, 0.8)
            head.addChildNode(bump)
            let nose = shape(SCNSphere(radius: headR * 0.1), dark)
            nose.position = v3(0, headR * 0.8, headR * 1.02)
            head.addChildNode(nose)
            mouthY = headR * 0.5
            mouthZ = headR * 1.02
            maskColor = accent
        } else if snout == "nose" {
            let nose = shape(SCNSphere(radius: headR * 0.09), dark)
            nose.position = v3(0, headR * 0.78, headR * 0.96)
            head.addChildNode(nose)
        } else if snout == "beak" {
            mouthVisible = false
            let upper = shape(SCNCone(topRadius: 0, bottomRadius: headR * 0.22, height: headR * 0.5), trim)
            upper.eulerAngles = v3(CGFloat.pi / 2, 0, 0)
            upper.scale = v3(1.1, 1, 0.55)
            upper.position = v3(0, headR * 0.7, headR * 1.1)
            head.addChildNode(upper)
            let hinge = SCNNode()
            hinge.position = v3(0, headR * 0.62, headR * 0.86)
            let lower = shape(SCNCone(topRadius: 0, bottomRadius: headR * 0.17, height: headR * 0.4), trim)
            lower.eulerAngles = v3(CGFloat.pi / 2, 0, 0)
            lower.scale = v3(1.1, 1, 0.45)
            lower.position = v3(0, 0, headR * 0.2)
            hinge.addChildNode(lower)
            head.addChildNode(hinge)
            beakLower = hinge
        }

        // Mouth: a dark oval, with a face-coloured oval sliding over it to carve a smile or a frown.
        let mouth = SCNNode()
        mouth.position = v3(0, mouthY, mouthZ)
        let darkShape = SCNSphere(radius: headR * 0.16)
        darkShape.firstMaterial = material(dark)
        mouthDark.geometry = darkShape
        mouth.addChildNode(mouthDark)
        let maskShape = SCNSphere(radius: headR * 0.16)
        maskShape.firstMaterial = material(maskColor)
        mouthMask.geometry = maskShape
        mouth.addChildNode(mouthMask)
        mouth.isHidden = !mouthVisible
        head.addChildNode(mouth)

        // Antenna: one in the middle, or a pair of stalks
        var antennaSpots: [CGFloat] = []
        if features.contains("antenna") { antennaSpots = [0] }
        if features.contains("stalks") { antennaSpots = [-0.5, 0.5] }
        for spot in antennaSpots {
            let a = SCNNode()
            a.position = v3(spot * headR, headR * (spot == 0 ? 1.8 : 1.65), 0)
            let stalk = shape(SCNCylinder(radius: headR * 0.04, height: headR * 0.6), dark)
            stalk.position = v3(0, headR * 0.3, 0)
            a.addChildNode(stalk)
            let bulb = shape(SCNSphere(radius: headR * 0.15), spot == 0 ? bodyColor : trim, glow: true)
            bulb.position = v3(0, headR * 0.66, 0)
            a.addChildNode(bulb)
            bulbNodes.append(bulb)
            head.addChildNode(a)
            antennas.append(a)
        }

        // Ears: pointy, long, round, or horns
        var earKind = ""
        if features.contains("ears") { earKind = "pointy" }
        if features.contains("longears") { earKind = "long" }
        if features.contains("roundears") { earKind = "round" }
        if features.contains("horns") { earKind = "horns" }
        if !earKind.isEmpty {
            for side in [CGFloat(-1), CGFloat(1)] {
                let e = SCNNode()
                if earKind == "long" {
                    earTilt = 0.16
                    earFlop = 1.7
                    e.position = v3(side * headR * 0.45, headR * 1.6, 0)
                    let outer = shape(SCNCapsule(capRadius: headR * 0.17, height: headR * 1.5), skin)
                    outer.position = v3(0, headR * 0.7, 0)
                    outer.scale = v3(1, 1, 0.6)
                    e.addChildNode(outer)
                    let inner = shape(SCNCapsule(capRadius: headR * 0.09, height: headR * 1.15), trim)
                    inner.position = v3(0, headR * 0.7, headR * 0.07)
                    inner.scale = v3(1, 1, 0.4)
                    e.addChildNode(inner)
                } else if earKind == "round" {
                    earTilt = 0
                    earFlop = 0.3
                    e.position = v3(side * headR * 0.8, headR * 1.5, 0)
                    let outer = shape(SCNSphere(radius: headR * 0.34), skin)
                    outer.scale = v3(1, 1, 0.5)
                    e.addChildNode(outer)
                    let inner = shape(SCNSphere(radius: headR * 0.2), trim)
                    inner.position = v3(0, 0, headR * 0.1)
                    inner.scale = v3(1, 1, 0.4)
                    e.addChildNode(inner)
                } else if earKind == "horns" {
                    earTilt = 0.45
                    earFlop = 0
                    e.position = v3(side * headR * 0.5, headR * 1.62, headR * 0.1)
                    let horn = shape(SCNCone(topRadius: 0, bottomRadius: headR * 0.16, height: headR * 0.62), accent)
                    horn.position = v3(0, headR * 0.28, 0)
                    e.addChildNode(horn)
                } else {
                    earTilt = 0.35
                    earFlop = 0.8
                    e.position = v3(side * headR * 0.62, headR * 1.55, 0)
                    let cone = shape(SCNCone(topRadius: 0, bottomRadius: headR * 0.26, height: headR * 0.6), accent)
                    cone.position = v3(0, headR * 0.25, 0)
                    e.addChildNode(cone)
                }
                e.eulerAngles = v3(0, 0, -side * earTilt)
                head.addChildNode(e)
                ears.append(e)
            }
        }

        if features.contains("cape") {
            let c = SCNNode()
            c.position = v3(0, torsoH * 0.92, -torsoW * 0.36)
            let cloth = shape(SCNBox(width: torsoW * 1.3, height: torsoH * 1.35, length: 1.5, chamferRadius: 0.5), accent)
            cloth.position = v3(0, -torsoH * 0.675, 0)
            c.addChildNode(cloth)
            torso.addChildNode(c)
            cape = c
        }
        if features.contains("scarf") {
            let ring = shape(SCNTorus(ringRadius: torsoW * 0.36, pipeRadius: limbR * 0.95), trim)
            ring.position = v3(0, torsoH * 0.97, 0)
            ring.scale = v3(1, 1, 0.85)
            torso.addChildNode(ring)
            // Two trailing ends that stream out behind when running.
            let segLen = H * 0.15
            var parent: SCNNode = torso
            var at = v3(torsoW * 0.12, torsoH * 0.95, -torsoW * 0.36)
            var i = 0
            while i < 2 {
                let seg = SCNNode()
                seg.position = at
                let cloth = shape(SCNBox(width: limbR * 1.9, height: segLen, length: limbR * 0.5, chamferRadius: limbR * 0.2), trim)
                cloth.position = v3(0, -segLen / 2, 0)
                seg.addChildNode(cloth)
                parent.addChildNode(seg)
                scarfSegments.append(seg)
                parent = seg
                at = v3(0, -segLen, 0)
                i += 1
            }
        }

        // Headband: a sweatband round the forehead, tied at the back. It rides on the skull so it follows its shape.
        if features.contains("headband") {
            let bandY = headR * 0.6
            let bandR = headR * 0.84
            if headShape == "box" {
                let band = shape(SCNBox(width: headR * 2.02, height: headR * 0.26, length: headR * 1.82, chamferRadius: headR * 0.12), trim)
                band.position = v3(0, bandY, 0)
                skull.addChildNode(band)
            } else {
                let band = shape(SCNTorus(ringRadius: bandR, pipeRadius: headR * 0.11), trim)
                band.position = v3(0, bandY, 0)
                band.scale = v3(1, 1.5, 1)
                skull.addChildNode(band)
                let stripe = shape(SCNTorus(ringRadius: bandR * 1.04, pipeRadius: headR * 0.035), accent)
                stripe.position = v3(0, bandY, 0)
                skull.addChildNode(stripe)
            }
            for side in [CGFloat(-1), CGFloat(1)] {
                let tie = shape(SCNBox(width: headR * 0.14, height: headR * 0.42, length: headR * 0.06, chamferRadius: headR * 0.03), trim)
                tie.position = v3(side * headR * 0.12, bandY - headR * 0.18, -headR * 0.92)
                tie.eulerAngles = v3(-0.35, 0, side * 0.45)
                skull.addChildNode(tie)
            }
        }
        if features.contains("wristbands") {
            for lower in armLower {
                let cuff = shape(SCNTorus(ringRadius: limbR * 1.0, pipeRadius: limbR * 0.38), trim)
                cuff.position = v3(0, -armLen * 0.38, 0)
                cuff.scale = v3(1, 1.6, 1)
                lower.addChildNode(cuff)
            }
        }

        // Tails: a string of beads, a bushy fox tail, a long dragon tail, or a stub
        if features.contains("tail") {
            let tl = SCNNode()
            tl.position = v3(0, H * 0.03, -torsoW * 0.36)
            var i: CGFloat = 0
            while i < 4 {
                let ball = shape(SCNSphere(radius: limbR * (1.2 - i * 0.2)), accent)
                ball.position = v3(0, i * limbR * 1.1, -(i + 0.5) * limbR * 1.5)
                tl.addChildNode(ball)
                i += 1
            }
            hips.addChildNode(tl)
            tail = tl
        } else if features.contains("foxtail") {
            let tl = SCNNode()
            tl.position = v3(0, H * 0.05, -torsoW * 0.38)
            let sizes: [CGFloat] = [1.5, 2.1, 1.7, 1.0]
            var i = 0
            while i < sizes.count {
                let ball = shape(SCNSphere(radius: limbR * sizes[i]), i == sizes.count - 1 ? accent : bodyColor)
                ball.position = v3(0, CGFloat(i) * limbR * 1.6, -(CGFloat(i) + 0.6) * limbR * 1.9)
                tl.addChildNode(ball)
                i += 1
            }
            hips.addChildNode(tl)
            tail = tl
            tailWag = 0.6
        } else if features.contains("dragontail") {
            let tl = SCNNode()
            tl.position = v3(0, H * 0.04, -torsoW * 0.38)
            var i: CGFloat = 0
            while i < 6 {
                let ball = shape(SCNSphere(radius: limbR * (1.5 - i * 0.2)), bodyColor)
                ball.position = v3(0, -i * limbR * 0.3, -(i + 0.6) * limbR * 1.7)
                tl.addChildNode(ball)
                i += 1
            }
            let tip = shape(SCNCone(topRadius: 0, bottomRadius: limbR * 1.1, height: limbR * 2.4), trim)
            tip.eulerAngles = v3(-CGFloat.pi / 2, 0, 0)
            tip.position = v3(0, -6 * limbR * 0.3, -6.5 * limbR * 1.7)
            tl.addChildNode(tip)
            hips.addChildNode(tl)
            tail = tl
            tailWag = 0.3
        } else if features.contains("stub") {
            let tl = SCNNode()
            tl.position = v3(0, H * 0.03, -torsoW * 0.42)
            tl.addChildNode(shape(SCNSphere(radius: limbR * 1.7), accent))
            hips.addChildNode(tl)
            tail = tl
            tailWag = 0.2
        }

        // Wings that flap whenever the character is in the air
        if features.contains("wings") {
            for side in [CGFloat(-1), CGFloat(1)] {
                let w = SCNNode()
                w.position = v3(side * torsoW * 0.22, torsoH * 0.8, -torsoW * 0.4)
                let panel = shape(SCNBox(width: H * 0.3, height: H * 0.2, length: 1.6, chamferRadius: 0.8), trim)
                panel.position = v3(side * H * 0.15, H * 0.04, 0)
                w.addChildNode(panel)
                torso.addChildNode(w)
                wings.append(w)
            }
        }

        // A row of spikes down the back
        if features.contains("spikes") {
            let rows: [CGFloat] = [0.35, 0.62, 0.88]
            for row in rows {
                let spike = shape(SCNCone(topRadius: 0, bottomRadius: limbR * 1.1, height: limbR * 2.6), trim)
                spike.eulerAngles = v3(-CGFloat.pi / 2 + 0.5, 0, 0)
                spike.position = v3(0, torsoH * row, -torsoW * 0.45)
                torso.addChildNode(spike)
            }
            let crest = shape(SCNCone(topRadius: 0, bottomRadius: limbR * 1.1, height: limbR * 2.6), trim)
            crest.eulerAngles = v3(-0.6, 0, 0)
            crest.position = v3(0, headR * 1.85, -headR * 0.35)
            head.addChildNode(crest)
        }

        // A tiny laptop that appears while the bot is using a tool.
        let base = shape(SCNBox(width: H * 0.3, height: H * 0.02, length: H * 0.2, chamferRadius: 1), NSColor(white: 0.8, alpha: 1))
        prop.addChildNode(base)
        let screen = shape(SCNBox(width: H * 0.3, height: H * 0.2, length: H * 0.015, chamferRadius: 1), NSColor(white: 0.25, alpha: 1))
        screen.position = v3(0, H * 0.1, H * 0.1)
        screen.eulerAngles = v3(0.25, 0, 0)
        prop.addChildNode(screen)
        let glow = shape(SCNBox(width: H * 0.26, height: H * 0.16, length: 0.5, chamferRadius: 0.5), accent, glow: true)
        glow.position = v3(0, H * 0.1, H * 0.09)
        glow.eulerAngles = v3(0.25, 0, 0)
        prop.addChildNode(glow)
        prop.position = v3(0, legLength * 0.75, torsoW * 0.95)
        prop.isHidden = true
        yawNode.addChildNode(prop)

        // A sheet of paper, held up while reading a file.
        let sheetShape = SCNBox(width: H * 0.17, height: H * 0.22, length: 0.8, chamferRadius: 0.4)
        let paperMaterial = SCNMaterial()
        paperMaterial.diffuse.contents = NSColor(white: 0.97, alpha: 1)
        paperMaterial.lightingModel = .constant
        sheetShape.firstMaterial = paperMaterial
        page.geometry = sheetShape
        var line: CGFloat = 0
        while line < 4 {
            let rule = shape(SCNBox(width: H * 0.11, height: H * 0.012, length: 0.4, chamferRadius: 0), NSColor(white: 0.55, alpha: 1))
            rule.position = v3(0, H * 0.06 - line * H * 0.04, -0.7)
            page.addChildNode(rule)
            line += 1
        }
        page.position = v3(0, hipBase + torsoH * 0.62, torsoW * 0.5 + H * 0.2)
        page.eulerAngles = v3(-0.35, 0, 0)
        page.isHidden = true
        yawNode.addChildNode(page)
    }

    /// A two-segment limb hanging down from its pivot.
    private static func limb(length: CGFloat, radius: CGFloat, color: NSColor, end: SCNNode) -> (SCNNode, SCNNode) {
        let half = length / 2
        let upper = SCNNode()
        let upperShape = shape(SCNCapsule(capRadius: radius, height: half + radius * 2), color)
        upperShape.position = v3(0, -half / 2, 0)
        upper.addChildNode(upperShape)
        let lower = SCNNode()
        lower.position = v3(0, -half, 0)
        let lowerShape = shape(SCNCapsule(capRadius: radius * 0.92, height: half + radius * 2), color)
        lowerShape.position = v3(0, -half / 2, 0)
        lower.addChildNode(lowerShape)
        end.position = v3(end.position.x, -half, end.position.z)
        lower.addChildNode(end)
        upper.addChildNode(lower)
        return (upper, lower)
    }

    func apply(pose: Pose, clip: String, dt: CGFloat, showProp: Bool, speed: CGFloat, time: CGFloat) {
        let s = max(0.5, min(1.5, pose.squash))
        let wide = 1 / s.squareRoot()
        squashNode.scale = v3(wide, s, wide)
        rollNode.eulerAngles = v3(0, 0, pose.roll)
        yawNode.eulerAngles = v3(0, pose.yaw + pose.spin, 0)
        hips.position = v3(0, hipBase + pose.bodyY, 0)
        torso.eulerAngles = v3(pose.lean, pose.twist, pose.tilt)

        // Rotating a hanging limb about x by a negative angle swings it forward.
        legUpper[0].eulerAngles = v3(-pose.legL, 0, 0)
        legUpper[1].eulerAngles = v3(-pose.legR, 0, 0)
        legLower[0].eulerAngles = v3(pose.kneeL, 0, 0)
        legLower[1].eulerAngles = v3(pose.kneeR, 0, 0)
        armUpper[0].eulerAngles = v3(-pose.armL, 0, -pose.armOutL)
        armUpper[1].eulerAngles = v3(-pose.armR, 0, pose.armOutR)
        armLower[0].eulerAngles = v3(-pose.elbowL, 0, 0)
        armLower[1].eulerAngles = v3(-pose.elbowR, 0, 0)

        head.eulerAngles = v3(pose.headPitch, pose.headYaw, pose.headTilt)
        let open = max(0.06, min(1.25, pose.eyeOpen))
        for eye in eyes { eye.scale = v3(1, open, 1) }

        // Face
        let r = headRadius
        for pupil in pupils {
            pupil.position = v3(max(-1, min(1, pose.lookX)) * r * 0.075 * pupilTravel,
                                max(-1, min(1, pose.lookY)) * r * 0.06 * pupilTravel, pupilZ)
        }
        var browIndex = 0
        for brow in brows {
            let lift = pose.browLift + (browIndex == brows.count - 1 ? pose.browCock : 0)
            brow.position = v3(browX[browIndex], browY + lift * r * 0.11, r * 0.86)
            brow.eulerAngles = v3(0, 0, browSign[browIndex] * pose.browAngle * 0.45)
            browIndex += 1
        }
        let mouthOpen = max(0, min(1, pose.mouthOpen))
        if mouthVisible {
            let smile = max(-1, min(1, pose.smile))
            let mouthW = 0.9 + 0.5 * max(0, smile) - 0.25 * mouthOpen * (1 - abs(smile))
            let mouthH = 0.18 + 0.75 * mouthOpen + 0.25 * abs(smile)
            mouthDark.scale = v3(mouthW, mouthH, 0.25)
            let cover = abs(smile) * (1 - 0.6 * mouthOpen)
            let half = r * 0.16 * mouthH
            mouthMask.scale = v3(mouthW * 1.2, mouthH, 0.27)
            mouthMask.position = v3(0, (smile >= 0 ? 1 : -1) * half * (2 - 1.3 * cover), r * 0.015)
        }
        beakLower?.eulerAngles = v3(0.06 + mouthOpen * 0.55, 0, 0)
        let blush = max(0, min(1, pose.blush))
        for cheek in cheeks { cheek.opacity = blush * 0.7 }
        let g = max(0, min(1.5, pose.glow))
        var bulbIndex: CGFloat = 0
        for bulb in bulbNodes {
            // With two bulbs, they can pulse in turn instead of together.
            let turn = 0.5 + 0.5 * sin(time * 7 + bulbIndex * CGFloat.pi)
            let level = g * (1 - pose.glowAlt) + g * pose.glowAlt * (bulbNodes.count > 1 ? turn : 1)
            bulb.geometry?.firstMaterial?.emission.intensity = 0.25 + level * 1.6
            let bulbScale = 1 + 0.22 * level
            bulb.scale = v3(bulbScale, bulbScale, bulbScale)
            bulbIndex += 1
        }

        // Attachments react to motion already happening: a nod, a turn, a step or a landing.
        // Measuring rates, rather than applying impulses per frame, keeps their weight consistent.
        let elapsed = dt.isFinite ? max(0, dt) : 0
        let previous = lastAttachmentPose ?? pose
        func limited(_ value: CGFloat, to limit: CGFloat) -> CGFloat {
            max(-limit, min(limit, value))
        }
        func angularRate(_ current: CGFloat, _ old: CGFloat) -> CGFloat {
            guard elapsed > 0 else { return 0 }
            let delta = current - old
            return limited(atan2(sin(delta), cos(delta)) / elapsed, to: 12)
        }
        let headNod = angularRate(pose.lean + pose.headPitch, previous.lean + previous.headPitch)
        let headLean = angularRate(pose.tilt + pose.headTilt, previous.tilt + previous.headTilt)
        let turn = angularRate(pose.yaw + pose.spin + pose.headYaw, previous.yaw + previous.spin + previous.headYaw)
        let torsoNod = angularRate(pose.lean, previous.lean)
        let torsoLean = angularRate(pose.tilt, previous.tilt)
        let heave = elapsed > 0 ? limited(((pose.bodyY - previous.bodyY) / max(1, height)
            + (pose.squash - previous.squash) * 0.5) / elapsed, to: 4) : 0
        let stream = -min(abs(speed) * 0.004, 0.5)
        let headForce = limited(stream - headNod * 0.035 + heave * 0.045, to: 0.7)
        let sideForce = limited(-headLean * 0.045 - turn * 0.018, to: 0.35)
        let clothForce = limited(stream - torsoNod * 0.045 + heave * 0.035, to: 0.65)
        antennaPitch.advance(to: headForce, dt: elapsed, frequency: 13, damping: 0.56)
        antennaSway.advance(to: sideForce, dt: elapsed, frequency: 11, damping: 0.62)
        earPitch.advance(to: headForce, dt: elapsed, frequency: 10, damping: 0.66)
        earSway.advance(to: sideForce, dt: elapsed, frequency: 8.5, damping: 0.72)
        clothPitch.advance(to: clothForce, dt: elapsed, frequency: 8, damping: 0.72)
        clothSway.advance(to: limited(-torsoLean * 0.04 - turn * 0.025, to: 0.3), dt: elapsed, frequency: 7, damping: 0.75)
        scarfTip.advance(to: clothPitch.value, dt: elapsed, frequency: 6, damping: 0.72)
        lastAttachmentPose = pose

        var antennaIndex = 0
        for a in antennas {
            let lean: CGFloat = antennas.count == 2 ? (antennaIndex == 0 ? 0.3 : -0.3) : 0
            let weight: CGFloat = antennaIndex == 0 ? 1 : 0.88
            a.eulerAngles = v3(antennaPitch.value * weight + 0.35 * pose.twitch * sin(time * 34),
                              0, lean + antennaSway.value * weight)
            antennaIndex += 1
        }
        cape?.eulerAngles = v3(0.12 - clothPitch.value * 1.6, 0, clothSway.value)

        // A content tail is quiet; delight brings it to life, and it settles during a nap.
        // Low glow distinguishes resting eyes from an ordinary blink or happy squint.
        let resting = pose.eyeOpen < 0.2 && pose.glow < 0.12
        let delight = max(0, min(1, pose.smile))
        let movement = min(1, abs(speed) / 130)
        let wag = resting ? 0 : tailWag * (0.12 + 0.35 * delight + 0.5 * blush + 0.25 * movement)
        tailPhase = (tailPhase + elapsed * (1.5 + 1.7 * delight + 0.8 * movement)).truncatingRemainder(dividingBy: 2 * .pi)
        tailMotion.advance(to: wag * sin(tailPhase) + clothSway.value * 0.7,
                           dt: elapsed, frequency: 7, damping: 0.78)
        tail?.eulerAngles = v3(clothPitch.value * 0.6, tailMotion.value, 0)
        if ears.count == 2 {
            let flick = 0.3 * pose.twitch * sin(time * 34) * min(1, earFlop)
            let pinned = -1.25 * max(0, min(1, pose.earsBack)) * min(1, earFlop)
            ears[0].eulerAngles = v3(earPitch.value * earFlop + pinned, 0, earTilt + earSway.value * earFlop + flick)
            ears[1].eulerAngles = v3(earPitch.value * earFlop * 0.9 + pinned, 0, -earTilt + earSway.value * earFlop * 0.9 - flick)
        }
        if wings.count == 2 {
            let flap = max(0, min(1, pose.flap))
            let lift = 0.15 + flap * (0.25 + 0.7 * sin(time * 24))
            wings[0].eulerAngles = v3(0, 0.35 * (1 - flap), -lift)
            wings[1].eulerAngles = v3(0, -0.35 * (1 - flap), lift)
        }
        if scarfSegments.count == 2 {
            let flutter = sin(time * 9) * min(1, abs(speed) / 100)
            scarfSegments[0].eulerAngles = v3(0.35 + min(1.2, -clothPitch.value * 2.6) + 0.08 * flutter, 0, clothSway.value)
            scarfSegments[1].eulerAngles = v3(0.2 - scarfTip.value * 0.8 + 0.18 * flutter, 0, clothSway.value * 0.6)
        }
        prop.isHidden = !(showProp && pose.prop == 1)
        page.isHidden = !(showProp && pose.prop == 2)
    }
}

// MARK: - Body loaded from generated model files (one USDZ per animation clip)

final class ModelBody: CharacterBody {
    let root = SCNNode()
    let height: CGFloat
    let legLength: CGFloat
    private let rollNode = SCNNode()
    private let turn = SCNNode()
    private var clips: [String: SCNNode] = [:]
    private var current = ""
    private let yawOffset: CGFloat

    init?(folder: URL, height: CGFloat, yawOffset: CGFloat) {
        self.height = height
        self.legLength = height * 0.35
        self.yawOffset = yawOffset
        rollNode.position = v3(0, height * 0.45, 0)
        root.addChildNode(rollNode)
        turn.position = v3(0, -height * 0.45, 0)
        rollNode.addChildNode(turn)
        for name in ["idle", "walk", "run", "jump", "wave"] {
            let url = folder.appendingPathComponent(name + ".usdz")
            guard FileManager.default.fileExists(atPath: url.path),
                  let scene = try? SCNScene(url: url, options: nil) else { continue }
            let holder = SCNNode()
            for child in scene.rootNode.childNodes {
                child.removeFromParentNode()
                holder.addChildNode(child)
            }
            // Drop any lights or cameras that came along in the file.
            holder.enumerateHierarchy { node, _ in
                node.light = nil
                node.camera = nil
            }
            let wrap = SCNNode()
            wrap.addChildNode(holder)
            let fit = SCNNode()
            fit.addChildNode(wrap)

            // Measure from the skeleton, which is where the character is actually drawn.
            let topBone = holder.childNode(withName: "head_end", recursively: true)
                ?? holder.childNode(withName: "Head", recursively: true)
            let footBone = holder.childNode(withName: "LeftToeBase", recursively: true)
                ?? holder.childNode(withName: "LeftFoot", recursively: true)
            if let topBone, let footBone {
                var top = topBone.convertPosition(v3(0, 0, 0), to: wrap)
                var foot = footBone.convertPosition(v3(0, 0, 0), to: wrap)
                if abs(top.z - foot.z) > abs(top.y - foot.y) {
                    // The file is Z-up and was not converted on load: stand it upright.
                    holder.eulerAngles = v3(-CGFloat.pi / 2, 0, 0)
                    top = topBone.convertPosition(v3(0, 0, 0), to: wrap)
                    foot = footBone.convertPosition(v3(0, 0, 0), to: wrap)
                }
                let h = top.y - foot.y
                if h <= 0 { continue }
                let k = height * 0.88 / h
                fit.scale = v3(k, k, k)
                fit.position = v3(-top.x * k, -foot.y * k + height * 0.03, -top.z * k)
            } else {
                var box = wrap.boundingBox
                if box.max.z - box.min.z > (box.max.y - box.min.y) * 1.2 {
                    holder.eulerAngles = v3(-CGFloat.pi / 2, 0, 0)
                    box = wrap.boundingBox
                }
                let h = box.max.y - box.min.y
                if h <= 0 { continue }
                let k = height / h
                fit.scale = v3(k, k, k)
                fit.position = v3(-(box.min.x + box.max.x) / 2 * k, -box.min.y * k, -(box.min.z + box.max.z) / 2 * k)
            }
            holder.enumerateHierarchy { node, _ in
                for key in node.animationKeys {
                    if let player = node.animationPlayer(forKey: key) {
                        player.animation.repeatCount = .infinity
                        player.animation.usesSceneTimeBase = false
                        player.play()
                    }
                }
            }
            fit.isHidden = true
            turn.addChildNode(fit)
            clips[name] = fit
        }
        if clips.isEmpty { return nil }
    }

    func apply(pose: Pose, clip: String, dt: CGFloat, showProp: Bool, speed: CGFloat, time: CGFloat) {
        var want = clip
        if clips[want] == nil { want = clips["idle"] != nil ? "idle" : (clips.keys.first ?? "") }
        if want != current {
            clips[current]?.isHidden = true
            clips[want]?.isHidden = false
            current = want
        }
        rollNode.eulerAngles = v3(0, 0, pose.roll)
        turn.eulerAngles = v3(0, pose.yaw + pose.spin + yawOffset, 0)
    }
}
