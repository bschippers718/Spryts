import AppKit
import SpriteKit

// Stand-ins for the parts of the app the games lean on, so they can be run on their own.
enum GameSound { static func play(_ name: String, volume: Float = 0.35) {} }
struct ScoreEntry { var game: String; var host: String; var score: Int; var date: Date; var wave: Int?; var streak: Int? }
enum Leaderboard {
    static var added: [ScoreEntry] = []
    static func best(_ game: String) -> Int { 0 }
    static func add(_ entry: ScoreEntry) { added.append(entry) }
}
final class SprytCharacter {
    struct Sheet { var name = "Joy" }
    var sheet = Sheet()
    var playing = false
    var pendingSpeech: String?
    func wake() {}
    func wince() {}
    func cheer() {}
}
extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

@main
@MainActor
struct ArcadePlayChecks {
    static var checks = 0
    static var failures: [String] = []
    static func expect(_ condition: Bool, _ why: String) {
        checks += 1
        if condition { print("PASS  " + why) } else { failures.append(why); print("FAIL  " + why) }
    }

    static let size = CGSize(width: 1440, height: 900)
    static let floorY: CGFloat = 70
    static let desk = [
        DeskWindow(id: 11, rect: CGRect(x: 120, y: 330, width: 520, height: 360), order: 0),
        DeskWindow(id: 12, rect: CGRect(x: 520, y: 180, width: 620, height: 400), order: 1),
        DeskWindow(id: 13, rect: CGRect(x: 900, y: 420, width: 460, height: 330), order: 2),
        DeskWindow(id: 14, rect: CGRect(x: 60, y: 90, width: 380, height: 300), order: 3),
    ]

    /// Draws the scene over a stand-in desktop and saves it, so a person can look at what the game shows.
    static func snapshot(_ scene: SKScene, in view: SKView, to name: String, folder: URL) -> Bool {
        let backdrop = SKNode()
        backdrop.zPosition = -100
        let wall = SKShapeNode(rect: CGRect(origin: .zero, size: size))
        wall.fillColor = NSColor(hex: "#2E6E8E")
        wall.strokeColor = .clear
        backdrop.addChild(wall)
        for window in desk.reversed() {
            let pane = SKShapeNode(rect: window.rect, cornerRadius: 10)
            pane.fillColor = NSColor(hex: "#F4F4F6")
            pane.strokeColor = NSColor(hex: "#9A9AA2")
            backdrop.addChild(pane)
            let bar = SKShapeNode(rect: CGRect(x: window.rect.minX, y: window.rect.maxY - 28, width: window.rect.width, height: 28), cornerRadius: 10)
            bar.fillColor = NSColor(hex: "#DCDCE2")
            bar.strokeColor = .clear
            backdrop.addChild(bar)
        }
        scene.addChild(backdrop)
        defer { backdrop.removeFromParent() }
        guard let texture = view.texture(from: scene) else { return false }
        let image = texture.cgImage()
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? data.write(to: folder.appendingPathComponent(name))) != nil
    }

    static func main() {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
            .appendingPathComponent("arcade-shots")
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.allowsTransparency = true
        var clock: TimeInterval = 1

        // MARK: Window Climb
        let climb = ClimbScene(game: .climb, desk: desk, size: size, floorY: floorY, hostName: "Joy")
        var left = false
        climb.onLeave = { left = true }
        view.presentScene(climb)
        func tick(_ scene: ArcadeScene, _ seconds: Double, holding: Set<UInt16> = [], tap: Set<UInt16> = []) {
            scene.keys = holding.union(tap)
            scene.pressed = tap
            var passed = 0.0
            while passed < seconds {
                clock += 1.0 / 60
                passed += 1.0 / 60
                scene.update(clock)
            }
        }
        tick(climb, 0.3)
        let start = climb.probe
        expect(start.grounded && start.y == floorY, "the climber starts standing on the floor")
        let towardDoor: UInt16 = start.door.x > start.x ? ArcadeScene.Key.right : ArcadeScene.Key.left
        tick(climb, 0.8, holding: [towardDoor])
        let walked = climb.probe
        expect(abs(walked.x - start.x) > 150 && walked.y == floorY, "holding an arrow key runs along the floor")
        tick(climb, 1.0 / 60, holding: [ArcadeScene.Key.space], tap: [ArcadeScene.Key.space])
        var peak: CGFloat = 0
        for _ in 0..<70 {
            tick(climb, 1.0 / 60, holding: [ArcadeScene.Key.space])
            peak = max(peak, climb.probe.y - floorY)
        }
        expect(peak > ArcadeLevels.rise + 15 && peak < 200, "a held jump clears the tallest step with room to spare (peak \(Int(peak)))")
        tick(climb, 0.5)
        expect(climb.probe.grounded, "and lands again")
        tick(climb, 1.0 / 60, tap: [ArcadeScene.Key.space])
        var hop: CGFloat = 0
        for _ in 0..<60 {
            tick(climb, 1.0 / 60)
            hop = max(hop, climb.probe.y - floorY)
        }
        expect(hop > 20 && hop < peak - 30, "a tap is a short hop (peak \(Int(hop)))")
        expect(snapshot(climb, in: view, to: "climb.png", folder: folder), "Window Climb draws")
        // Twenty seconds of button mashing must never take her off the screen or stop the game unfairly.
        var onScreen = true
        for step in 0..<1200 {
            let keys: Set<UInt16> = [step % 180 < 90 ? ArcadeScene.Key.right : ArcadeScene.Key.left]
            tick(climb, 1.0 / 60, holding: keys, tap: step % 40 == 0 ? [ArcadeScene.Key.space] : (step % 55 == 0 ? [ArcadeScene.Key.x] : []))
            let p = climb.probe
            if p.x < 0 || p.x > size.width || p.y < floorY - 1 || p.y > size.height { onScreen = false }
        }
        expect(onScreen, "the climber never leaves the screen")
        expect(climb.lives <= 3 && climb.lives >= 0 && climb.score >= 0, "lives and score stay sensible through a rough run")
        climb.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                             characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: ArcadeScene.Key.escape)!)
        expect(left, "Esc leaves at once")

        // MARK: Window Breaker
        let breaker = BreakerScene(game: .breaker, desk: desk, size: size, floorY: floorY, hostName: "Joy")
        view.presentScene(breaker)
        tick(breaker, 0.2)
        let before = breaker.probe
        expect(before.bricks >= 14 && before.balls == 1, "the windows become bricks (\(before.bricks)) and one ball waits on the paddle")
        expect(snapshot(breaker, in: view, to: "breaker.png", folder: folder), "Window Breaker draws")
        tick(breaker, 1.0 / 60, tap: [ArcadeScene.Key.space])
        // A simple player: keep the paddle under the ball.
        var escaped = false
        var frames = 0
        while frames < 60 * 90 && !breaker.over && breaker.stage == 1 {
            frames += 1
            let p = breaker.probe
            var keys: Set<UInt16> = []
            if p.ballX < p.paddleX - 12 { keys.insert(ArcadeScene.Key.left) }
            if p.ballX > p.paddleX + 12 { keys.insert(ArcadeScene.Key.right) }
            tick(breaker, 1.0 / 60, holding: keys, tap: p.ballY < floorY + 100 ? [ArcadeScene.Key.space] : [])
            if p.ballX < -20 || p.ballX > size.width + 20 || p.ballY > size.height + 20 { escaped = true }
        }
        let after = breaker.probe
        expect(!escaped, "the ball never leaves the play area")
        expect(after.bricks < before.bricks - 10 || breaker.stage > 1, "a steady player breaks bricks (\(before.bricks) down to \(after.bricks), level \(breaker.stage))")
        expect(breaker.score > 100, "and scores (\(breaker.score))")
        _ = snapshot(breaker, in: view, to: "breaker-later.png", folder: folder)
        // Then stop playing: the ball must be lost fairly and the game must end and record the score.
        var idle = 0
        while idle < 60 * 240 && !breaker.over {
            idle += 1
            tick(breaker, 1.0 / 60, holding: [ArcadeScene.Key.left], tap: idle % 30 == 0 ? [ArcadeScene.Key.space] : [])
        }
        expect(breaker.over && breaker.lives == 0, "leaving the paddle in the corner ends the game")
        expect(Leaderboard.added.last?.game == "joy-breaker" && Leaderboard.added.last?.score == breaker.score, "and the score is recorded")
        _ = snapshot(breaker, in: view, to: "breaker-over.png", folder: folder)

        print("")
        print(failures.isEmpty ? "ARCADE PLAY CHECK OK: \(checks) checks" : "ARCADE PLAY CHECK FAILED: \(failures.count) of \(checks)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
