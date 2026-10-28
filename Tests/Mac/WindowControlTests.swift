import CoreGraphics
import XCTest

final class WindowRingTests: XCTestCase {
    func testRaisingAWindowDoesNotReorderTheSwipe() {
        var r = WindowRing()
        r.update([1, 2, 3])
        // Showing 2 brings it to the front of the z-order.
        r.update([2, 1, 3])
        XCTAssertEqual(r.order, [1, 2, 3])
        XCTAssertEqual(r.step(from: 2, by: 1), 3, "a second swipe goes on, not back to 1")
    }

    func testNewWindowsJoinAtTheEndAndClosedOnesLeave() {
        var r = WindowRing()
        r.update([1, 2, 3])
        r.update([4, 3, 1])
        XCTAssertEqual(r.order, [1, 3, 4])
    }

    func testStepsWrapAroundBothWays() {
        var r = WindowRing()
        r.update([1, 2, 3])
        XCTAssertEqual(r.step(from: 3, by: 1), 1)
        XCTAssertEqual(r.step(from: 1, by: -1), 3)
        XCTAssertEqual(r.step(from: 2, by: -4), 1)
        XCTAssertEqual(r.step(from: 2, by: 0), 2)
    }

    func testFromAWindowThatIsGoneStartsAtTheFirst() {
        var r = WindowRing()
        r.update([5, 6])
        XCTAssertEqual(r.step(from: 99, by: 1), 5)
        XCTAssertEqual(r.step(from: nil, by: 1), 5)
        XCTAssertNil(WindowRing().step(from: 1, by: 1))
    }
}

final class WindowFitTests: XCTestCase {
    // A 1512x982 MacBook screen: menu bar 33 tall, Dock 70 at the bottom.
    let visible = CGRect(x: 0, y: 33, width: 1512, height: 879)

    func testAWindowThatFitsGetsExactlyTheSizeAskedFor() {
        let r = WindowFit.place(CGSize(width: 845, height: 600), from: CGRect(x: 100, y: 100, width: 1200, height: 700), in: visible)
        XCTAssertEqual(r.size, CGSize(width: 845, height: 600))
        XCTAssertEqual(r.midX, 700, accuracy: 1, "centred where the window was")
    }

    func testATallPhoneShapeShrinksToTheScreenKeepingItsShape() {
        // An unfolded phone in portrait asks for 845x1201; the Mac is only 879 tall.
        let r = WindowFit.place(CGSize(width: 845, height: 1201), from: CGRect(x: 300, y: 200, width: 800, height: 600), in: visible)
        XCTAssertEqual(r.height, 879)
        XCTAssertEqual(r.width / r.height, 845.0 / 1201.0, accuracy: 0.005)
        XCTAssertTrue(visible.contains(r), "\(r) leaves the visible area")
    }

    func testIsPushedBackOnScreen() {
        let r = WindowFit.place(CGSize(width: 800, height: 600), from: CGRect(x: 1300, y: 800, width: 400, height: 300), in: visible)
        XCTAssertTrue(visible.contains(r), "\(r) leaves the visible area")
        XCTAssertEqual(r.maxX, visible.maxX)
        XCTAssertEqual(r.maxY, visible.maxY)
    }

    func testWorksOnASecondDisplayAboveAndLeftOfTheMainOne() {
        let second = CGRect(x: -1920, y: -1080, width: 1920, height: 1055)
        let r = WindowFit.place(CGSize(width: 900, height: 1200), from: CGRect(x: -1500, y: -900, width: 600, height: 400), in: second)
        XCTAssertTrue(second.contains(r), "\(r) leaves the visible area")
    }
}
