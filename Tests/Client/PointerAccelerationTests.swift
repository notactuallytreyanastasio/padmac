import CoreGraphics
import XCTest

final class PointerAccelerationTests: XCTestCase {
    // A 5120-wide Mac display across a 13" iPad in landscape: 1376 iPad points.
    let scale = 1376.0 / 5120.0

    /// Moves `distance` points along x at a constant `speed`, sampled at `hz`.
    private func drag(_ distance: Double, speed: Double, hz: Double = 120, zoom: Double = 1) -> Double {
        var a = PointerAcceleration()
        let steps = max(1, Int(distance / speed * hz))
        let step = distance / Double(steps)
        var total = 0.0, t = 0.0
        for _ in 0..<steps {
            t += 1 / hz
            total += Double(a.macDelta(CGPoint(x: step, y: 0), at: t, onScreenScale: scale * zoom).x)
        }
        return total
    }

    func testCurveRunsFromFineToFastWithNoSteps() {
        XCTAssertEqual(PointerAcceleration.gain(speed: 0), PointerAcceleration.slowGain)
        XCTAssertEqual(PointerAcceleration.gain(speed: 1e6), PointerAcceleration.fastGain)
        var previous = PointerAcceleration.gain(speed: 0)
        for v in stride(from: 1.0, through: 3000, by: 1) {
            let g = PointerAcceleration.gain(speed: v)
            XCTAssertGreaterThanOrEqual(g, previous, "never slows down as you speed up")
            XCTAssertLessThan(g - previous, 0.003, "no jump at \(v) pt/s")
            previous = g
        }
    }

    func testSlowMovementIsPrecise() {
        // 300pt at 150pt/s: the cursor moves less than the finger, as seen on screen.
        let mac = drag(300, speed: 150)
        let onScreen = mac * scale
        XCTAssertEqual(onScreen, 300 * PointerAcceleration.slowGain, accuracy: 300 * 0.08)
        // Each 120Hz sample at that speed moves the Mac cursor about 2 points: fine enough for small targets.
        var a = PointerAcceleration()
        _ = a.macDelta(CGPoint(x: 1.25, y: 0), at: 0, onScreenScale: scale)
        XCTAssertLessThan(Double(a.macDelta(CGPoint(x: 1.25, y: 0), at: 1.0 / 120, onScreenScale: scale).x), 3.5)
    }

    func testAQuickFlickCrossesMostOfAnUltrawide() {
        let mac = drag(400, speed: 2500)
        XCTAssertGreaterThan(mac, 5120 * 0.8, "a 400pt flick should cover most of 5120pt")
    }

    func testSameFeelAt60And120Hz() {
        for speed in [100.0, 600, 1500] {
            let a = drag(400, speed: speed, hz: 60), b = drag(400, speed: speed, hz: 120)
            XCTAssertEqual(a, b, accuracy: b * 0.05, "at \(speed) pt/s")
        }
    }

    func testZoomKeepsTheOnScreenFeel() {
        // At 2x zoom the Mac moves half as far, so the cursor travels the same distance on the iPad.
        XCTAssertEqual(drag(300, speed: 400, zoom: 2), drag(300, speed: 400) / 2, accuracy: 1)
    }

    func testANewTouchStartsSlow() {
        var a = PointerAcceleration()
        for i in 1...30 { _ = a.macDelta(CGPoint(x: 20, y: 0), at: Double(i) / 120, onScreenScale: scale) }
        XCTAssertGreaterThan(a.speed, 2000)
        a.reset()
        let first = a.macDelta(CGPoint(x: 10, y: 0), at: 5, onScreenScale: scale)
        XCTAssertEqual(Double(first.x) * scale, 10 * PointerAcceleration.slowGain, accuracy: 0.01,
                       "the pan's first report (its ~10pt start threshold) must not be thrown")
    }

    func testDirectionIsPreserved() {
        var a = PointerAcceleration()
        let d = a.macDelta(CGPoint(x: -3, y: 4), at: 0, onScreenScale: scale)
        XCTAssertEqual(Double(d.y / d.x), -4.0 / 3, accuracy: 1e-9)
    }
}

final class ScrollMomentumTests: XCTestCase {
    private func coast(_ v: CGVector, hz: Double) -> (distance: CGVector, frames: Int) {
        guard var m = ScrollMomentum(velocity: v) else { return (.zero, 0) }
        var total = CGVector.zero, frames = 0
        while true {
            let (d, done) = m.step(1 / hz)
            total.dx += d.dx; total.dy += d.dy; frames += 1
            if done || frames > 10_000 { break }
        }
        return (total, frames)
    }

    func testSlowLiftsDoNotCoast() {
        XCTAssertNil(ScrollMomentum(velocity: CGVector(dx: 0, dy: 100)))
        XCTAssertNotNil(ScrollMomentum(velocity: CGVector(dx: 0, dy: -400)))
    }

    func testCoastsAboutHalfTheLiftSpeedAndStops() {
        let (d, frames) = coast(CGVector(dx: 0, dy: 2000), hz: 120)
        XCTAssertEqual(Double(d.dy), ScrollMomentum.coastDistance(speed: 2000), accuracy: 2000 * 0.02)
        XCTAssertEqual(Double(d.dy), 1000, accuracy: 30)
        XCTAssertLessThan(Double(frames) / 120, 3, "settles within a few seconds")
        XCTAssertEqual(d.dx, 0)
    }

    func testFrameRateDoesNotChangeTheDistance() {
        let a = coast(CGVector(dx: 1500, dy: -900), hz: 60).distance
        let b = coast(CGVector(dx: 1500, dy: -900), hz: 120).distance
        XCTAssertEqual(Double(a.dx), Double(b.dx), accuracy: abs(Double(b.dx)) * 0.01)
        XCTAssertEqual(Double(a.dy), Double(b.dy), accuracy: abs(Double(b.dy)) * 0.01)
    }

    func testEachFrameIsSmallerThanTheLast() {
        var m = ScrollMomentum(velocity: CGVector(dx: 0, dy: 1000))!
        var last = Double.infinity
        for _ in 0..<50 {
            let d = Double(m.step(1 / 120.0).delta.dy)
            XCTAssertLessThan(d, last)
            last = d
        }
    }
}
