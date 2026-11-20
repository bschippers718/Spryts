import CoreGraphics
import Foundation

// The coach's movement breaks: a few things anyone can do next to a desk with no kit, and how Rally does each
// one himself. Every pose is a pure function of time, so the checks can draw them and count the reps.

struct Exercise: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String       // SF Symbol
    let ask: String          // what the break asks of you, in one line
    let call: String         // what Rally says as it starts
    let reps: Int            // 0 for a timed stretch
    let pace: CGFloat        // seconds per rep
    let seconds: CGFloat     // how long Rally keeps going

    var done: String { reps > 0 ? "That's \(reps). Nice work." : "Better. Back to it." }
}

enum Exercises {
    static let all: [Exercise] = [
        Exercise(id: "stand", name: "Stand Up", symbol: "figure.stand", ask: "Stand, reach up, roll your shoulders. One minute.",
                 call: "Up you get. Reach for the ceiling with me.", reps: 0, pace: 0, seconds: 36),
        Exercise(id: "pushups", name: "Push-ups", symbol: "figure.strengthtraining.functional", ask: "10 push-ups. Knees down is fine.",
                 call: "Ten push-ups. Down with me.", reps: 10, pace: 2.6, seconds: 27),
        Exercise(id: "situps", name: "Sit-ups", symbol: "figure.core.training", ask: "15 sit-ups, slow on the way down.",
                 call: "Fifteen sit-ups. Find the floor.", reps: 15, pace: 2.2, seconds: 34),
        Exercise(id: "squats", name: "Squats", symbol: "figure.cross.training", ask: "15 squats. Heels down, chest up.",
                 call: "Fifteen squats. Sit back into it.", reps: 15, pace: 2.2, seconds: 34),
    ]

    /// "mix" is not an exercise of its own: it takes each of the others in turn.
    static let mix = "mix"

    static func find(_ id: String) -> Exercise? { all.first { $0.id == id } }

    /// How many reps are finished `u` seconds in.
    static func rep(_ exercise: Exercise, at u: CGFloat) -> Int {
        guard exercise.reps > 0, exercise.pace > 0 else { return 0 }
        return min(exercise.reps, max(0, Int((u + 0.01) / exercise.pace)))
    }

    /// 0 at the top of a rep, 1 at the bottom, eased.
    private static func cycle(_ u: CGFloat, _ pace: CGFloat) -> CGFloat {
        0.5 - 0.5 * cos(2 * CGFloat.pi * u / max(0.1, pace))
    }

    /// Rally doing it. `L` is his leg length; `facing` is 1 or -1.
    static func pose(_ id: String, at u: CGFloat, L: CGFloat, facing: CGFloat) -> Pose {
        var p = Pose()
        p.smile = 0.5
        switch id {
        case "pushups":
            // Seen from the side: a straight line from heels to shoulders, lowered and pressed back up.
            let down = cycle(u, find(id)?.pace ?? 2.6)
            let line = 1.08 + 0.26 * down
            p.yaw = facing * 1.5
            p.lean = line
            p.legL = -(1.08 + 0.2 * down)
            p.legR = p.legL
            p.bodyY = L * cos(1.08 + 0.2 * down) - L + 2
            p.armL = line - 1.0 * down
            p.armR = p.armL
            p.elbowL = 0.05 + 1.9 * down
            p.elbowR = p.elbowL
            p.armOutL = 0.1
            p.armOutR = 0.1
            p.headPitch = -0.6
            p.mouthOpen = 0.25 * down
            p.browAngle = 0.3 * down
        case "situps":
            // Sitting on the floor, knees up, curling from lying back to upright.
            let up = 1 - cycle(u, find(id)?.pace ?? 2.2)
            p.yaw = facing * 1.5
            // Sat on the floor: thighs angled up, shins back down to it.
            p.bodyY = -L * 0.72
            p.legL = 2.0
            p.legR = 2.0
            p.kneeL = 1.9
            p.kneeR = 1.9
            p.lean = -1.3 + 1.25 * up
            p.armL = 2.5
            p.armR = 2.5
            p.elbowL = 2.2
            p.elbowR = 2.2
            p.headPitch = 0.25
            p.mouthOpen = 0.2 * up
        case "squats":
            let down = cycle(u, find(id)?.pace ?? 2.2)
            p.yaw = facing * 0.6
            p.legL = 0.95 * down
            p.legR = 0.95 * down
            p.kneeL = 1.7 * down
            p.kneeR = 1.7 * down
            // Hips drop by exactly what the bent legs give up, so the feet stay planted.
            p.bodyY = L / 2 * (cos(0.95 * down) + cos(0.75 * down)) - L
            p.lean = 0.35 * down
            p.armL = 1.4 * down
            p.armR = 1.4 * down
            p.elbowL = 0.1
            p.elbowR = 0.1
            p.mouthOpen = 0.2 * down
        default:
            // Stand up: a long reach, side bends, then loose shoulders and an easy march.
            p.yaw = 0
            if u < 12 {
                let e = min(1, u / 1.5)
                p.armOutL = 0.12 + 2.75 * e
                p.armOutR = 0.12 + 2.75 * e
                p.elbowL = 0.1
                p.elbowR = 0.1
                p.bodyY = 3 * e + 1.5 * sin(u * 1.6)
                p.lean = -0.08 * e
                p.headPitch = -0.28 * e
            } else if u < 24 {
                let side = sin((u - 12) * 1.05)
                p.tilt = 0.24 * side
                p.armOutR = side > 0 ? 2.8 : 0.4
                p.armOutL = side < 0 ? 2.8 : 0.4
                p.elbowL = 0.15
                p.elbowR = 0.15
                p.headTilt = 0.12 * side
            } else {
                let s = sin((u - 24) * 4)
                p.armL = 0.7 * s
                p.armR = -0.7 * s
                p.armOutL = 0.45
                p.armOutR = 0.45
                p.elbowL = 0.6
                p.elbowR = 0.6
                p.legL = 0.5 * max(0, s)
                p.legR = 0.5 * max(0, -s)
                p.kneeL = 0.9 * max(0, s)
                p.kneeR = 0.9 * max(0, -s)
                p.bodyY = 1.5 * abs(s)
            }
            p.smile = 0.8
        }
        return p
    }
}
