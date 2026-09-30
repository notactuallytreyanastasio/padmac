import CoreGraphics
import XCTest

/// Input logic with events captured instead of posted: nothing touches the real cursor.
final class InputInjectorTests: XCTestCase {
    private var events: [CGEvent] = []
    private var clock: TimeInterval = 1000
    private var realCursor = CGPoint(x: 100, y: 100)
    private var injector: InputInjector!

    override func setUp() {
        events = []
        let system = InputInjector.System(
            post: { [unowned self] in self.events.append($0) },
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

    func testScrollIsPixelBased() {
        send(.scroll(dx: 3, dy: -40))
        XCTAssertEqual(types, [.scrollWheel])
        XCTAssertEqual(events[0].getIntegerValueField(.scrollWheelEventIsContinuous), 1, "pixel scrolling")
        XCTAssertEqual(events[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -40)
        XCTAssertEqual(events[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 3)
    }
}
