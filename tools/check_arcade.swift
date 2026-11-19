import CoreGraphics
import Foundation

@main
struct ArcadeChecks {
    static var checks = 0
    static var failures: [String] = []

    static func expect(_ condition: Bool, _ why: String) {
        checks += 1
        if condition { print("PASS  " + why) } else { failures.append(why); print("FAIL  " + why) }
    }

    static let frame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    static let floorY: CGFloat = 70

    /// A messy desktop: a handful of windows of ordinary sizes, anywhere.
    static func desktop(_ seed: UInt64, count: Int) -> [DeskWindow] {
        var dice = ArcadeDice(seed: seed)
        var out: [DeskWindow] = []
        for index in 0..<count {
            let w = dice.between(320, 1100)
            let h = dice.between(220, 800)
            let x = dice.between(-80, frame.width - 200)
            let y = dice.between(floorY, frame.height - 260)
            let rect = CGRect(x: x, y: y, width: w, height: h).intersection(frame)
            out.append(DeskWindow(id: 100 + index, rect: rect, order: index))
        }
        return out
    }

    static func main() {
        // Ledges are the visible parts of window tops.
        let alone = [DeskWindow(id: 1, rect: CGRect(x: 200, y: 200, width: 600, height: 400), order: 0)]
        let one = ArcadeLevels.ledges(windows: alone, frame: frame, floorY: floorY)
        expect(one.count == 1 && one[0].y == 600 && one[0].minX == 200 && one[0].maxX == 800, "a window's top edge is a ledge")
        let split = alone + []
        let cover = [DeskWindow(id: 2, rect: CGRect(x: 400, y: 500, width: 200, height: 300), order: 0),
                     DeskWindow(id: 1, rect: split[0].rect, order: 1)]
        let two = ArcadeLevels.ledges(windows: cover, frame: frame, floorY: floorY).filter { $0.kind == .window(1) }
        expect(two.count == 2 && two.contains { $0.maxX == 400 } && two.contains { $0.minX == 600 }, "a window in front splits the ledge behind it")
        let buried = [DeskWindow(id: 2, rect: CGRect(x: 100, y: 100, width: 900, height: 700), order: 0),
                      DeskWindow(id: 1, rect: split[0].rect, order: 1)]
        expect(!ArcadeLevels.ledges(windows: buried, frame: frame, floorY: floorY).contains { $0.kind == .window(1) }, "a hidden edge is not a ledge")
        let extremes = [DeskWindow(id: 3, rect: CGRect(x: 0, y: 70, width: 500, height: 40), order: 0),
                        DeskWindow(id: 4, rect: CGRect(x: 600, y: 300, width: 500, height: 800), order: 1)]
        expect(ArcadeLevels.ledges(windows: extremes, frame: frame, floorY: floorY).isEmpty, "edges at the floor or under the scoreboard are left out")

        // The game's jump clears what the level asks of it (the numbers in ClimbScene).
        let gravity: CGFloat = 1800, jumpSpeed: CGFloat = 760, runSpeed: CGFloat = 300
        let apex = jumpSpeed * jumpSpeed / (2 * gravity)
        let timeToRise = (jumpSpeed + (jumpSpeed * jumpSpeed - 2 * gravity * ArcadeLevels.rise).squareRoot()) / gravity
        expect(apex > ArcadeLevels.rise + 20 && runSpeed * timeToRise > ArcadeLevels.reach + 20, "the climber can make every jump the level allows")

        // Every level can be finished, whatever the desktop looks like.
        var finishable = true, doorsOnTop = true, tall = true, inside = true, sane = true, startsOnFloor = true
        for seed in 1...300 {
            let windows = desktop(UInt64(seed), count: seed % 13)
            let level = ArcadeLevels.climb(windows: windows, frame: frame, floorY: floorY, seed: UInt64(seed) &* 31)
            if ArcadeLevels.reachable(level.ledges).count != level.ledges.count { finishable = false }
            let top = level.ledges.map { $0.y }.max() ?? 0
            if level.door.y != top { doorsOnTop = false }
            if top < floorY + (frame.maxY - 190 - floorY) * 0.55 { tall = false }
            if level.ledges.contains(where: { $0.minX < frame.minX - 1 || $0.maxX > frame.maxX + 1 || $0.y > frame.maxY - 140 || $0.width < 60 }) { inside = false }
            if level.ledges.count > 110 || level.coins.count > 36 || level.ledges.first?.kind != .floor { sane = false }
            if level.start.y != floorY || abs(level.start.x - level.door.x) < 60 { startsOnFloor = false }
        }
        expect(finishable, "300 desktops: every ledge in every level can be reached from the floor")
        expect(doorsOnTop, "the door is always on the highest ledge")
        expect(tall, "every level is a real climb, even on an empty desktop")
        expect(inside, "every ledge is on the screen and wide enough to stand on")
        expect(sane, "levels stay a sensible size and start with the floor")
        expect(startsOnFloor, "the climber starts on the floor, away from the door")
        let messy = desktop(7, count: 9)
        expect(ArcadeLevels.climb(windows: messy, frame: frame, floorY: floorY, seed: 5) == ArcadeLevels.climb(windows: messy, frame: frame, floorY: floorY, seed: 5),
               "the same desktop and seed give the same level")
        expect(ArcadeLevels.climb(windows: messy, frame: frame, floorY: floorY, seed: 5).ledges.contains { if case .window = $0.kind { return true } else { return false } },
               "real windows are part of the climb")
        let empty = ArcadeLevels.climb(windows: [], frame: frame, floorY: floorY, seed: 3)
        expect(empty.ledges.filter { $0.kind == .folder }.count >= 5, "an empty desktop gets a tower of folders")

        // Bricks.
        var tidy = true, visibleOnly = true, capped = true
        for seed in 1...200 {
            let windows = desktop(UInt64(seed) &+ 900, count: seed % 11)
            let bricks = ArcadeLevels.bricks(windows: windows, frame: frame, floorY: floorY)
            if bricks.count > 150 || bricks.count < 14 { capped = false }
            for (index, brick) in bricks.enumerated() {
                if brick.rect.minY < floorY + (frame.maxY - floorY) * 0.33 || brick.rect.maxY > frame.maxY - 90 || brick.hits < 1 { tidy = false }
                if bricks[(index + 1)...].contains(where: { $0.rect.insetBy(dx: 1, dy: 1).intersects(brick.rect.insetBy(dx: 1, dy: 1)) }) { tidy = false }
                if let owner = windows.first(where: { $0.id == brick.window }) {
                    let centre = CGPoint(x: brick.rect.midX, y: brick.rect.midY)
                    if windows.contains(where: { $0.order < owner.order && $0.rect.contains(centre) }) { visibleOnly = false }
                    if !owner.rect.insetBy(dx: -1, dy: -1).contains(brick.rect) { tidy = false }
                }
            }
        }
        expect(tidy, "200 desktops: bricks never overlap, stay inside their window and clear of the paddle")
        expect(visibleOnly, "only the part of a window you can see becomes bricks")
        expect(capped, "there are always enough bricks for a game and never too many")
        let wall = ArcadeLevels.bricks(windows: [], frame: frame, floorY: floorY)
        expect(wall.count >= 30 && wall.allSatisfy { $0.window == 0 }, "an empty desktop gets a classic wall")
        let titled = ArcadeLevels.bricks(windows: [DeskWindow(id: 9, rect: CGRect(x: 300, y: 500, width: 900, height: 420), order: 0)], frame: frame, floorY: floorY)
        expect(titled.contains { $0.hits == 2 } && titled.contains { $0.hits == 1 }, "a window's title-bar row takes two hits")

        print("")
        print(failures.isEmpty ? "ARCADE CHECK OK: \(checks) checks" : "ARCADE CHECK FAILED: \(failures.count) of \(checks)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
