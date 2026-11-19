import Foundation

/// Standalone physics checks: run tools/check-motion.command from any directory.
@main
struct MotionChecks {
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }

    private static func close(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        expect(abs(actual - expected) < 0.000_001, "\(message): \(actual) != \(expected)")
    }

    private static func fixedTargets() {
        let distances: [CGFloat] = [-1000, -160, -25, -1, -0.01, 0.01, 1, 25, 160, 1000]
        let speeds: [CGFloat] = [48, 180, 390]
        let accelerations: [CGFloat] = [160, 600, 1500]
        for fps in [30, 60, 120] {
            let dt = 1 / CGFloat(fps)
            for target in distances {
                for speed in speeds {
                    for acceleration in accelerations {
                        var motion = WalkingMotion()
                        var position: CGFloat = 0
                        let direction: CGFloat = target > 0 ? 1 : -1
                        let context = "target=\(target), speed=\(speed), acceleration=\(acceleration), fps=\(fps)"
                        for _ in 0..<(fps * 60) {
                            let remaining = target - position
                            let step = motion.advance(distance: remaining, speed: speed,
                                                      acceleration: acceleration, braking: 900, dt: dt)
                            expect(step.isFinite && motion.velocity.isFinite, "Non-finite motion: \(context)")
                            expect(step * direction >= 0, "Moved away from fixed target: \(context)")
                            expect(step * direction <= abs(remaining) + 0.000_001,
                                   "Overshot fixed target: \(context)")
                            expect(abs(motion.velocity) <= speed + 0.000_001, "Exceeded speed: \(context)")
                            position += step
                            if step == remaining { position = target; break }
                        }
                        close(position, target, "Did not reach target within 60 seconds: \(context)")
                        close(motion.velocity, 0, "Did not settle at target: \(context)")
                    }
                }
            }
        }
    }

    private static func accelerationAndReset() {
        for direction: CGFloat in [-1, 1] {
            for fps in [30, 60, 120] {
                let dt = 1 / CGFloat(fps)
                var motion = WalkingMotion()
                var previous: CGFloat = 0
                for frame in 1...fps {
                    let step = motion.advance(distance: direction * 10_000, speed: 300,
                                              acceleration: 120, braking: 500, dt: dt)
                    let expected = direction * 120 * CGFloat(frame) * dt
                    close(motion.velocity, expected, "Acceleration should depend on elapsed time")
                    close(step, (previous + expected) * 0.5 * dt, "Displacement should integrate velocity")
                    previous = expected
                }
                motion.reset()
                close(motion.velocity, 0, "Reset should remove momentum")
            }
        }
    }

    private static func braking() {
        for fps in [30, 60, 120] {
            let dt = 1 / CGFloat(fps)
            var motion = WalkingMotion()
            var position: CGFloat = 0
            var peak: CGFloat = 0
            var slowedBeforeArrival = false
            for _ in 0..<(fps * 10) {
                let remaining = 320 - position
                let step = motion.advance(distance: remaining, speed: 160,
                                          acceleration: 500, braking: 450, dt: dt)
                position += step
                peak = max(peak, motion.velocity)
                if position < 320 && position > 295 && motion.velocity < peak * 0.7 {
                    slowedBeforeArrival = true
                }
                if step == remaining { position = 320; break }
            }
            close(peak, 160, "Long walk should reach cruising speed")
            expect(slowedBeforeArrival, "Must slow before arriving, not abruptly stop at \(fps) fps")
            close(position, 320, "Braking should still reach the target")
        }
    }

    private static func targetReversal() {
        for fps in [30, 60, 120] {
            let dt = 1 / CGFloat(fps)
            var motion = WalkingMotion()
            var position: CGFloat = 0
            for _ in 0..<fps {
                position += motion.advance(distance: 1000 - position, speed: 180,
                                           acceleration: 600, braking: 900, dt: dt)
            }
            let initialVelocity = motion.velocity
            let firstStep = motion.advance(distance: -60 - position, speed: 180,
                                           acceleration: 600, braking: 900, dt: dt)
            expect(firstStep > 0, "Reversal should absorb existing forward momentum")
            close(motion.velocity, initialVelocity - 900 * dt, "Reversal should brake at the specified rate")
            position += firstStep
            var turned = false
            for _ in 0..<(fps * 10) {
                let remaining = -60 - position
                let step = motion.advance(distance: remaining, speed: 180,
                                          acceleration: 600, braking: 900, dt: dt)
                if motion.velocity < 0 { turned = true }
                expect(step >= remaining - 0.000_001, "Reversal overshot its new target")
                position += step
                if step == remaining { position = -60; break }
            }
            expect(turned, "Should turn toward the new target")
            close(position, -60, "Should reach the reversed target")
            close(motion.velocity, 0, "Should settle after reversal")
        }
    }

    private static func unbrakedBurst() {
        for direction: CGFloat in [-1, 1] {
            for fps in [30, 60, 120] {
                let dt = 1 / CGFloat(fps)
                let target = direction * 120
                var motion = WalkingMotion()
                var position: CGFloat = 0
                for _ in 0..<(fps * 10) {
                    let remaining = target - position
                    let step = motion.advance(distance: remaining, speed: 200,
                                              acceleration: 600, braking: 800, dt: dt,
                                              brakeAtTarget: false)
                    expect(step * direction <= abs(remaining) + 0.000_001,
                           "Unbraked burst should not overshoot")
                    position += step
                    if step == remaining { position = target; break }
                }
                close(position, target, "Unbraked burst should arrive exactly")
                close(motion.velocity, direction * 200, "Burst should preserve momentum for its skid")
                let finalCorrection = direction * CGFloat(0.0005)
                let correction = motion.advance(distance: finalCorrection, speed: 200,
                                                acceleration: 600, braking: 800, dt: dt,
                                                brakeAtTarget: false)
                close(correction, finalCorrection, "Tiny final correction should arrive exactly")
                close(motion.velocity, direction * 200, "Tiny correction should preserve burst momentum")
            }
        }
    }

    static func main() {
        fixedTargets()
        accelerationAndReset()
        braking()
        targetReversal()
        unbrakedBurst()
        print("Motion checks passed (\(checks) assertions; 30, 60 and 120 fps).")
    }
}
