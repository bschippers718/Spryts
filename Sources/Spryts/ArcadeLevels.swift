import CoreGraphics
import Foundation

// Joy's games are played on the desktop as it is right now: the open windows are the level.
// This file turns a list of window rectangles into ledges to climb and bricks to break. It only measures;
// nothing here (or anywhere in the arcade) moves, closes or reads a real window.

/// A window as the games see it: where it is and how far forward. Order 0 is the frontmost.
struct DeskWindow: Equatable {
    let id: Int
    let rect: CGRect
    let order: Int
}

/// Something to stand on.
struct Ledge: Equatable {
    enum Kind: Equatable {
        case floor
        case window(Int)     // the visible part of a window's top edge
        case folder          // a stepping stone the level adds so the top can always be reached
    }
    var minX: CGFloat
    var maxX: CGFloat
    var y: CGFloat
    var kind: Kind

    var midX: CGFloat { (minX + maxX) / 2 }
    var width: CGFloat { maxX - minX }
}

struct ClimbLevel: Equatable {
    var ledges: [Ledge]      // the floor is always first
    var start: CGPoint
    var door: CGPoint        // stands on the highest ledge
    var coins: [CGPoint]
}

struct Brick: Equatable {
    var rect: CGRect
    var window: Int          // 0 for the spare wall on an empty desktop
    var hits: Int            // 2 for a window's title bar row
}

/// A small repeatable random source, so a level can be rebuilt and checked.
struct ArcadeDice {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 2862933555777941757 &+ 3037000493 }

    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 10_000) / 10_000
    }

    mutating func between(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + (high - low) * next() }
}

enum ArcadeLevels {
    /// How high and how far the climber can be asked to jump. The game's physics clear both with room to spare.
    static let rise: CGFloat = 130
    static let reach: CGFloat = 150
    static let drop: CGFloat = 230
    static let folderWidth: CGFloat = 96

    // MARK: Ledges

    /// The parts of each window's top edge that are not hidden behind a window in front of it.
    static func ledges(windows: [DeskWindow], frame: CGRect, floorY: CGFloat) -> [Ledge] {
        var out: [Ledge] = []
        let ordered = windows.sorted { $0.order < $1.order }
        for window in ordered {
            let y = window.rect.maxY
            // Leave headroom for the climber and the scoreboard, and skip edges too near the floor to matter.
            if y < floorY + 70 || y > frame.maxY - 150 { continue }
            var pieces: [(CGFloat, CGFloat)] = [(max(window.rect.minX, frame.minX + 4), min(window.rect.maxX, frame.maxX - 4))]
            for front in ordered where front.order < window.order {
                // A window in front hides the edge wherever it covers the strip just above it.
                if front.rect.minY > y + 8 || front.rect.maxY < y + 2 { continue }
                var next: [(CGFloat, CGFloat)] = []
                for (a, b) in pieces {
                    if front.rect.maxX <= a || front.rect.minX >= b {
                        next.append((a, b))
                        continue
                    }
                    if front.rect.minX > a { next.append((a, front.rect.minX)) }
                    if front.rect.maxX < b { next.append((front.rect.maxX, b)) }
                }
                pieces = next
            }
            for (a, b) in pieces where b - a >= 70 {
                out.append(Ledge(minX: a, maxX: b, y: y, kind: .window(window.id)))
            }
        }
        // Ledges almost on top of each other read as one muddle: keep the wider.
        var kept: [Ledge] = []
        for ledge in out.sorted(by: { $0.width > $1.width }) {
            let crowded = kept.contains { abs($0.y - ledge.y) < 34 && $0.minX < ledge.maxX && ledge.minX < $0.maxX }
            if !crowded { kept.append(ledge) }
        }
        return kept.sorted { $0.y < $1.y }
    }

    /// Whether a climber standing on `a` can get onto `b`. Ledges are one-way: you can jump up through them.
    static func canReach(_ a: Ledge, _ b: Ledge) -> Bool {
        let gap = max(0, max(b.minX - a.maxX, a.minX - b.maxX))
        let up = b.y - a.y
        if up > rise { return false }
        return gap <= (up >= -20 ? reach : drop)
    }

    /// Every ledge that can be reached from the floor, by index.
    static func reachable(_ ledges: [Ledge]) -> Set<Int> {
        guard !ledges.isEmpty else { return [] }
        var seen: Set<Int> = [0]
        var queue = [0]
        while let current = queue.popLast() {
            for index in ledges.indices where !seen.contains(index) && canReach(ledges[current], ledges[index]) {
                seen.insert(index)
                queue.append(index)
            }
        }
        return seen
    }

    // MARK: The climb

    /// Builds a level from the desktop: window tops to stand on, folders added as stepping stones wherever
    /// the windows alone would leave a gap, a door on the highest ledge and a coin above each one.
    static func climb(windows: [DeskWindow], frame: CGRect, floorY: CGFloat, seed: UInt64) -> ClimbLevel {
        var dice = ArcadeDice(seed: seed)
        var ledges = [Ledge(minX: frame.minX, maxX: frame.maxX, y: floorY, kind: .floor)]
        ledges.append(contentsOf: self.ledges(windows: windows, frame: frame, floorY: floorY))
        let ceiling = frame.maxY - 190
        let inset: CGFloat = 20

        /// A staircase of folders from a point up to a height, drifting toward `towardX`.
        func stairs(from start: CGPoint, toY top: CGFloat, towardX: CGFloat) {
            var x = start.x
            var y = start.y
            var guardCount = 0
            while y + 40 < top && guardCount < 14 {
                guardCount += 1
                let step = min(rise * 0.82, top - y)
                y += max(60, step)
                let heading: CGFloat = abs(towardX - x) < 60 ? (dice.next() < 0.5 ? -1 : 1) : (towardX > x ? 1 : -1)
                x += heading * dice.between(70, reach * 0.8)
                x = min(frame.maxX - inset - folderWidth / 2, max(frame.minX + inset + folderWidth / 2, x))
                ledges.append(Ledge(minX: x - folderWidth / 2, maxX: x + folderWidth / 2, y: min(y, ceiling), kind: .folder))
            }
        }

        // Bridge to every window ledge that cannot be reached yet, lowest first.
        var rounds = 0
        while rounds < 24 && ledges.count < 70 {
            rounds += 1
            let open = reachable(ledges)
            let stranded = ledges.indices.filter { !open.contains($0) }.sorted { ledges[$0].y < ledges[$1].y }
            guard let target = stranded.first else { break }
            let goal = ledges[target]
            // Start from the reachable ledge that leaves the least climbing and walking to do.
            let from = open.min { first, second in
                func cost(_ index: Int) -> CGFloat {
                    let l = ledges[index]
                    let across = max(0, max(goal.minX - l.maxX, l.minX - goal.maxX))
                    return max(0, goal.y - l.y) * 1.4 + across + (l.y > goal.y ? 400 : 0)
                }
                return cost(first) < cost(second)
            } ?? 0
            let base = ledges[from]
            let footX = min(max(goal.midX, base.minX + 30), base.maxX - 30)
            let before = ledges.count
            // Walk the stairs sideways first if the goal is off to one side, then up.
            var x = footX
            var y = base.y
            var steps = 0
            while steps < 16 {
                steps += 1
                let across = goal.minX - 10 > x ? goal.minX - x : (x > goal.maxX + 10 ? goal.maxX - x : 0)
                let up = goal.y - y
                if up <= rise && abs(across) <= reach * 0.9 { break }
                let climb = min(rise * 0.82, max(0, up - 20))
                let run = max(-reach * 0.8, min(reach * 0.8, across))
                if climb < 20 && abs(run) < 20 { break }
                y += climb
                x += abs(run) > 20 ? run : (dice.next() < 0.5 ? -60 : 60)
                x = min(frame.maxX - inset - folderWidth / 2, max(frame.minX + inset + folderWidth / 2, x))
                ledges.append(Ledge(minX: x - folderWidth / 2, maxX: x + folderWidth / 2, y: y, kind: .folder))
            }
            if ledges.count == before && !reachable(ledges).contains(target) {
                // Nothing sensible to add: leave this one out of the level.
                ledges.remove(at: target)
            }
        }
        // Drop anything still out of reach, so the level is honest.
        let open = reachable(ledges)
        ledges = ledges.indices.filter { open.contains($0) }.map { ledges[$0] }

        // A level should be a climb. If the desktop tops out low (or is empty), build a tower above it.
        let highest = ledges.max { $0.y < $1.y } ?? ledges[0]
        if highest.y < floorY + (ceiling - floorY) * 0.6 {
            let from = CGPoint(x: highest.kind == .floor ? frame.minX + frame.width * dice.between(0.3, 0.7) : highest.midX, y: highest.y)
            stairs(from: from, toY: floorY + (ceiling - floorY) * dice.between(0.78, 0.95), towardX: frame.midX)
        }

        let top = ledges.max { $0.y < $1.y } ?? ledges[0]
        let door = CGPoint(x: top.midX, y: top.y)
        // Start on the floor, on the far side from the door, so the first steps are a walk and not a leap.
        let startX = door.x > frame.midX ? frame.minX + frame.width * 0.14 : frame.maxX - frame.width * 0.14
        var coins: [CGPoint] = []
        for ledge in ledges where ledge.kind != .floor && ledge != top && coins.count < 36 {
            coins.append(CGPoint(x: ledge.midX, y: ledge.y + 34))
            if ledge.width > 320 && coins.count < 36 {
                coins.append(CGPoint(x: ledge.minX + ledge.width * 0.22, y: ledge.y + 34))
                coins.append(CGPoint(x: ledge.minX + ledge.width * 0.78, y: ledge.y + 34))
            }
        }
        return ClimbLevel(ledges: ledges, start: CGPoint(x: startX, y: floorY), door: door, coins: coins)
    }

    // MARK: Bricks

    /// Tiles the visible part of every window with bricks. The real windows are only measured.
    static func bricks(windows: [DeskWindow], frame: CGRect, floorY: CGFloat, limit: Int = 150) -> [Brick] {
        // Bricks live in the upper part of the screen; the paddle needs the rest.
        let zone = CGRect(x: frame.minX + 12, y: floorY + (frame.maxY - floorY) * 0.34,
                          width: frame.width - 24, height: (frame.maxY - floorY) * 0.66 - 96)
        let ordered = windows.sorted { $0.order < $1.order }
        var scale: CGFloat = 1
        var out: [Brick] = []
        while scale <= 3.1 {
            out = []
            let w = 88 * scale
            let h = 30 * scale
            let gap: CGFloat = 4
            for window in ordered {
                let area = window.rect.intersection(zone)
                if area.isNull || area.width < w || area.height < h { continue }
                let columns = Int((area.width + gap) / (w + gap))
                let rows = Int((area.height + gap) / (h + gap))
                if columns < 1 || rows < 1 { continue }
                // Centre the grid in the window so the edges look deliberate.
                let left = area.minX + (area.width - CGFloat(columns) * (w + gap) + gap) / 2
                let topRowIsTitle = abs(area.maxY - window.rect.maxY) < 2
                for row in 0..<rows {
                    for column in 0..<columns {
                        let rect = CGRect(x: left + CGFloat(column) * (w + gap), y: area.maxY - CGFloat(row + 1) * (h + gap) + gap,
                                          width: w, height: h)
                        // A brick must be wholly on show: one that a nearer window overlaps would collide with that window's own.
                        let hidden = ordered.contains { $0.order < window.order && $0.rect.intersects(rect) }
                        if hidden { continue }
                        out.append(Brick(rect: rect, window: window.id, hits: row == 0 && topRowIsTitle ? 2 : 1))
                    }
                }
            }
            if out.count <= limit { break }
            scale += 0.3
        }
        if out.count > limit { out = Array(out.prefix(limit)) }
        if out.count < 14 {
            // A tidy desktop still gets a game: a classic wall across the top.
            out = []
            let columns = max(6, min(14, Int(zone.width / 104)))
            let w = (zone.width - CGFloat(columns - 1) * 6) / CGFloat(columns)
            for row in 0..<5 {
                for column in 0..<columns {
                    out.append(Brick(rect: CGRect(x: zone.minX + CGFloat(column) * (w + 6), y: zone.maxY - CGFloat(row + 1) * 36,
                                                  width: w, height: 30),
                                     window: 0, hits: row == 0 ? 2 : 1))
                }
            }
        }
        return out
    }
}
