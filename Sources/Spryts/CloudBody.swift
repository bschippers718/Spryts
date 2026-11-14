import AppKit
import SceneKit

/// A cloud with a face. No legs or arms: it hovers above the ground and its shadow sits below it.
/// When the chat is busy it rains, a light drizzle when idle and a downpour while working.
final class CloudBody: CharacterBody {
    let root = SCNNode()
    let height: CGFloat
    let legLength: CGFloat

    private let R: CGFloat
    private let hover: CGFloat
    private let cluster = SCNNode()
    private let backing = SCNNode()   // the outline; follows the cloud but never turns, so it stays even all round
    private let face = SCNNode()
    private var eyes: [SCNNode] = []
    private var eyeBase: [CGFloat] = []
    private let mouth = SCNNode()
    private var cheeks: [SCNNode] = []
    private var drops: [SCNNode] = []
    private var dropPhase: [CGFloat] = []
    private var dropX: [CGFloat] = []
    private var storm: CGFloat = 0.25
    private var stormShown: CGFloat = 0.25

    init(look: Look) {
        let H = look.height
        height = H
        legLength = H * 0.04
        hover = H * 0.42
        R = H * 0.2

        let body = NSColor(hex: look.body)
        let ink = NSColor(srgbRed: 0.12, green: 0.16, blue: 0.22, alpha: 1)

        root.addChildNode(cluster)
        root.addChildNode(backing)
        cluster.position = v3(0, hover, 0)

        // The cloud itself: a cluster of puffs, with a flatter base so it reads as a cloud and not a snowman.
        let puffs: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
            (0, 0, 1.0), (-1.1, -0.2, 0.74), (1.1, -0.15, 0.8), (-0.55, 0.7, 0.8), (0.6, 0.72, 0.7)
        ]
        // A darker copy just behind and a touch bigger gives the cloud an outline,
        // so a pale cloud still shows against a white window.
        let rim = NSColor(hex: look.trim ?? "#4C6A8C")
        for puff in puffs {
            let s = shape(SCNSphere(radius: R * puff.r), body)
            s.position = v3(puff.x * R, puff.y * R, 0)
            cluster.addChildNode(s)
            let edge = outline(SCNSphere(radius: R * puff.r + R * 0.11), rim)
            edge.position = v3(puff.x * R, puff.y * R, -R * 1.4)
            backing.addChildNode(edge)
        }
        let base = shape(SCNSphere(radius: R * 1.25), NSColor(hex: look.accent))
        base.position = v3(0, -0.7 * R, 0)
        base.scale = v3(1.3, 0.42, 0.9)
        cluster.addChildNode(base)
        let baseEdge = outline(SCNSphere(radius: R * 1.25), rim)
        baseEdge.position = v3(0, -0.7 * R, -R * 1.4)
        baseEdge.scale = v3(1.38, 0.52, 0.9)
        backing.addChildNode(baseEdge)

        // The face sits on the front of the main puff.
        face.position = v3(0, 0.12 * R, R * 0.8)
        cluster.addChildNode(face)
        for side in [CGFloat(-1), CGFloat(1)] {
            let eye = shape(SCNSphere(radius: R * 0.13), ink)
            eye.position = v3(side * R * 0.38, 0, 0)
            eye.scale = v3(1, 1, 0.5)
            face.addChildNode(eye)
            eyes.append(eye)
            eyeBase.append(side * R * 0.38)

            let cheek = shape(SCNSphere(radius: R * 0.14), NSColor(srgbRed: 1.0, green: 0.55, blue: 0.62, alpha: 1))
            cheek.position = v3(side * R * 0.62, -0.2 * R, -R * 0.05)
            cheek.scale = v3(1, 0.6, 0.3)
            cheek.opacity = 0
            face.addChildNode(cheek)
            cheeks.append(cheek)
        }
        // The mouth is a short capsule lying flat: wider for a grin, thicker when open.
        let mouthShape = shape(SCNCapsule(capRadius: R * 0.045, height: R * 0.42), ink)
        mouthShape.eulerAngles = v3(0, 0, CGFloat.pi / 2)
        mouth.position = v3(0, -0.28 * R, 0.02 * R)
        mouth.addChildNode(mouthShape)
        face.addChildNode(mouth)

        // Rain: a few drops that fall from under the cloud, faded in and out by how heavy the storm is.
        let drizzle = NSColor(hex: look.accent)
        for i in 0..<6 {
            let drop = shape(SCNCylinder(radius: R * 0.06, height: R * 0.4), drizzle)
            drop.opacity = 0
            cluster.addChildNode(drop)
            drops.append(drop)
            dropPhase.append(CGFloat(i) / 6)
            dropX.append((CGFloat(i) / 5 - 0.5) * 1.6 * R)
        }
    }

    func setStorm(_ level: CGFloat) {
        storm = max(0, min(1, level))
    }

    func apply(pose p: Pose, clip: String, dt: CGFloat, showProp: Bool, speed: CGFloat, time t: CGFloat) {
        // Hovering: a slow bob, plus whatever the behaviour asks for (hops, sinks, squashes).
        let bob = sin(t * 2.2) * height * 0.015
        cluster.position = v3(0, hover + p.bodyY + bob, 0)
        cluster.eulerAngles = v3(p.lean * 0.4, p.yaw, p.tilt)
        cluster.scale = v3(1 + (1 - p.squash) * 0.6, p.squash, 1)
        backing.position = cluster.position
        backing.eulerAngles = v3(0, 0, p.tilt)
        backing.scale = cluster.scale

        face.eulerAngles = v3(p.headPitch * 0.5, p.headYaw, p.headTilt)
        for (i, eye) in eyes.enumerated() {
            eye.position.x = eyeBase[i] + p.lookX * R * 0.05
            eye.position.y = p.lookY * R * 0.05
            eye.scale.y = max(0.08, p.eyeOpen)
        }
        mouth.scale = v3(0.7 + 0.5 * p.smile, 1 + 2 * p.mouthOpen, 1)
        mouth.position.y = -0.28 * R + p.smile * 0.04 * R
        for cheek in cheeks {
            cheek.opacity = p.blush
        }

        // Rain falls while the cloud is busy, and a little when idle.
        stormShown += (storm - stormShown) * min(1, dt * 4)
        for (i, drop) in drops.enumerated() {
            let fall = (dropPhase[i] + t * (0.9 + 0.15 * CGFloat(i % 3))).truncatingRemainder(dividingBy: 1)
            drop.position = v3(dropX[i], -0.9 * R - fall * height * 0.45, 0)
            drop.opacity = stormShown * (1 - fall) * 0.9
        }
    }
}

extension CharacterBody {
    /// Only the cloud rains. Other bodies ignore it.
    func setStorm(_ level: CGFloat) {}
}

/// A flat, unlit shape, used behind the cloud as its outline.
private func outline(_ geometry: SCNGeometry, _ color: NSColor) -> SCNNode {
    let m = SCNMaterial()
    m.diffuse.contents = color
    m.lightingModel = .constant
    geometry.firstMaterial = m
    return SCNNode(geometry: geometry)
}

private func shape(_ geometry: SCNGeometry, _ color: NSColor) -> SCNNode {
    let m = SCNMaterial()
    m.diffuse.contents = color
    m.specular.contents = NSColor(white: 1, alpha: 0.3)
    m.shininess = 0.3
    m.lightingModel = .blinn
    geometry.firstMaterial = m
    return SCNNode(geometry: geometry)
}
