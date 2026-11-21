import AppKit

/// A surface a character can stand on: the top edge of a window, or the floor (id 0).
struct Platform {
    let id: Int
    let minX: CGFloat
    let maxX: CGFloat
    let y: CGFloat
    let order: Int   // front-to-back position in the window list
}

final class World {
    private(set) var frame = CGRect.zero
    private(set) var floorY: CGFloat = 0
    private var platforms: [Platform] = []
    private var rects: [CGRect] = []
    private let myPID = Int(ProcessInfo.processInfo.processIdentifier)
    /// Window numbers of this app's own workspace windows, which characters may stand on.
    var ownWindows: Set<Int> = []

    func refresh(screenFrame: CGRect, visibleFrame: CGRect) {
        frame = screenFrame
        floorY = visibleFrame.minY
        let primaryHeight = screenFrame.height

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }

        var newRects: [CGRect] = []
        var newPlatforms: [Platform] = []
        newRects.reserveCapacity(min(list.count, 40))
        newPlatforms.reserveCapacity(min(list.count, 40))
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let number = info[kCGWindowNumber as String] as? Int,
                  pid != myPID || ownWindows.contains(number),
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.1 { continue }
            if r.width < 160 || r.height < 60 { continue }
            // Window list uses a top-left origin; AppKit uses bottom-left.
            let rect = CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
            if !rect.intersects(frame) { continue }
            let order = newRects.count
            newRects.append(rect)
            let minX = max(rect.minX, frame.minX)
            let maxX = min(rect.maxX, frame.maxX)
            if maxX - minX > 80 && rect.maxY > floorY + 40 {
                newPlatforms.append(Platform(id: number, minX: minX, maxX: maxX, y: rect.maxY, order: order))
            }
        }
        rects = newRects
        platforms = newPlatforms
    }

    /// True when a window in front hides this spot on the edge or blocks the standing space above it.
    private func covered(x: CGFloat, y: CGFloat, clearance: CGFloat, order: Int) -> Bool {
        let low = y + 2
        let high = y + max(12, clearance * 0.65)
        var i = 0
        while i < order && i < rects.count {
            let r = rects[i]
            if x >= r.minX && x <= r.maxX && r.minY < high && r.maxY > low {
                return true
            }
            i += 1
        }
        return false
    }

    private func usable(_ p: Platform, x: CGFloat, clearance: CGFloat) -> Bool {
        if x < p.minX - 2 || x > p.maxX + 2 { return false }
        if p.y + clearance > frame.maxY { return false }
        return !covered(x: x, y: p.y, clearance: clearance, order: p.order)
    }

    /// Height of the surface with this id at x, or nil if it is gone.
    func surfaceY(id: Int, x: CGFloat, clearance: CGFloat) -> CGFloat? {
        if id == 0 { return floorY }
        guard let p = platforms.first(where: { $0.id == id }) else { return nil }
        return usable(p, x: x, clearance: clearance) ? p.y : nil
    }

    /// The highest surface at x that is at or below the given height.
    func ground(x: CGFloat, below y: CGFloat, clearance: CGFloat) -> (id: Int, y: CGFloat) {
        var best: (id: Int, y: CGFloat) = (0, floorY)
        for p in platforms where p.y <= y && p.y > best.y && usable(p, x: x, clearance: clearance) {
            best = (p.id, p.y)
        }
        return best
    }

    /// A place to stand on a particular surface, as close to x as it allows.
    func spot(on id: Int, near x: CGFloat, clearance: CGFloat) -> CGPoint? {
        guard let p = platforms.first(where: { $0.id == id }), p.maxX - p.minX > 120 else { return nil }
        let tries = [min(max(x, p.minX + 60), p.maxX - 60), (p.minX + p.maxX) / 2, p.minX + 70, p.maxX - 70]
        for candidate in tries where usable(p, x: candidate, clearance: clearance) {
            return CGPoint(x: candidate, y: p.y)
        }
        return nil
    }

    func range(id: Int) -> ClosedRange<CGFloat> {
        if id != 0, let p = platforms.first(where: { $0.id == id }), p.maxX > p.minX {
            return p.minX...p.maxX
        }
        return frame.minX...max(frame.maxX, frame.minX + 1)
    }

    /// A reachable spot on some other surface.
    func jumpTarget(from pos: CGPoint, excluding current: Int, clearance: CGFloat) -> (id: Int, point: CGPoint)? {
        var options: [(id: Int, point: CGPoint)] = []
        for p in platforms where p.id != current {
            if abs(p.y - pos.y) > 460 { continue }
            let lo = max(p.minX + 24, pos.x - 520)
            let hi = min(p.maxX - 24, pos.x + 520)
            if hi <= lo { continue }
            let x = CGFloat.random(in: lo...hi)
            if usable(p, x: x, clearance: clearance) {
                options.append((p.id, CGPoint(x: x, y: p.y)))
            }
        }
        if current != 0 && pos.y - floorY < 460 {
            let lo = max(frame.minX + 60, pos.x - 400)
            let hi = min(frame.maxX - 60, pos.x + 400)
            if hi > lo { options.append((0, CGPoint(x: CGFloat.random(in: lo...hi), y: floorY))) }
        }
        return options.randomElement()
    }
}
