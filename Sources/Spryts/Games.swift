import AppKit
import SceneKit
import SwiftUI

// MARK: - Leaderboard

struct ScoreEntry: Codable, Equatable {
    var game: String
    var host: String      // which character ran the game
    var score: Int
    var date: Date
    var wave: Int?
    var streak: Int?
}

/// Scores are kept on this Mac, next to the characters' memories.
enum Leaderboard {
    private static var file: URL { Harness.support.appendingPathComponent("scores.json") }

    static func all() -> [ScoreEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ScoreEntry].self, from: data)) ?? []
    }

    static func top(_ game: String, count: Int) -> [ScoreEntry] {
        let mine = all().filter { $0.game == game }
        let sorted = mine.sorted(by: { $0.score > $1.score })
        return Array(sorted.prefix(count))
    }

    static func best(_ game: String) -> Int {
        top(game, count: 1).first?.score ?? 0
    }

    static func add(_ entry: ScoreEntry) {
        var entries = all()
        entries.append(entry)
        // Keep the best fifty per game so the file never grows without limit.
        var kept: [ScoreEntry] = []
        let groups = Dictionary(grouping: entries, by: { $0.game })
        for (_, group) in groups {
            let sorted = group.sorted(by: { $0.score > $1.score })
            kept.append(contentsOf: sorted.prefix(50))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(kept) else { return }
        try? FileManager.default.createDirectory(at: Harness.support, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - Sound

/// Short system sounds, a few copies of each so quick hits can overlap.
enum GameSound {
    private static var pool: [String: [NSSound]] = [:]

    static func play(_ name: String, volume: Float = 0.35) {
        var copies = pool[name] ?? []
        var chosen: NSSound?
        for sound in copies where !sound.isPlaying {
            chosen = sound
            break
        }
        if chosen == nil && copies.count < 4 {
            if let fresh = NSSound(named: name)?.copy() as? NSSound {
                copies.append(fresh)
                pool[name] = copies
                chosen = fresh
            }
        }
        guard let sound = chosen else { return }
        sound.volume = volume
        sound.play()
    }
}

// MARK: - What the scoreboard shows

final class GameState: ObservableObject {
    @Published var title = "Orange Smash"
    @Published var host = ""
    @Published var score = 0
    @Published var lives = 3
    @Published var combo = 0          // hits in a row without a miss
    @Published var multiplier = 1
    @Published var wave = 0
    @Published var best = 0
    @Published var over = false
    @Published var paused = false
    @Published var sound = true
    @Published var effect = ""        // "Slow motion", "Frenzy!"
    @Published var note = ""          // a line about what the AI is doing
    @Published var smashed = 0
    @Published var bestStreak = 0
    @Published var board: [ScoreEntry] = []
    var onEnd: (() -> Void)?
    var onAgain: (() -> Void)?
}

struct GameHUDView: View {
    @ObservedObject var state: GameState
    let tint: Color

    var body: some View {
        VStack(spacing: 8) {
            bar
            if !state.note.isEmpty && !state.over {
                Text(state.note)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
            }
            if state.over {
                card
            }
            Spacer(minLength: 0)
        }
        .frame(width: 540)
        .frame(maxHeight: .infinity, alignment: .top)
        .fontDesign(.rounded)
    }

    private var bar: some View {
        HStack(spacing: 12) {
            scorePart
            Spacer(minLength: 4)
            statusPart
            controls
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1.5))
    }

    private var scorePart: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(red: 1.0, green: 0.58, blue: 0.1))
                .frame(width: 16, height: 16)
            Text("\(state.score)")
                .font(.system(size: 24, weight: .heavy))
                .monospacedDigit()
            if state.multiplier > 1 {
                Text("×\(state.multiplier)")
                    .font(.system(size: 14, weight: .heavy))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.45))
                    .clipShape(Capsule())
            }
            if state.combo >= 3 {
                Text("\(state.combo) in a row")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statusPart: some View {
        HStack(spacing: 10) {
            if !state.effect.isEmpty {
                Text(state.effect)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.blue)
            }
            Text(state.wave > 0 ? "Wave \(state.wave)" : "Get ready")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11))
                        .foregroundColor(i < state.lives ? Color.red : Color.primary.opacity(0.15))
                }
            }
            Text("Best \(state.best)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: {
                state.sound.toggle()
                UserDefaults.standard.set(!state.sound, forKey: "gameMuted")
            }) {
                Image(systemName: state.sound ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .buttonStyle(.plain)
            .help(state.sound ? "Mute" : "Sound on")
            Button(action: { state.paused.toggle() }) {
                Image(systemName: state.paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.plain)
            .help(state.paused ? "Carry on" : "Pause")
            Button("End") { state.onEnd?() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.1))
                .clipShape(Capsule())
        }
        .font(.system(size: 13))
    }

    private var card: some View {
        VStack(spacing: 8) {
            Text(state.score > 0 && state.score >= state.best ? "New best!" : "Game over")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.secondary)
            Text("\(state.score)")
                .font(.system(size: 44, weight: .heavy))
                .monospacedDigit()
            Text("\(state.smashed) smashed · best run \(state.bestStreak) · wave \(state.wave)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if !state.board.isEmpty {
                boardList
            }
            HStack(spacing: 10) {
                Button("Done") { state.onEnd?() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.1))
                    .clipShape(Capsule())
                Button("Play again") { state.onAgain?() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(tint.opacity(0.4))
                    .clipShape(Capsule())
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 320)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(tint.opacity(0.5), lineWidth: 1.5))
    }

    private var boardList: some View {
        VStack(spacing: 3) {
            ForEach(Array(state.board.enumerated()), id: \.offset) { item in
                HStack {
                    Text("\(item.offset + 1).")
                        .frame(width: 22, alignment: .trailing)
                        .foregroundColor(.secondary)
                    Text("\(item.element.score)")
                        .fontWeight(.bold)
                        .frame(width: 48, alignment: .leading)
                    Text("with " + item.element.host)
                    Spacer()
                    Text(item.element.date, format: .dateTime.month(.abbreviated).day())
                        .foregroundColor(.secondary)
                }
                .font(.system(size: 12))
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
    }
}

@MainActor
final class GameHUDController {
    private let panel: NSPanel
    private var tall: Bool?

    init(state: GameState, tint: NSColor) {
        let rect = NSRect(x: 0, y: 0, width: 540, height: 96)
        panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: GameHUDView(state: state, tint: Color(nsColor: tint)))
        host.frame = rect
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    /// A slim bar while playing, so it never covers the fruit; taller for the game-over card.
    func layout(over: Bool) {
        if tall == over { return }
        tall = over
        guard let screen = NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let height: CGFloat = over ? 420 : 96
        panel.setFrame(NSRect(x: area.midX - 270, y: area.maxY - height - 6, width: 540, height: height), display: true)
    }

    func show() {
        layout(over: false)
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }
}

// MARK: - Orange Smash

/// The character lobs oranges across the screen in waves. Flick the cursor through them, or click them,
/// before they hit the floor. Bombs are best left alone.
@MainActor
final class OrangeSmash {
    static let id = "orange-smash"

    enum Kind {
        case orange, golden, bomb, big, mini, heart, freeze, frenzy
    }

    private struct Fruit {
        let node: SCNNode
        var pos: CGPoint
        var vel: CGVector
        let radius: CGFloat
        let kind: Kind
        let spin: CGFloat
        let free: Bool        // dropping this one costs nothing
        var age: CGFloat
    }

    private struct Bit {
        let node: SCNNode
        var vel: CGVector
        var life: CGFloat
        let total: CGFloat
        let weight: CGFloat   // 0 hangs in the air (the slash trail), 1 falls
    }

    /// A piece of peel: it drops to the bottom of the screen and stays there, so the pile shows how you did.
    private struct Peel {
        let node: SCNNode
        var pos: CGPoint
        var vel: CGVector
        var angle: CGFloat
        let spin: CGFloat
        var landed: Bool
    }

    /// A number or a word that floats up from where something happened.
    private struct Popup {
        let node: SCNNode
        var life: CGFloat
        let total: CGFloat
    }

    /// One throw in a wave: how long after the previous one, what, and optionally exactly where.
    private struct Shot {
        var delay: CGFloat
        var kind: Kind
        var vx: CGFloat?
        var peak: CGFloat?    // 0...1 of the height available
    }

    /// Each character throws in its own way.
    private struct Style {
        var gravity: CGFloat = 1
        var sideways: CGFloat = 1
        var peakLow: CGFloat = 0.5
        var peakHigh: CGFloat = 0.95
        var bombs: CGFloat = 1
        var gold: CGFloat = 0.55
    }

    let state = GameState()
    let host: SprytCharacter
    private let stage: SCNNode
    private let style: Style
    private let role: String

    private var fruits: [Fruit] = []
    private var bits: [Bit] = []
    private var peels: [Peel] = []
    private var popups: [Popup] = []
    private var pile: [Int: CGFloat] = [:]   // how high the heap is in each narrow column of the screen
    private let column: CGFloat = 14

    private var frame = CGRect.zero
    private var floorY: CGFloat = 0
    private var clock: CGFloat = 0

    private var queue: [Shot] = []
    private var waveOn = false
    private var waveClean = true
    private var rest: CGFloat = 1.2
    private var slow: CGFloat = 0
    private var frenzy: CGFloat = 0
    private var frenzyClock: CGFloat = 0

    private var lastMouse = CGPoint.zero
    private var haveMouse = false
    private var chain = 0
    private var lastHit: CGFloat = -10
    private var sinceSaid: CGFloat = 20
    private var noteTime: CGFloat = 0
    private var wasBusy = false

    init(host: SprytCharacter, stage: SCNNode) {
        self.host = host
        self.stage = stage
        let r = host.sheet.role ?? "generalist"
        role = r
        var s = Style()
        if r == "coder" {
            // Quick, flat and full of bugs.
            s.sideways = 1.3
            s.peakLow = 0.4
            s.peakHigh = 0.8
            s.bombs = 1.4
        } else if r == "coach" {
            // Drills: brisk and wide, to keep you moving.
            s.sideways = 1.2
            s.peakLow = 0.55
            s.peakHigh = 0.9
        } else if r == "writer" {
            // Slow, high arcs with more treasure in them.
            s.gravity = 0.8
            s.peakLow = 0.65
            s.peakHigh = 1.0
            s.bombs = 0.8
            s.gold = 0.8
        }
        style = s
        state.host = host.sheet.name
        state.best = Leaderboard.best(OrangeSmash.id)
        state.sound = !UserDefaults.standard.bool(forKey: "gameMuted")
        wasBusy = host.session.busy
        if wasBusy {
            state.note = host.sheet.name + " is working. Play while you wait."
            noteTime = 6
        }
        host.playing = true
    }

    private var gravity: CGFloat { 900 * style.gravity }

    func restart() {
        clear()
        sweep()
        clock = 0
        queue = []
        waveOn = false
        waveClean = true
        rest = 1.0
        slow = 0
        frenzy = 0
        chain = 0
        lastHit = -10
        state.score = 0
        state.lives = 3
        state.combo = 0
        state.multiplier = 1
        state.wave = 0
        state.smashed = 0
        state.bestStreak = 0
        state.effect = ""
        state.over = false
        state.paused = false
        state.best = Leaderboard.best(OrangeSmash.id)
        host.playing = true
    }

    /// Removes everything in flight.
    func clear() {
        for fruit in fruits { fruit.node.removeFromParentNode() }
        for bit in bits { bit.node.removeFromParentNode() }
        for popup in popups { popup.node.removeFromParentNode() }
        fruits = []
        bits = []
        popups = []
    }

    /// Clears the heap of peel off the bottom of the screen.
    private func sweep() {
        for peel in peels { peel.node.removeFromParentNode() }
        peels = []
        pile = [:]
    }

    func stop() {
        clear()
        sweep()
        host.playing = false
    }

    private func sound(_ name: String, volume: Float = 0.35) {
        if state.sound { GameSound.play(name, volume: volume) }
    }

    // MARK: Things on screen

    private func tone(_ kind: Kind) -> NSColor {
        switch kind {
        case .orange, .mini: return NSColor(srgbRed: 1.0, green: 0.56, blue: 0.08, alpha: 1)
        case .big: return NSColor(srgbRed: 1.0, green: 0.45, blue: 0.05, alpha: 1)
        case .golden: return NSColor(srgbRed: 1.0, green: 0.84, blue: 0.2, alpha: 1)
        case .bomb: return NSColor(white: 0.14, alpha: 1)
        case .heart: return NSColor(srgbRed: 1.0, green: 0.3, blue: 0.45, alpha: 1)
        case .freeze: return NSColor(srgbRed: 0.45, green: 0.8, blue: 1.0, alpha: 1)
        case .frenzy: return NSColor(srgbRed: 0.75, green: 0.4, blue: 1.0, alpha: 1)
        }
    }

    private func size(_ kind: Kind) -> CGFloat {
        switch kind {
        case .orange: return 27
        case .big: return 40
        case .mini: return 18
        case .golden: return 21
        case .bomb: return 26
        case .heart, .freeze, .frenzy: return 23
        }
    }

    private func isSpecial(_ kind: Kind) -> Bool {
        kind == .heart || kind == .freeze || kind == .frenzy
    }

    private func makeFruit(kind: Kind, radius: CGFloat) -> SCNNode {
        let node = SCNNode()
        let sphere = SCNSphere(radius: radius)
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.specular.contents = NSColor(white: 1, alpha: 0.5)
        m.diffuse.contents = tone(kind)
        if kind == .golden {
            m.emission.contents = NSColor(srgbRed: 0.5, green: 0.38, blue: 0.0, alpha: 1)
        } else if isSpecial(kind) {
            m.emission.contents = tone(kind).withAlphaComponent(1).blended(withFraction: 0.6, of: .black) ?? NSColor.black
        }
        sphere.firstMaterial = m
        node.addChildNode(SCNNode(geometry: sphere))

        if isSpecial(kind) {
            // Power-ups wear a bright ring so they read as different at a glance.
            let ring = SCNTorus(ringRadius: radius * 1.3, pipeRadius: 2.2)
            let ringMaterial = SCNMaterial()
            ringMaterial.lightingModel = .constant
            ringMaterial.diffuse.contents = NSColor.white
            ring.firstMaterial = ringMaterial
            let ringNode = SCNNode(geometry: ring)
            ringNode.eulerAngles = v3(CGFloat.pi / 2, 0, 0)
            node.addChildNode(ringNode)
            return node
        }

        // A leaf for fruit, a lit fuse for bombs.
        let top = SCNSphere(radius: radius * 0.3)
        let topMaterial = SCNMaterial()
        if kind == .bomb {
            topMaterial.diffuse.contents = NSColor.red
            topMaterial.emission.contents = NSColor(srgbRed: 1.0, green: 0.3, blue: 0.1, alpha: 1)
        } else {
            topMaterial.diffuse.contents = NSColor(srgbRed: 0.25, green: 0.65, blue: 0.25, alpha: 1)
        }
        top.firstMaterial = topMaterial
        let topNode = SCNNode(geometry: top)
        topNode.position = v3(radius * 0.25, radius * 0.92, 0)
        topNode.scale = kind == .bomb ? v3(0.7, 0.7, 0.7) : v3(1.5, 0.45, 0.8)
        node.addChildNode(topNode)
        return node
    }

    private func place(_ node: SCNNode, at point: CGPoint, z: CGFloat) {
        node.position = v3(point.x - frame.minX, point.y - frame.minY, z)
    }

    private func spawn(_ kind: Kind, at point: CGPoint, vel: CGVector, free: Bool) {
        let radius = size(kind)
        let node = makeFruit(kind: kind, radius: radius)
        place(node, at: point, z: 700)
        stage.addChildNode(node)
        fruits.append(Fruit(node: node, pos: point, vel: vel, radius: radius, kind: kind,
                            spin: CGFloat.random(in: -5...5), free: free, age: 0))
    }

    /// Where throws start: the character's hand, or the bottom of the screen if it has wandered off stage.
    private var origin: CGPoint {
        if host.isOffstage { return CGPoint(x: frame.midX, y: floorY + 40) }
        return host.handPoint
    }

    private func lob(_ kind: Kind, vx wanted: CGFloat?, peak wantedPeak: CGFloat?, free: Bool) {
        let start = origin
        let room = max(220, frame.maxY - 130 - start.y)
        let fraction = wantedPeak ?? CGFloat.random(in: style.peakLow...style.peakHigh)
        let vy = (2 * gravity * room * fraction).squareRoot()
        var vx: CGFloat
        if let wanted {
            vx = wanted
        } else {
            let toCenter = frame.midX - start.x
            vx = toCenter * CGFloat.random(in: 0.05...0.5) + CGFloat.random(in: -170...170)
            vx *= style.sideways
        }
        vx = max(-520, min(520, vx))
        if kind == .golden { vx *= 1.25 }
        spawn(kind, at: start, vel: CGVector(dx: vx, dy: vy), free: free)
        host.throwSomething(toward: vx)
    }

    private func burst(at point: CGPoint, color: NSColor, count: Int, speed: CGFloat) {
        var i = 0
        while i < count && bits.count < 160 {
            let sphere = SCNSphere(radius: CGFloat.random(in: 3...8))
            sphere.segmentCount = 8
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = i % 3 == 0 ? NSColor(srgbRed: 1.0, green: 0.92, blue: 0.7, alpha: 1) : color
            sphere.firstMaterial = m
            let node = SCNNode(geometry: sphere)
            place(node, at: point, z: 720)
            stage.addChildNode(node)
            let angle = CGFloat.random(in: 0...(2 * CGFloat.pi))
            let v = CGFloat.random(in: 0.25...1) * speed
            let life = CGFloat.random(in: 0.35...0.7)
            bits.append(Bit(node: node, vel: CGVector(dx: cos(angle) * v, dy: sin(angle) * v + 120),
                            life: life, total: life, weight: 1))
            i += 1
        }
    }

    /// A bright dot left behind a fast cursor, so a flick reads as a blade.
    private func trail(at point: CGPoint) {
        if bits.count >= 160 { return }
        let sphere = SCNSphere(radius: 5)
        sphere.segmentCount = 8
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.white
        sphere.firstMaterial = m
        let node = SCNNode(geometry: sphere)
        place(node, at: point, z: 730)
        stage.addChildNode(node)
        bits.append(Bit(node: node, vel: CGVector(dx: 0, dy: 0), life: 0.22, total: 0.22, weight: 0))
    }

    private func popup(_ words: String, at point: CGPoint, color: NSColor, size: CGFloat) {
        if popups.count > 14 {
            popups[0].node.removeFromParentNode()
            popups.remove(at: 0)
        }
        let holder = SCNNode()
        var layer = 0
        while layer < 2 {
            // A dark copy just behind keeps the words readable over any window.
            let text = SCNText(string: words, extrusionDepth: 0)
            text.font = NSFont.systemFont(ofSize: size, weight: .heavy)
            text.flatness = 0.4
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = layer == 0 ? NSColor(white: 0, alpha: 0.75) : color
            text.firstMaterial = m
            let node = SCNNode(geometry: text)
            let box = node.boundingBox
            let middle = (box.min.x + box.max.x) / 2
            let offset: CGFloat = layer == 0 ? 1.5 : 0
            node.position = v3(-middle + offset, -offset, CGFloat(layer))
            holder.addChildNode(node)
            layer += 1
        }
        let x = max(frame.minX + 60, min(frame.maxX - 60, point.x))
        place(holder, at: CGPoint(x: x, y: point.y), z: 760)
        stage.addChildNode(holder)
        popups.append(Popup(node: holder, life: 1.0, total: 1.0))
    }

    private func dropPeel(at point: CGPoint, kind: Kind) {
        let pieces = kind == .big ? 5 : (kind == .golden ? 4 : (kind == .mini ? 2 : 3))
        var i = 0
        while i < pieces {
            let piece = CGFloat.random(in: 8...13)
            let sphere = SCNSphere(radius: piece)
            sphere.segmentCount = 10
            let m = SCNMaterial()
            m.lightingModel = .blinn
            let shade = CGFloat.random(in: -0.08...0.08)
            m.diffuse.contents = kind == .golden
                ? NSColor(srgbRed: 1.0, green: 0.82 + shade, blue: 0.2, alpha: 1)
                : NSColor(srgbRed: 1.0, green: 0.55 + shade, blue: 0.08, alpha: 1)
            sphere.firstMaterial = m
            let node = SCNNode(geometry: sphere)
            node.scale = v3(1, 0.36, 1)   // a curl of rind rather than a ball
            place(node, at: point, z: 690)
            stage.addChildNode(node)
            peels.append(Peel(node: node, pos: point,
                              vel: CGVector(dx: CGFloat.random(in: -150...150), dy: CGFloat.random(in: 40...260)),
                              angle: CGFloat.random(in: 0...3), spin: CGFloat.random(in: -7...7), landed: false))
            i += 1
        }
        // Keep the heap from growing without limit: the oldest pieces go first.
        while peels.count > 500 {
            peels[0].node.removeFromParentNode()
            peels.remove(at: 0)
        }
    }

    // MARK: What the character says

    private func say(_ lines: [String]) {
        if sinceSaid < 9 || lines.isEmpty { return }
        sinceSaid = 0
        host.pendingSpeech = lines.randomElement()
    }

    private var missLines: [String] {
        if role == "coder" { return ["That one slipped past the tests.", "Dropped frame!", "Off by one."] }
        if role == "writer" { return ["A tragic ending for that one.", "And so it fell.", "Plot twist: gravity."] }
        if role == "coach" { return ["Shake it off. Next rep!", "Reset. Eyes up.", "That's one. Still in it."] }
        if role == "forecaster" { return ["Well, that one's dropped.", "Sorry, a little drizzle there.", "Gusty. It happens."] }
        return ["Ooh, so close!", "That one got away.", "Eyes on the oranges!"]
    }

    private var bombLines: [String] {
        if role == "coder" { return ["That was a bug, not a feature.", "You shipped the bomb."] }
        if role == "writer" { return ["Never trust the dark ones.", "A cautionary tale."] }
        if role == "coach" { return ["Discipline! Leave the bombs.", "Bad rep. Breathe, go again."] }
        if role == "forecaster" { return ["Storm warning: bombs ahead.", "Lightning. Leave it alone."] }
        return ["Not the bombs!", "Boom. Leave those ones."]
    }

    private var streakLines: [String] {
        if role == "coder" { return ["Clean run!", "All green!", "You're compiling nicely."] }
        if role == "writer" { return ["Poetry in motion.", "What a chapter!", "Bravo!"] }
        if role == "coach" { return ["That's form!", "Strong set! Keep the pace.", "Now you're warmed up."] }
        if role == "forecaster" { return ["Clearing up nicely!", "Sunshine, all the way!", "Not a cloud in sight."] }
        return ["You're on fire!", "Look at you go!", "Unstoppable!"]
    }

    private var waveLines: [String] {
        if role == "coder" { return ["Flawless. Shipping the next wave.", "No misses. Scaling up."] }
        if role == "writer" { return ["A perfect stanza. Next verse!", "Not a word out of place."] }
        if role == "coach" { return ["Clean set. Adding load.", "Perfect round! Next one's harder."] }
        if role == "forecaster" { return ["A front of perfect weather!", "Settled, sunny, and staying that way."] }
        return ["Perfect wave! Here come more.", "Too easy? Try these."]
    }

    // MARK: Waves

    private func bombChance(_ n: Int) -> CGFloat {
        if n < 3 { return 0 }
        return min(0.4, (0.1 + CGFloat(n) * 0.03) * style.bombs)
    }

    private func buildWave(_ n: Int) {
        var shots: [Shot] = []
        let gap = max(0.55, 1.35 - CGFloat(n) * 0.07)
        var budget = min(26, 4 + n * 2)
        var first = true
        let toCenter = frame.midX - origin.x
        let lean = max(-200, min(200, toCenter * 0.3))
        while budget > 0 {
            let roll = CGFloat.random(in: 0...1)
            let lead = first ? 0.3 : gap * CGFloat.random(in: 0.8...1.2)
            first = false
            if n >= 2 && roll < 0.24 && budget >= 3 {
                // A fan: several at once in a line, made to be cut with one flick.
                let most = min(5, 3 + n / 3)
                let count = min(budget, Int.random(in: 3...most))
                let peak = CGFloat.random(in: style.peakLow...style.peakHigh)
                var i = 0
                while i < count {
                    let offset = (CGFloat(i) - CGFloat(count - 1) / 2) * 120
                    shots.append(Shot(delay: i == 0 ? lead : 0, kind: .orange, vx: lean + offset, peak: peak))
                    i += 1
                }
                if CGFloat.random(in: 0...1) < bombChance(n) {
                    shots.append(Shot(delay: 0, kind: .bomb, vx: lean + CGFloat.random(in: -90...90), peak: peak * 0.92))
                }
                budget -= count
            } else if n >= 3 && roll < 0.42 && budget >= 4 {
                // A stream: one after another along the same arc.
                let count = min(budget, Int.random(in: 4...6))
                let peak = CGFloat.random(in: style.peakLow...style.peakHigh)
                let vx = lean + CGFloat.random(in: -220...220)
                var i = 0
                while i < count {
                    shots.append(Shot(delay: i == 0 ? lead : 0.17, kind: .orange, vx: vx, peak: peak))
                    i += 1
                }
                budget -= count
            } else if roll < 0.62 && budget >= 2 {
                // A pair going opposite ways.
                let side = CGFloat.random(in: 120...300)
                shots.append(Shot(delay: lead, kind: .orange, vx: lean - side, peak: nil))
                shots.append(Shot(delay: 0, kind: .orange, vx: lean + side, peak: nil))
                budget -= 2
            } else {
                let big = n >= 2 && CGFloat.random(in: 0...1) < 0.2
                shots.append(Shot(delay: lead, kind: big ? .big : .orange, vx: nil, peak: nil))
                if CGFloat.random(in: 0...1) < bombChance(n) * 0.6 {
                    shots.append(Shot(delay: 0.25, kind: .bomb, vx: nil, peak: nil))
                }
                budget -= 1
            }
        }
        // Treats, dropped in somewhere after the opening throw.
        var treats: [Kind] = []
        if CGFloat.random(in: 0...1) < style.gold { treats.append(.golden) }
        if state.lives < 3 && CGFloat.random(in: 0...1) < 0.4 { treats.append(.heart) }
        if n >= 2 && CGFloat.random(in: 0...1) < 0.3 { treats.append(.freeze) }
        if n >= 4 && CGFloat.random(in: 0...1) < 0.25 { treats.append(.frenzy) }
        for treat in treats {
            let at = shots.count > 1 ? Int.random(in: 1...shots.count) : shots.count
            shots.insert(Shot(delay: 0.25, kind: treat, vx: nil, peak: nil), at: at)
        }
        queue = shots
    }

    // MARK: Hits and misses

    /// True when the cursor is over something clickable, so the stage should take the click.
    func hovering(_ mouse: CGPoint) -> Bool {
        if state.over || state.paused { return false }
        for fruit in fruits where hypot(fruit.pos.x - mouse.x, fruit.pos.y - mouse.y) < fruit.radius + 16 {
            return true
        }
        return false
    }

    /// A click on the stage. Returns true if it hit something.
    func click(at point: CGPoint) -> Bool {
        if state.over || state.paused { return false }
        var hit: Int?
        var nearest = CGFloat.greatestFiniteMagnitude
        for (index, fruit) in fruits.enumerated() {
            let d = hypot(fruit.pos.x - point.x, fruit.pos.y - point.y)
            if d < fruit.radius + 16 && d < nearest {
                nearest = d
                hit = index
            }
        }
        guard let index = hit else { return false }
        smash(index)
        return true
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = dx * dx + dy * dy
        if length < 0.001 { return hypot(p.x - a.x, p.y - a.y) }
        var s = ((p.x - a.x) * dx + (p.y - a.y) * dy) / length
        s = max(0, min(1, s))
        return hypot(p.x - (a.x + s * dx), p.y - (a.y + s * dy))
    }

    /// A fast flick of the cursor cuts everything along its path.
    private func slice(from a: CGPoint, to b: CGPoint) {
        var index = fruits.count - 1
        while index >= 0 {
            if index < fruits.count {
                let fruit = fruits[index]
                if fruit.age > 0.15 && distance(from: fruit.pos, toSegment: a, b) < fruit.radius + 8 {
                    smash(index)
                    if state.over { return }
                }
            }
            index -= 1
        }
    }

    private func smash(_ index: Int) {
        let fruit = fruits.remove(at: index)
        fruit.node.removeFromParentNode()
        let point = fruit.pos

        if fruit.kind == .bomb {
            burst(at: point, color: NSColor(white: 0.25, alpha: 1), count: 16, speed: 520)
            popup("Boom!", at: point, color: NSColor(srgbRed: 1.0, green: 0.35, blue: 0.3, alpha: 1), size: 30)
            sound("Basso", volume: 0.5)
            say(bombLines)
            loseLife()
            return
        }

        burst(at: point, color: tone(fruit.kind), count: fruit.kind == .golden || fruit.kind == .big ? 18 : 12, speed: 460)
        if !isSpecial(fruit.kind) { dropPeel(at: point, kind: fruit.kind) }

        // Hits in a row raise the multiplier; several in one flick add a bonus on top.
        state.combo += 1
        state.smashed += 1
        if state.combo > state.bestStreak { state.bestStreak = state.combo }
        state.multiplier = min(5, 1 + state.combo / 8)
        if clock - lastHit < 0.4 {
            chain += 1
        } else {
            chain = 1
        }
        lastHit = clock

        var base = 1
        if fruit.kind == .golden { base = 5 }
        if fruit.kind == .big { base = 2 }
        let gain = base * state.multiplier + (chain - 1)
        state.score += gain

        let warm = NSColor(srgbRed: 1.0, green: 0.95, blue: 0.75, alpha: 1)
        popup("+\(gain)", at: CGPoint(x: point.x, y: point.y + fruit.radius), color: fruit.kind == .golden ? tone(.golden) : warm,
              size: gain >= 5 ? 30 : 22)
        if chain == 3 {
            popup("Triple!", at: CGPoint(x: point.x, y: point.y + 60), color: tone(.frenzy), size: 28)
        } else if chain == 5 {
            popup("Five in one!", at: CGPoint(x: point.x, y: point.y + 60), color: tone(.frenzy), size: 32)
            host.cheer()
        }
        if state.combo == 10 || state.combo == 25 || state.combo == 50 || state.combo == 100 {
            popup("\(state.combo) in a row!", at: CGPoint(x: frame.midX, y: frame.midY + 120), color: tone(.golden), size: 36)
            sound("Glass")
            host.cheer()
            say(streakLines)
        }

        switch fruit.kind {
        case .golden:
            sound("Glass")
            host.cheer()
        case .big:
            // A big one splits into three little ones that are pure bonus.
            sound("Pop", volume: 0.5)
            var i = 0
            while i < 3 {
                let vx = (CGFloat(i) - 1) * 210 + CGFloat.random(in: -50...50)
                spawn(.mini, at: point, vel: CGVector(dx: vx, dy: CGFloat.random(in: 260...430)), free: true)
                i += 1
            }
        case .heart:
            sound("Ping")
            if state.lives < 3 { state.lives += 1 }
            popup("Extra life", at: CGPoint(x: point.x, y: point.y + 50), color: tone(.heart), size: 26)
        case .freeze:
            sound("Submarine")
            slow = 5
            popup("Slow motion", at: CGPoint(x: point.x, y: point.y + 50), color: tone(.freeze), size: 26)
        case .frenzy:
            sound("Hero")
            frenzy = 6
            frenzyClock = 0
            popup("Frenzy!", at: CGPoint(x: frame.midX, y: frame.midY + 120), color: tone(.frenzy), size: 40)
            host.cheer()
        default:
            sound("Pop")
        }
    }

    private func miss(_ fruit: Fruit) {
        let point = CGPoint(x: fruit.pos.x, y: floorY + 6)
        burst(at: point, color: tone(fruit.kind), count: 8, speed: 220)
        if fruit.free || fruit.kind == .bomb || fruit.kind == .golden || isSpecial(fruit.kind) { return }
        popup("Miss", at: CGPoint(x: point.x, y: point.y + 30), color: NSColor(srgbRed: 1.0, green: 0.4, blue: 0.35, alpha: 1), size: 22)
        sound("Bottle")
        host.wince()
        say(missLines)
        loseLife()
    }

    private func loseLife() {
        state.combo = 0
        state.multiplier = 1
        chain = 0
        waveClean = false
        state.lives -= 1
        if state.lives <= 0 { finish() }
    }

    private func finish() {
        for fruit in fruits { fruit.node.removeFromParentNode() }
        fruits = []
        queue = []
        state.over = true
        state.effect = ""
        host.playing = false
        let newBest = state.score > 0 && state.score >= state.best
        if state.score > 0 {
            Leaderboard.add(ScoreEntry(game: OrangeSmash.id, host: host.sheet.name, score: state.score, date: Date(),
                                       wave: state.wave, streak: state.bestStreak))
        }
        if newBest {
            host.cheer()
            sound("Hero")
        } else {
            sound("Submarine")
        }
        state.best = max(state.best, state.score)
        state.board = Leaderboard.top(OrangeSmash.id, count: 5)
    }

    // MARK: Every frame

    private func moveBits(dt: CGFloat) {
        var b = bits.count - 1
        while b >= 0 {
            bits[b].life -= dt
            if bits[b].life <= 0 {
                bits[b].node.removeFromParentNode()
                bits.remove(at: b)
            } else {
                bits[b].vel.dy -= gravity * bits[b].weight * dt
                let node = bits[b].node
                node.position = v3(node.position.x + bits[b].vel.dx * dt, node.position.y + bits[b].vel.dy * dt, node.position.z)
                node.opacity = bits[b].life / bits[b].total
            }
            b -= 1
        }
    }

    private func movePopups(dt: CGFloat) {
        var p = popups.count - 1
        while p >= 0 {
            popups[p].life -= dt
            if popups[p].life <= 0 {
                popups[p].node.removeFromParentNode()
                popups.remove(at: p)
            } else {
                let node = popups[p].node
                node.position = v3(node.position.x, node.position.y + 70 * dt, node.position.z)
                let left = popups[p].life / popups[p].total
                node.opacity = min(1, left * 2.5)
                let grow = 1 + (1 - left) * 0.25
                node.scale = v3(grow, grow, 1)
            }
            p -= 1
        }
    }

    private func settlePeels(dt: CGFloat) {
        var i = 0
        while i < peels.count {
            if !peels[i].landed {
                peels[i].vel.dy -= gravity * dt
                peels[i].pos.x = max(frame.minX + 10, min(frame.maxX - 10, peels[i].pos.x + peels[i].vel.dx * dt))
                peels[i].pos.y += peels[i].vel.dy * dt
                peels[i].angle += peels[i].spin * dt
                let slot = Int((peels[i].pos.x - frame.minX) / column)
                let top = floorY + (pile[slot] ?? 0) + 4
                if peels[i].pos.y <= top && peels[i].vel.dy < 0 {
                    // Landed: lie nearly flat on the heap and raise it here, and a little either side.
                    peels[i].pos.y = top
                    peels[i].landed = true
                    peels[i].angle = CGFloat.random(in: -0.5...0.5)
                    pile[slot] = min(240, (pile[slot] ?? 0) + 4.5)
                    pile[slot - 1] = min(240, (pile[slot - 1] ?? 0) + 2)
                    pile[slot + 1] = min(240, (pile[slot + 1] ?? 0) + 2)
                }
                let peel = peels[i]
                place(peel.node, at: peel.pos, z: 690)
                peel.node.eulerAngles = v3(0, 0, peel.angle)
            }
            i += 1
        }
    }

    private func moveFruit(dt: CGFloat) {
        var f = fruits.count - 1
        while f >= 0 {
            if f >= fruits.count {
                f -= 1
                continue
            }
            fruits[f].age += dt
            fruits[f].vel.dy -= gravity * dt
            fruits[f].pos.x += fruits[f].vel.dx * dt
            fruits[f].pos.y += fruits[f].vel.dy * dt
            // Bounce off the sides so nothing is lost off screen where it can't be reached.
            let r = fruits[f].radius
            if fruits[f].pos.x < frame.minX + r && fruits[f].vel.dx < 0 { fruits[f].vel.dx = -fruits[f].vel.dx }
            if fruits[f].pos.x > frame.maxX - r && fruits[f].vel.dx > 0 { fruits[f].vel.dx = -fruits[f].vel.dx }
            let fruit = fruits[f]
            place(fruit.node, at: fruit.pos, z: 700)
            fruit.node.eulerAngles = v3(fruit.node.eulerAngles.x, 0, fruit.node.eulerAngles.z + fruit.spin * dt)
            if fruit.pos.y < floorY + r * 0.6 && fruit.vel.dy < 0 {
                // Hit the floor without being smashed.
                fruit.node.removeFromParentNode()
                fruits.remove(at: f)
                miss(fruit)
                if state.over { return }
            }
            f -= 1
        }
    }

    private func runWaves(dt: CGFloat) {
        if frenzy > 0 {
            // A burst of free oranges: nothing to lose, lots to gain.
            frenzy -= dt
            frenzyClock -= dt
            if frenzyClock <= 0 {
                frenzyClock = 0.13
                lob(.orange, vx: CGFloat.random(in: -460...460), peak: CGFloat.random(in: 0.45...1.0), free: true)
            }
            return
        }
        if waveOn {
            var guardCount = 0
            while !queue.isEmpty && guardCount < 12 {
                queue[0].delay -= guardCount == 0 ? dt : 0
                if queue[0].delay > 0 { break }
                let shot = queue.removeFirst()
                lob(shot.kind, vx: shot.vx, peak: shot.peak, free: false)
                guardCount += 1
            }
            if queue.isEmpty && fruits.isEmpty {
                waveOn = false
                rest = 1.8
                if waveClean {
                    let bonus = 5 + state.wave * 2
                    state.score += bonus
                    popup("Perfect wave  +\(bonus)", at: CGPoint(x: frame.midX, y: frame.midY + 80), color: tone(.golden), size: 34)
                    sound("Glass")
                    host.cheer()
                    say(waveLines)
                }
            }
        } else {
            rest -= dt
            if rest <= 0 {
                state.wave += 1
                waveClean = true
                waveOn = true
                buildWave(state.wave)
                popup("Wave \(state.wave)", at: CGPoint(x: frame.midX, y: frame.midY + 160), color: NSColor.white, size: 38)
                sound("Tink", volume: 0.5)
            }
        }
    }

    func update(dt: CGFloat, frame newFrame: CGRect, floorY newFloor: CGFloat, mouse: CGPoint) {
        frame = newFrame
        floorY = newFloor
        clock += dt
        sinceSaid += dt

        // Things already in the air keep moving whatever else is going on.
        settlePeels(dt: dt)
        moveBits(dt: dt)
        movePopups(dt: dt)

        // Let the player know when the thing they were waiting for is ready.
        let busy = host.session.busy
        if wasBusy && !busy {
            state.note = host.sheet.name + " is finished. Your answer is ready."
            noteTime = 12
            sound("Ping", volume: 0.5)
        }
        wasBusy = busy
        if noteTime > 0 {
            noteTime -= dt
            if noteTime <= 0 { state.note = "" }
        }

        let moved = hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y)
        let previous = lastMouse
        let tracked = haveMouse
        lastMouse = mouse
        haveMouse = true

        if state.over || state.paused { return }
        host.noteInteraction()

        // A flick fast enough counts as a blade; easing the cursor past something leaves it alone.
        if tracked && dt > 0 && moved / dt > 900 && moved < 700 {
            trail(at: mouse)
            trail(at: CGPoint(x: (mouse.x + previous.x) / 2, y: (mouse.y + previous.y) / 2))
            slice(from: previous, to: mouse)
            if state.over { return }
        }

        var step = dt
        if slow > 0 {
            slow -= dt
            step = dt * 0.45
        }
        let effect = frenzy > 0 ? "Frenzy!" : (slow > 0 ? "Slow motion" : "")
        if state.effect != effect { state.effect = effect }

        runWaves(dt: step)
        moveFruit(dt: step)
    }
}
