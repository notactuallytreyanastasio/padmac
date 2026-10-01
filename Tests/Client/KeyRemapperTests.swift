import XCTest

final class KeyRemapperTests: XCTestCase {
    private var r = KeyRemapper()

    /// Feed physical key events, return what the Mac receives as "55↓ 48↓ ...".
    private func press(_ keys: (UInt16, Bool)...) -> String {
        keys.flatMap { r.handle($0.0, down: $0.1) }.map { "\($0.code)\($0.down ? "↓" : "↑")" }.joined(separator: " ")
    }

    func testOptionTabIsTheMacAppSwitcherHeldUntilOptionIsReleased() {
        // ⌥ down, Tab, Tab, ⌥ up: one ⌘ hold with two Tabs inside it.
        XCTAssertEqual(press((58, true), (48, true), (48, false), (48, true), (48, false), (58, false)),
                       "58↓ 58↑ 55↓ 48↓ 48↑ 48↓ 48↑ 55↑")
    }

    func testShiftTabGoesBackInTheSwitcher() {
        XCTAssertEqual(press((58, true), (48, true), (48, false), (56, true), (48, true), (48, false), (56, false), (58, false)),
                       "58↓ 58↑ 55↓ 48↓ 48↑ 56↓ 48↓ 48↑ 56↑ 55↑")
    }

    func testRightOptionWorksToo() {
        XCTAssertEqual(press((61, true), (48, true), (48, false), (61, false)), "61↓ 61↑ 55↓ 48↓ 48↑ 55↑")
    }

    func testHeldTabRepeatsCycleTheSwitcher() {
        // The iPad repeats a held key by resending key-down.
        XCTAssertEqual(press((58, true), (48, true), (48, true), (48, true), (48, false), (58, false)),
                       "58↓ 58↑ 55↓ 48↓ 48↓ 48↓ 48↑ 55↑")
    }

    func testOptionBacktickIsNextWindow() {
        XCTAssertEqual(press((58, true), (50, true), (50, false), (58, false)), "58↓ 58↑ 55↓ 50↓ 50↑ 55↑")
    }

    func testOptionSpaceIsSpotlightOnceEvenWhenHeld() {
        XCTAssertEqual(press((58, true), (49, true)), "58↓ 58↑ 55↓ 49↓ 49↑ 55↑ 58↓")
        XCTAssertEqual(press((49, true), (49, true)), "", "repeats must not toggle Spotlight closed again")
        XCTAssertEqual(press((49, false), (58, false)), "58↑")
        XCTAssertEqual(press((49, true), (49, false)), "49↓ 49↑", "plain Space afterwards is just Space")
    }

    func testOptionWithOtherKeysIsUntouched() {
        // ⌥E (accent), ⌥← (word left) keep working.
        XCTAssertEqual(press((58, true), (14, true), (14, false), (123, true), (123, false), (58, false)),
                       "58↓ 14↓ 14↑ 123↓ 123↑ 58↑")
    }

    func testTabAndSpaceWithoutOptionAreUntouched() {
        XCTAssertEqual(press((48, true), (48, false), (49, true), (49, false)), "48↓ 48↑ 49↓ 49↑")
        // Real ⌘ (when iPadOS does let it through, e.g. ⌘C) is not involved at all.
        XCTAssertEqual(press((55, true), (8, true), (8, false), (55, false)), "55↓ 8↓ 8↑ 55↑")
    }

    func testOtherKeysWhileSwitchingPassThrough() {
        // In the switcher, Q quits the selected app: ⌘ must still be held.
        XCTAssertEqual(press((58, true), (48, true), (48, false), (12, true), (12, false), (58, false)),
                       "58↓ 58↑ 55↓ 48↓ 48↑ 12↓ 12↑ 55↑")
    }

    func testResetForgetsEverything() {
        _ = press((58, true), (48, true))
        r.reset()
        XCTAssertFalse(r.switching)
        XCTAssertNil(r.optionHeld)
        XCTAssertEqual(press((48, true)), "48↓")
    }
}
