import CoreGraphics
import XCTest

final class SwipeTrackerTests: XCTestCase {
    let size = CGSize(width: 1000, height: 800)

    func testNothingUntilTheFingersHaveMovedFarEnough() {
        var t = SwipeTracker()
        XCTAssertNil(t.update(translation: CGPoint(x: 5, y: 3), in: size))
        XCTAssertEqual(t.end(translation: CGPoint(x: 5, y: 3), in: size), [], "a three-finger tap isn't a swipe")
    }

    func testLocksToTheAxisItStartedOn() {
        var t = SwipeTracker()
        XCTAssertEqual(t.update(translation: CGPoint(x: -12, y: 4), in: size), .swipe(axis: .horizontal, phase: .began, distance: -0.012))
        // Drifting mostly vertical afterwards still drives the horizontal swipe.
        XCTAssertEqual(t.update(translation: CGPoint(x: -100, y: 300), in: size), .swipe(axis: .horizontal, phase: .changed, distance: -0.1))
        XCTAssertEqual(t.end(translation: CGPoint(x: -500, y: 300), in: size),
                       [.swipe(axis: .horizontal, phase: .changed, distance: -0.5), .swipe(axis: .horizontal, phase: .ended, distance: -0.5)])
    }

    func testVerticalUsesTheHeight() {
        var t = SwipeTracker()
        XCTAssertEqual(t.update(translation: CGPoint(x: 2, y: -40), in: size), .swipe(axis: .vertical, phase: .began, distance: -0.05))
    }

    func testNoDuplicateChanges() {
        var t = SwipeTracker()
        _ = t.update(translation: CGPoint(x: 20, y: 0), in: size)
        XCTAssertNil(t.update(translation: CGPoint(x: 20, y: 7), in: size), "no movement along the locked axis")
        XCTAssertEqual(t.end(translation: CGPoint(x: 20, y: 7), in: size), [.swipe(axis: .horizontal, phase: .ended, distance: 0.02)])
    }

    func testCancelAndReuse() {
        var t = SwipeTracker()
        _ = t.update(translation: CGPoint(x: 50, y: 0), in: size)
        XCTAssertEqual(t.end(translation: CGPoint(x: 50, y: 0), in: size, cancelled: true).last,
                       .swipe(axis: .horizontal, phase: .cancelled, distance: 0.05))
        XCTAssertNil(t.axis, "reset for the next gesture")
        XCTAssertEqual(t.update(translation: CGPoint(x: 0, y: 50), in: size), .swipe(axis: .vertical, phase: .began, distance: 0.0625))
    }
}
