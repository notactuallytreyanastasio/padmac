import CoreGraphics
import Foundation

/// Turns a three-finger drag into trackpad-style swipe events.
///
/// The swipe locks to the axis it starts moving along, the way a Mac trackpad
/// does: drifting sideways during a Mission Control swipe doesn't also change
/// desktops. Distances are total travel as a fraction of the view, so a
/// full-width swipe moves one desktop whatever the iPad's size.
struct SwipeTracker {
    /// Finger travel before the gesture commits to an axis, in points.
    static let lockDistance: CGFloat = 10

    private(set) var axis: SwipeAxis?
    private var last: Double = 0

    mutating func update(translation t: CGPoint, in size: CGSize) -> InputEvent? {
        guard let axis else {
            guard hypot(t.x, t.y) >= Self.lockDistance else { return nil }
            let a: SwipeAxis = abs(t.x) >= abs(t.y) ? .horizontal : .vertical
            self.axis = a
            last = Self.distance(t, size, a)
            return .swipe(axis: a, phase: .began, distance: last)
        }
        let d = Self.distance(t, size, axis)
        guard d != last else { return nil }
        last = d
        return .swipe(axis: axis, phase: .changed, distance: d)
    }

    /// Ends the swipe. Nothing is sent if the fingers never moved far enough to start one.
    mutating func end(translation t: CGPoint, in size: CGSize, cancelled: Bool = false) -> [InputEvent] {
        defer { self = SwipeTracker() }
        guard let axis else { return [] }
        let d = Self.distance(t, size, axis)
        var out: [InputEvent] = []
        if d != last { out.append(.swipe(axis: axis, phase: .changed, distance: d)) }
        out.append(.swipe(axis: axis, phase: cancelled ? .cancelled : .ended, distance: d))
        return out
    }

    private static func distance(_ t: CGPoint, _ size: CGSize, _ axis: SwipeAxis) -> Double {
        switch axis {
        case .horizontal: size.width > 0 ? Double(t.x / size.width) : 0
        case .vertical: size.height > 0 ? Double(t.y / size.height) : 0
        }
    }
}

extension SwipeTracker {
    /// Window mode: which way a finished sideways swipe moves. Fingers left is
    /// the next window, as with desktops. A quarter of the screen commits, or
    /// a flick of more than one screen-width a second the way it is moving.
    static func windowStep(distance: Double, velocity: Double) -> Int {
        if distance <= -0.25 || (distance < -0.05 && velocity < -1) { return 1 }
        if distance >= 0.25 || (distance > 0.05 && velocity > 1) { return -1 }
        return 0
    }
}
