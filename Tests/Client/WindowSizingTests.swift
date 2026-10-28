import CoreGraphics
import XCTest

final class WindowSizingTests: XCTestCase {
    func testAPhoneInPortraitGetsAWindowMacAppsCanLayOutIn() {
        // A 6.1" iPhone's safe area in portrait.
        let r = WindowSizing.request(for: CGSize(width: 393, height: 759))!
        XCTAssertEqual(r.width, 840, accuracy: 1)
        XCTAssertEqual(r.width / r.height, 393 / 759, accuracy: 0.01, "the window has the phone's shape")
    }

    func testLandscapeNeedsHeightNotWidth() {
        let r = WindowSizing.request(for: CGSize(width: 800, height: 360))!
        XCTAssertEqual(r.height, 600, accuracy: 1)
        XCTAssertGreaterThan(r.width, 840)
    }

    func testABigScreenIsNeverMagnified() {
        // An iPad in window mode already has more room than the target.
        let r = WindowSizing.request(for: CGSize(width: 1024, height: 1300))!
        XCTAssertEqual(r, WindowRequest(width: 1024, height: 1300))
    }

    func testUnfoldingMakesTheTextBigger() {
        let folded = WindowSizing.macPointsPerPoint(for: CGSize(width: 440, height: 660))
        let open = WindowSizing.macPointsPerPoint(for: CGSize(width: 620, height: 860))
        XCTAssertLessThan(open, folded, "fewer Mac points per point: the Mac window shows larger")
        XCTAssertEqual(open, 840 / 620, accuracy: 0.001)
    }

    func testTextScaleTradesSpaceForSize() {
        let space = CGSize(width: 440, height: 660)
        let larger = WindowSizing.request(for: space, textScale: 1.25)!, normal = WindowSizing.request(for: space)!
        XCTAssertLessThan(larger.width, normal.width)
        // Capped: a tiny screen can't ask for a Mac window too big to read.
        XCTAssertEqual(WindowSizing.macPointsPerPoint(for: CGSize(width: 200, height: 200)), WindowSizing.maxMacPointsPerPoint)
    }

    func testNoRequestBeforeLayout() {
        XCTAssertNil(WindowSizing.request(for: .zero))
    }

    func testWindowSwipeCommitsOnDistanceOrFlick() {
        XCTAssertEqual(SwipeTracker.windowStep(distance: -0.3, velocity: 0), 1, "fingers left: next window")
        XCTAssertEqual(SwipeTracker.windowStep(distance: 0.3, velocity: 0), -1)
        XCTAssertEqual(SwipeTracker.windowStep(distance: -0.1, velocity: -2), 1, "a short fast flick")
        XCTAssertEqual(SwipeTracker.windowStep(distance: -0.1, velocity: 0.5), 0, "a short slow drag goes nowhere")
        XCTAssertEqual(SwipeTracker.windowStep(distance: 0.02, velocity: 3), 0, "a twitch is not a swipe")
    }

    func testAFoldAcrossTheScreenGivesTheWindowTheTopHalf() {
        let safe = CGRect(x: 0, y: 30, width: 880, height: 600)
        let fold = CGRect(x: 0, y: 320, width: 880, height: 24)
        XCTAssertEqual(WindowSizing.space(safe: safe, division: fold), CGRect(x: 0, y: 30, width: 880, height: 290))
    }

    func testAnUprightFoldGivesTheWindowTheLeadingHalf() {
        let safe = CGRect(x: 0, y: 0, width: 620, height: 860)
        let fold = CGRect(x: 298, y: 0, width: 24, height: 860)
        XCTAssertEqual(WindowSizing.space(safe: safe, division: fold), CGRect(x: 0, y: 0, width: 298, height: 860))
    }

    func testNoFoldIsTheWholeSafeArea() {
        let safe = CGRect(x: 0, y: 30, width: 880, height: 600)
        XCTAssertEqual(WindowSizing.space(safe: safe, division: nil), safe)
        XCTAssertEqual(WindowSizing.space(safe: safe, division: CGRect(x: 0, y: 900, width: 880, height: 20)), safe, "a fold outside the app's space")
    }

    func testTheKeyboardPushesTheWindowUpFromTheBottom() {
        let safe = CGRect(x: 0, y: 59, width: 620, height: 800)
        XCTAssertEqual(WindowSizing.space(safe: safe, division: nil, bottom: 540), CGRect(x: 0, y: 59, width: 620, height: 481))
        XCTAssertEqual(WindowSizing.space(safe: safe, division: nil, bottom: 900), safe, "a keyboard below the safe area changes nothing")
        // Above the keyboard is a wide, short space: the Mac window becomes wide and short too.
        let r = WindowSizing.request(for: WindowSizing.space(safe: safe, division: nil, bottom: 540).size)!
        XCTAssertGreaterThan(r.width, r.height)
    }
}
