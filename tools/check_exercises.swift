import AppKit
import SceneKit

// Only the cloud has weather; the app gives every other body this empty version in CloudBody.swift.
extension CharacterBody { func setStorm(_ level: CGFloat) {} }

// Draws Rally doing each movement break, so the poses can be looked at, and checks the rep counting.
@main
struct ExerciseChecks {
    static var checks = 0
    static var failures: [String] = []
    static func expect(_ condition: Bool, _ why: String) {
        checks += 1
        if condition { print("PASS  " + why) } else { failures.append(why); print("FAIL  " + why) }
    }

    static func main() {
        let project = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        expect(Exercises.all.map { $0.id } == ["stand", "pushups", "situps", "squats"], "the four starter breaks are there")
        for exercise in Exercises.all where exercise.reps > 0 {
            expect(Exercises.rep(exercise, at: 0) == 0 && Exercises.rep(exercise, at: exercise.seconds) == exercise.reps
                   && Exercises.rep(exercise, at: 9_999) == exercise.reps,
                   "\(exercise.name): counts from 0 to \(exercise.reps) in the time he takes and no further")
        }
        var bounded = true
        for exercise in Exercises.all {
            var u: CGFloat = 0
            while u < exercise.seconds {
                let p = Exercises.pose(exercise.id, at: u, L: 30, facing: 1)
                for key in Pose.keys where !p[keyPath: key].isFinite || abs(p[keyPath: key]) > 40 { bounded = false }
                u += 0.05
            }
        }
        expect(bounded, "every pose stays finite all the way through")

        // The picture: Rally himself, in the poses that matter, standing on a floor line.
        guard let data = try? Data(contentsOf: project.appendingPathComponent("Characters/rally.json")),
              let sheet = try? JSONDecoder().decode(CharacterSheet.self, from: data) else {
            expect(false, "Rally's sheet can be read")
            finish()
        }
        let shots: [(String, CGFloat)] = [("stand", 6), ("stand", 13.5), ("stand", 24.4), ("pushups", 0), ("pushups", 1.3),
                                          ("situps", 0), ("situps", 1.1), ("squats", 0), ("squats", 1.1)]
        let scene = SCNScene()
        let spacing: CGFloat = 170
        for (index, shot) in shots.enumerated() {
            let body = ProceduralBody(look: sheet.look)
            var pose = Exercises.pose(shot.0, at: shot.1, L: body.legLength, facing: 1)
            pose.eyeOpen = 1
            body.apply(pose: pose, clip: "idle", dt: 1.0 / 60, showProp: false, speed: 0, time: 1)
            body.root.position = v3(CGFloat(index) * spacing, 0, 0)
            scene.rootNode.addChildNode(body.root)
        }
        let width = CGFloat(shots.count - 1) * spacing
        let floor = SCNNode(geometry: SCNBox(width: width + 300, height: 2, length: 400, chamferRadius: 0))
        floor.geometry?.firstMaterial?.diffuse.contents = NSColor(white: 0.25, alpha: 1)
        floor.position = v3(width / 2, -1, 0)
        scene.rootNode.addChildNode(floor)
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 110
        camera.zNear = 1
        camera.zFar = 4000
        let eye = SCNNode()
        eye.camera = camera
        eye.position = v3(width / 2, 80, 1500)
        scene.rootNode.addChildNode(eye)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 600
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 800
        sun.eulerAngles = v3(-0.55, 0.45, 0)
        scene.rootNode.addChildNode(sun)
        scene.background.contents = NSColor(white: 0.93, alpha: 1)

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.pointOfView = eye
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 2000, height: 2000 * 220 / (width + 260)), antialiasingMode: .multisampling4X)
        let folder = project.appendingPathComponent("arcade-shots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var saved = false
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            saved = (try? png.write(to: folder.appendingPathComponent("rally-breaks.png"))) != nil
        }
        expect(saved, "Rally is drawn doing each one (arcade-shots/rally-breaks.png)")
        finish()
    }

    static func finish() -> Never {
        print("")
        print(failures.isEmpty ? "EXERCISE CHECK OK: \(checks) checks" : "EXERCISE CHECK FAILED: \(failures.count) of \(checks)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
