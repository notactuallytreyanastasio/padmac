import XCTest

final class RateMeterTests: XCTestCase {
    func testMeasuresTheLastTwoSeconds() {
        var m = RateMeter()
        // 30 frames a second of 10 KB for three seconds.
        for i in 0..<90 { m.add(bytes: 10_000, at: Double(i) / 30) }
        let r = m.rate(at: 3)
        XCTAssertEqual(r.perSecond, 30, accuracy: 1)
        XCTAssertEqual(r.megabitsPerSecond, 2.4, accuracy: 0.1) // 10 KB x 30/s x 8 bits
    }

    func testFallsToZeroWhenTrafficStops() {
        var m = RateMeter()
        m.add(bytes: 1_000_000, at: 0)
        XCTAssertGreaterThan(m.rate(at: 1).megabitsPerSecond, 0)
        XCTAssertEqual(m.rate(at: 2.5).megabitsPerSecond, 0)
        XCTAssertEqual(RateMeter().rate(at: 0).perSecond, 0)
    }
}
