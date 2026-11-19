import Foundation

/// Ground movement with a real stopping distance. The same displacement drives the foot cycle.
struct WalkingMotion {
    private(set) var velocity: CGFloat = 0

    mutating func reset() { velocity = 0 }

    mutating func advance(distance: CGFloat, speed: CGFloat, acceleration: CGFloat,
                          braking: CGFloat, dt: CGFloat, brakeAtTarget: Bool = true) -> CGFloat {
        guard dt > 0, speed > 0, acceleration > 0, braking > 0 else { return 0 }
        guard abs(distance) > 0.001 else {
            if brakeAtTarget { velocity = 0 }
            return distance
        }
        let direction: CGFloat = distance > 0 ? 1 : -1
        let allowedSpeed = brakeAtTarget ? min(speed, sqrt(2 * braking * abs(distance))) : speed
        let desired = direction * allowedSpeed
        let slowing = velocity * desired < 0 || abs(desired) < abs(velocity)
        let change = (slowing ? braking : acceleration) * dt
        let previous = velocity
        velocity += min(change, max(-change, desired - velocity))
        let step = (previous + velocity) * 0.5 * dt
        // Land exactly on the target; a moving cursor may change direction on the next frame.
        if step * direction >= abs(distance) {
            if brakeAtTarget { velocity = 0 }
            return distance
        }
        return step
    }
}
