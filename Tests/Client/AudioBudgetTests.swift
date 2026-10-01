import XCTest

final class AudioBudgetTests: XCTestCase {
    let packet = 960 // 20ms at 48kHz, what the Mac delivers

    func testFirstPacketGetsACushionOfSilence() {
        var b = AudioBudget()
        XCTAssertEqual(b.admit(packet), AudioBudget.cushion)
        XCTAssertEqual(b.admit(packet), 0, "only after running dry")
        XCTAssertEqual(b.queued, AudioBudget.cushion + 2 * packet)
    }

    func testAnUnderrunGetsAFreshCushion() {
        var b = AudioBudget()
        _ = b.admit(packet)
        b.played(AudioBudget.cushion)
        b.played(packet)
        XCTAssertEqual(b.queued, 0)
        XCTAssertEqual(b.admit(packet), AudioBudget.cushion)
    }

    func testDropsRatherThanFallingBehind() {
        var b = AudioBudget()
        var admitted = 0
        for _ in 0..<50 where b.admit(packet) != nil { admitted += 1 } // a burst nobody is playing
        XCTAssertLessThanOrEqual(b.queued, AudioBudget.maxQueued)
        XCTAssertEqual(admitted, (AudioBudget.maxQueued - AudioBudget.cushion) / packet, "about 160ms of packets, then drops")
        b.played(packet)
        XCTAssertNotNil(b.admit(packet), "room again once one has played")
    }

    func testNeverNegative() {
        var b = AudioBudget()
        b.played(10_000)
        XCTAssertEqual(b.queued, 0)
    }
}
