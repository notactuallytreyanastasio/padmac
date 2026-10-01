import AppKit
import CoreGraphics
import XCTest

/// Input logic with events captured instead of posted: nothing touches the real cursor.
final class InputInjectorTests: XCTestCase {
    private var events: [CGEvent] = []
    private var gestures: [CGEvent] = []
    private var pending: [(TimeInterval, () -> Void)] = []
    private var spaceCount: Int? = 5
    private var clock: TimeInterval = 1000
    private var realCursor = CGPoint(x: 100, y: 100)
    private var injector: InputInjector!

    override func setUp() {
        events = []
        gestures = []
        pending = []
        let system = InputInjector.System(
            post: { [unowned self] in self.events.append($0) },
            postGesture: { [unowned self] in self.gestures.append($0) },
            after: { [unowned self] delay, f in self.pending.append((delay, f)) },
            spaces: { [unowned self] _ in self.spaceCount },
            bounds: { _ in CGRect(x: 0, y: 0, width: 1000, height: 500) },
            cursor: { [unowned self] in self.realCursor },
            now: { [unowned self] in self.clock },
            doubleClickInterval: 0.5)
        injector = InputInjector(displayID: 1, system: system)
    }

    private func send(_ e: InputEvent...) { e.forEach(injector.handle) }
    private var types: [CGEventType] { events.map(\.type) }
    private func take() -> [CGEvent] { defer { events = [] }; return events }

    func testMoveToMapsNormalisedToDisplayAndClamps() {
        send(.moveTo(x: 0.5, y: 0.5), .moveTo(x: 1.5, y: -1))
        XCTAssertEqual(types, [.mouseMoved, .mouseMoved])
        XCTAssertEqual(events[0].location, CGPoint(x: 500, y: 250))
        XCTAssertEqual(events[1].location, CGPoint(x: 999, y: 0))
    }

    func testRelativeBurstDoesNotLoseDeltasToStaleCursorReads() {
        // The real cursor read lags behind what we posted; a burst must build on our own position.
        for _ in 0..<20 { send(.moveBy(dx: 10, dy: 5)) }
        XCTAssertEqual(events.last?.location, CGPoint(x: 300, y: 200))
    }

    func testRelativeMoveAfterIdleFollowsTheLocalMouse() {
        send(.moveBy(dx: 10, dy: 0))
        clock += 1           // idle long enough for the local mouse to have moved
        realCursor = CGPoint(x: 700, y: 50)
        send(.moveBy(dx: 10, dy: 0))
        XCTAssertEqual(events.last?.location, CGPoint(x: 710, y: 50))
    }

    func testDoubleClickCountsAndResets() {
        send(.button(.left, down: true), .button(.left, down: false))
        clock += 0.1
        send(.button(.left, down: true), .button(.left, down: false))
        clock += 2 // too slow: a new first click
        send(.button(.left, down: true), .button(.left, down: false))
        XCTAssertEqual(types, [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 1, 2, 2, 1, 1])
    }

    func testClicksFarApartAreNotADoubleClick() {
        send(.button(.left, down: true), .button(.left, down: false), .moveTo(x: 0.9, y: 0.9),
             .button(.left, down: true), .button(.left, down: false))
        XCTAssertEqual(events.filter { $0.type == .leftMouseDown }.map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 1])
    }

    func testMovingWithAButtonHeldDrags() {
        send(.button(.left, down: true), .moveBy(dx: 5, dy: 0), .button(.left, down: false), .moveBy(dx: 5, dy: 0))
        XCTAssertEqual(types, [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved])
        send(.button(.right, down: true), .moveBy(dx: 1, dy: 0), .button(.right, down: false))
        XCTAssertEqual(Array(types.suffix(3)), [.rightMouseDown, .rightMouseDragged, .rightMouseUp])
    }

    func testReleasingAButtonThatIsNotHeldPostsNothing() {
        send(.button(.left, down: false), .key(code: 8, down: false))
        XCTAssertTrue(events.isEmpty)
    }

    func testModifierFlagsAreStampedOnKeysAndClicks() {
        send(.key(code: 55, down: true))           // ⌘ down
        send(.key(code: 8, down: true), .key(code: 8, down: false)) // c
        send(.button(.left, down: true))
        send(.key(code: 55, down: false))
        let e = take()
        XCTAssertEqual(e.map(\.type), [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .flagsChanged])
        XCTAssertTrue(e[0].flags.contains(.maskCommand))
        XCTAssertTrue(e[1].flags.contains(.maskCommand), "⌘C must arrive as ⌘C, not c")
        XCTAssertTrue(e[3].flags.contains(.maskCommand), "⌘-click")
        XCTAssertFalse(e[4].flags.contains(.maskCommand))
        XCTAssertEqual(e[1].getIntegerValueField(.keyboardEventKeycode), 8)
    }

    func testLeftAndRightModifiersAreTrackedSeparately() {
        send(.key(code: 56, down: true), .key(code: 60, down: true), .key(code: 56, down: false), .key(code: 0, down: true))
        XCTAssertTrue(events.last!.flags.contains(.maskShift), "right shift is still held")
    }

    func testHeldKeyRepeatsAreMarkedAutorepeat() {
        send(.key(code: 51, down: true), .key(code: 51, down: true), .key(code: 51, down: true), .key(code: 51, down: false))
        XCTAssertEqual(types, [.keyDown, .keyDown, .keyDown, .keyUp])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventAutorepeat) }, [0, 1, 1, 0])
    }

    func testRepeatedModifierDownIsIgnored() {
        send(.key(code: 55, down: true), .key(code: 55, down: true))
        XCTAssertEqual(types, [.flagsChanged])
    }

    func testCapsLockToggles() {
        send(.key(code: 57, down: true), .key(code: 57, down: false), .key(code: 0, down: true))
        XCTAssertTrue(events.last!.flags.contains(.maskAlphaShift))
        send(.key(code: 0, down: false), .key(code: 57, down: true), .key(code: 0, down: true))
        XCTAssertFalse(events.last!.flags.contains(.maskAlphaShift))
    }

    func testReleaseAllLetsGoOfEverything() {
        send(.button(.left, down: true), .key(code: 56, down: true), .key(code: 0, down: true))
        events = []
        send(.releaseAll)
        XCTAssertEqual(Set(types.map(\.rawValue)), Set([CGEventType.leftMouseUp, .flagsChanged, .keyUp].map(\.rawValue)))
        events = []
        send(.releaseAll)
        XCTAssertTrue(events.isEmpty, "nothing left to release")
    }

    private func unicode(_ e: CGEvent) -> String {
        var len = 0
        var buf = [UniChar](repeating: 0, count: 64)
        e.keyboardGetUnicodeString(maxStringLength: 64, actualStringLength: &len, unicodeString: &buf)
        return String(utf16CodeUnits: buf, count: len)
    }

    func testTextIsTypedInChunksOfAtMost20UTF16Units() {
        let text = String(repeating: "abcdefghij", count: 4) + "xyz" // 43 units
        send(.text(text))
        let downs = events.filter { $0.type == .keyDown }
        XCTAssertEqual(downs.map { unicode($0).utf16.count }, [20, 20, 3])
        XCTAssertEqual(downs.map(unicode).joined(), text)
        XCTAssertEqual(events.count, 6, "each chunk is a key down and up")
    }

    func testChunkingNeverSplitsASurrogatePair() {
        let text = String(repeating: "a", count: 19) + "😀b"
        send(.text(text))
        let chunks = events.filter { $0.type == .keyDown }.map(unicode)
        XCTAssertEqual(chunks, [String(repeating: "a", count: 19), "😀b"])
    }

    func testNewlinesBecomeReturn() {
        send(.text("a\nb"))
        let downs = events.filter { $0.type == .keyDown }
        XCTAssertEqual(downs.count, 3)
        XCTAssertEqual(unicode(downs[0]), "a")
        XCTAssertEqual(downs[1].getIntegerValueField(.keyboardEventKeycode), 36)
        XCTAssertEqual(unicode(downs[2]), "b")
    }

    func testTrackpadScrollPhasesAndMomentumReachTheEvent() {
        send(.scroll(dx: 0, dy: 5, phase: .began), .scroll(dx: 0, dy: 10, phase: .changed), .scroll(dx: 0, dy: 0, phase: .ended),
             .scroll(dx: 0, dy: 8, momentum: .began), .scroll(dx: 0, dy: 4, momentum: .changed), .scroll(dx: 0, dy: 0, momentum: .ended))
        XCTAssertEqual(events.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) }, [1, 2, 4, 0, 0, 0])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.scrollWheelEventMomentumPhase) }, [0, 0, 0, 1, 2, 3])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }, [5, 10, 0, 8, 4, 0])
    }

    func testAppKitReadsThemAsTrackpadScrolls() throws {
        // Apps see NSEvents; check AppKit's own conversion of what we post.
        send(.scroll(dx: 0, dy: 12, phase: .began), .scroll(dx: 0, dy: 30, momentum: .changed))
        let scroll = try XCTUnwrap(NSEvent(cgEvent: events[0]))
        XCTAssertEqual(scroll.type, .scrollWheel)
        XCTAssertEqual(scroll.phase, .began)
        XCTAssertEqual(scroll.momentumPhase, [])
        XCTAssertTrue(scroll.hasPreciseScrollingDeltas, "pixel deltas, like a trackpad, not wheel notches")
        XCTAssertEqual(scroll.scrollingDeltaY, 12)
        let coast = try XCTUnwrap(NSEvent(cgEvent: events[1]))
        XCTAssertEqual(coast.momentumPhase, .changed)
        XCTAssertEqual(coast.phase, [])
    }

    func testSubPixelScrollsAddUp() {
        // The slow tail of a momentum scroll: 0.4px a frame used to round to nothing.
        send(.scroll(dx: 0, dy: 0.4, momentum: .began))
        for _ in 0..<9 { send(.scroll(dx: 0, dy: 0.4, momentum: .changed)) }
        let total = events.reduce(0) { $0 + $1.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }
        XCTAssertEqual(total, 4)
        // Negative fractions carry too, and a new scroll starts clean.
        events = []
        send(.scroll(dx: -0.6, dy: 0, phase: .began), .scroll(dx: -0.6, dy: 0, phase: .changed))
        XCTAssertEqual(events.reduce(0) { $0 + $1.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) }, -1)
    }

    func testScrollIsPixelBased() {
        send(.scroll(dx: 3, dy: -40))
        XCTAssertEqual(types, [.scrollWheel])
        XCTAssertEqual(events[0].getIntegerValueField(.scrollWheelEventIsContinuous), 1, "pixel scrolling")
        XCTAssertEqual(events[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -40)
        XCTAssertEqual(events[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 3)
    }

    // MARK: Swipes

    private func field(_ e: CGEvent, _ f: UInt32) -> Double { e.getDoubleValueField(CGEventField(rawValue: f)!) }
    /// The Dock-control events (type 30) among the posted gestures: (phase, offset, swipe type).
    private var dock: [(phase: Int, offset: Double, type: Int)] {
        gestures.filter { field($0, 55) == 30 }.map { (Int(field($0, 132)), field($0, 124), Int(field($0, 123))) }
    }

    func testSwipingLeftAFullWidthMovesOneDesktopRight() {
        send(.swipe(axis: .horizontal, phase: .began, distance: -0.1),
             .swipe(axis: .horizontal, phase: .changed, distance: -0.6),
             .swipe(axis: .horizontal, phase: .ended, distance: -1))
        // 5 spaces -> 1.25 offset per desktop; positive means the next desktop (measured on macOS 26.2).
        // (Values chosen to be exact in Float32: the field is stored as a 32-bit float.)
        XCTAssertEqual(dock.map(\.phase), [1, 2, 4])
        XCTAssertEqual(dock.map(\.offset), [0.125, 0.75, 0.75], "ended reports the last offset it moved to")
        XCTAssertEqual(dock.map(\.type), [1, 1, 1])
        XCTAssertTrue(events.isEmpty, "gestures go to the session tap, not the HID tap")
        XCTAssertEqual(gestures.count, 6, "each step is a Dock event plus a gesture event")
    }

    func testDockEventCarriesTheOffsetTwiceAndTheTypeAsAFloatBitPattern() {
        let e = DockSwipe.events(axis: .horizontal, phase: .changed, offset: 0.75)[0]
        XCTAssertEqual(field(e, 110), 23, "kIOHIDEventTypeDockSwipe")
        XCTAssertEqual(e.getIntegerValueField(CGEventField(rawValue: 135)!), Int64(Float(0.75).bitPattern))
        XCTAssertEqual(field(e, 119), Double(Float(bitPattern: 1)))
        XCTAssertEqual(DockSwipe.offsetPerSpace(spaces: 2), 2)
        XCTAssertEqual(DockSwipe.offsetPerSpace(spaces: 5), 1.25)
        XCTAssertEqual(DockSwipe.offsetPerSpace(spaces: 1), 2)
    }

    func testSwipingUpIsMissionControl() {
        send(.swipe(axis: .vertical, phase: .began, distance: -0.2), .swipe(axis: .vertical, phase: .ended, distance: -0.2))
        XCTAssertEqual(dock.map(\.type), [2, 2])
        XCTAssertEqual(dock[0].offset, 0.2, accuracy: 1e-6, "up is positive: +1.0 opened Mission Control on macOS 26.2")
    }

    func testLiftingWhileMovingBackCancels() {
        send(.swipe(axis: .horizontal, phase: .began, distance: -0.2),
             .swipe(axis: .horizontal, phase: .changed, distance: -0.5),
             .swipe(axis: .horizontal, phase: .changed, distance: -0.4),
             .swipe(axis: .horizontal, phase: .ended, distance: -0.4))
        XCTAssertEqual(dock.last?.phase, 8, "cancelled: the fingers were heading back")
    }

    func testEndIsSentAgainAfterAPauseUnlessANewSwipeStarted() {
        send(.swipe(axis: .horizontal, phase: .began, distance: -0.2), .swipe(axis: .horizontal, phase: .ended, distance: -0.2))
        XCTAssertEqual(pending.map(\.0), [0.2])
        pending.removeFirst().1()
        XCTAssertEqual(dock.map(\.phase), [1, 4, 4])

        gestures = []
        send(.swipe(axis: .horizontal, phase: .began, distance: -0.2), .swipe(axis: .horizontal, phase: .ended, distance: -0.2))
        send(.swipe(axis: .horizontal, phase: .began, distance: 0.1))
        pending.removeFirst().1() // the first swipe's re-send must not end the second
        XCTAssertEqual(dock.map(\.phase), [1, 4, 1])
    }

    func testDisconnectMidSwipeLetsGoOfTheDock() {
        send(.swipe(axis: .horizontal, phase: .began, distance: -0.3))
        send(.releaseAll)
        XCTAssertEqual(dock.last?.phase, 8)
        gestures = []
        send(.releaseAll)
        XCTAssertTrue(gestures.isEmpty)
    }

    func testUnknownSpaceCountAssumesTwo() {
        spaceCount = nil
        send(.swipe(axis: .horizontal, phase: .began, distance: -0.5))
        XCTAssertEqual(dock.first?.offset, 1.0)
    }

    func testChangeOrEndWithoutBeganIsIgnored() {
        send(.swipe(axis: .horizontal, phase: .changed, distance: -0.5), .swipe(axis: .horizontal, phase: .ended, distance: -0.5))
        XCTAssertTrue(gestures.isEmpty)
    }
}
