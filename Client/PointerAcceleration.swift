import CoreGraphics
import Foundation

/// Mac-style pointer acceleration for using the iPad's screen as a trackpad.
///
/// Gain is defined on screen: how far the cursor moves *as you see it on the
/// iPad* per point of finger travel. Slow movement is finer than your finger
/// (0.6x) so small targets are reachable; fast movement throws the cursor
/// (up to 3.2x). Between the two, the curve is a smoothstep of finger speed:
/// flat at both ends with no corners, so speeding up never makes the cursor
/// jump.
///
/// The speed is measured from the deltas themselves, smoothed over about 30ms.
/// The previous version used UIPanGestureRecognizer.velocity, which lags behind
/// the finger and then catches up, and that catch-up is what made the cursor snap.
struct PointerAcceleration {
    static let slowGain = 0.6
    static let fastGain = 3.2
    /// Finger speeds (iPad points per second) where the curve starts and stops rising.
    static let slowSpeed = 60.0
    static let fastSpeed = 2000.0
    static let smoothing: TimeInterval = 0.03

    private(set) var speed = 0.0
    private var lastTime: TimeInterval?

    static func gain(speed: Double) -> Double {
        let t = min(max((speed - slowSpeed) / (fastSpeed - slowSpeed), 0), 1)
        return slowGain + (fastGain - slowGain) * t * t * (3 - 2 * t)
    }

    /// Mac points to move for a finger movement `d` (iPad points) at `time`.
    /// `onScreenScale` is iPad points per Mac point as currently displayed
    /// (it includes the zoom), so the gain holds on screen at any zoom.
    mutating func macDelta(_ d: CGPoint, at time: TimeInterval, onScreenScale: Double) -> CGPoint {
        if let last = lastTime, time > last {
            let dt = time - last
            let instant = Double(hypot(d.x, d.y)) / dt
            speed += (instant - speed) * min(1, dt / Self.smoothing)
        }
        lastTime = time
        let g = Self.gain(speed: speed) / max(onScreenScale, 1e-6)
        return CGPoint(x: Double(d.x) * g, y: Double(d.y) * g)
    }

    /// A new touch: the first movement is treated as slow.
    mutating func reset() {
        speed = 0
        lastTime = nil
    }
}

/// Scrolling that keeps going after the fingers lift, decelerating like a Mac
/// trackpad (the Mac generates momentum in the trackpad driver, not in apps,
/// so a synthesized scroll has none unless we make it).
struct ScrollMomentum {
    /// Fraction of velocity left after one second: UIScrollView's normal rate (0.998 per ms).
    static let decayPerSecond = 0.135
    /// Below this lift-off speed (Mac points per second) the scroll just stops.
    static let minimumStartSpeed = 150.0
    static let stopSpeed = 12.0

    private(set) var velocity: CGVector

    init?(velocity v: CGVector) {
        guard hypot(v.dx, v.dy) >= Self.minimumStartSpeed else { return nil }
        velocity = v
    }

    /// Distance to scroll during the next `dt` seconds, and whether that's the last of it.
    /// Integrates the decay exactly, so the total doesn't depend on the frame rate.
    mutating func step(_ dt: TimeInterval) -> (delta: CGVector, done: Bool) {
        let k = pow(Self.decayPerSecond, dt)
        let f = (k - 1) / log(Self.decayPerSecond)
        let d = CGVector(dx: velocity.dx * f, dy: velocity.dy * f)
        velocity = CGVector(dx: velocity.dx * k, dy: velocity.dy * k)
        return (d, hypot(velocity.dx, velocity.dy) < Self.stopSpeed)
    }

    /// How far a lift at `speed` coasts in total: speed / ln(1 / decay) ≈ speed / 2.
    static func coastDistance(speed: Double) -> Double { speed / -log(decayPerSecond) }
}
