import XCTest

/// Drives the real iPad app in the simulator against a real host running with
/// `-dryRunInput YES -inputLog <path>`, then asserts on the input the host
/// received. Gesture recognizers, the toolbar and the keyboard are all real;
/// only the final CGEvent post is skipped, so the Mac's cursor is left alone.
///
/// Run through `scripts/test.sh`, which starts that host and passes
/// REMOTEMAC_HOST and REMOTEMAC_INPUT_LOG to this runner.
/// Subclassed by WindowModeUITests, which reruns every test here in window mode.
class RemoteMacUITests: XCTestCase {
    fileprivate var app: XCUIApplication!
    /// Overridden by the window-mode tests.
    var windowMode: Bool { false }
    fileprivate var screen: XCUIElement!
    private var log: InputLog!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let host = try XCTUnwrap(env["REMOTEMAC_HOST"], "run via scripts/test.sh")
        log = InputLog(path: try XCTUnwrap(env["REMOTEMAC_INPUT_LOG"]))

        app = XCUIApplication()
        // The whole display, on any device; window mode has its own test below.
        app.launchArguments = ["-autoconnect", host, "-code", env["REMOTEMAC_CODE"] ?? "TESTCODE",
                               "-windowMode", windowMode ? "YES" : "NO"]
        app.launch()
        screen = app.descendants(matching: .any)["remote-screen"]
        let streaming = NSPredicate(format: "value BEGINSWITH 'streaming'")
        let ok = XCTWaiter().wait(for: [expectation(for: streaming, evaluatedWith: screen)], timeout: 20)
        XCTAssertEqual(ok, .completed, "never started streaming; screen value: \(String(describing: screen.value))")
        Thread.sleep(forTimeInterval: 0.3)
        log.mark()
    }

    override func tearDown() {
        app?.terminate()
    }

    private var zoom: Double {
        let v = screen.value as? String ?? ""
        guard let r = v.range(of: "zoom=") else { return 0 }
        return Double(v[r.upperBound...].prefix(while: { $0 != " " })) ?? 0
    }

    /// Where the app says the Mac picture is, as fractions of the screen element.
    fileprivate var content: CGRect {
        let v = screen.value as? String ?? ""
        guard let r = v.range(of: "content=") else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let n = v[r.upperBound...].prefix(while: { $0 != " " }).split(separator: ",").compactMap { Double($0) }
        return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private func at(_ x: Double, _ y: Double) -> XCUICoordinate {
        screen.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    private func buttons(_ events: [InputEvent]) -> [String] {
        events.compactMap {
            guard case .button(let b, let down) = $0 else { return nil }
            return "\(b)\(down ? "↓" : "↑")"
        }
    }

    // MARK: Trackpad mode (the default)

    func testTapClicksWhereTheCursorAlreadyIs() {
        screen.tap()
        let e = log.waitFor { self.buttons($0).count >= 2 }
        XCTAssertEqual(buttons(e), ["left↓", "left↑"])
        XCTAssertFalse(e.contains { if case .moveTo = $0 { true } else { false } }, "trackpad taps must not warp the cursor")
    }

    func testDoubleTapIsTwoClicksForTheHostToCount() {
        screen.doubleTap()
        let e = log.waitFor { self.buttons($0).count >= 4 }
        XCTAssertEqual(buttons(e), ["left↓", "left↑", "left↓", "left↑"])
    }

    func testTwoFingerTapRightClicks() {
        screen.twoFingerTap()
        let e = log.waitFor { self.buttons($0).count >= 2 }
        XCTAssertEqual(buttons(e), ["right↓", "right↑"])
    }

    func testDragMovesTheCursorRelativelyWithoutClicking() {
        at(0.3, 0.5).press(forDuration: 0.05, thenDragTo: at(0.7, 0.5))
        let e = log.waitFor(settle: 0.5) { $0.contains { if case .moveBy = $0 { true } else { false } } }
        let dx = e.reduce(0.0) { if case .moveBy(let dx, _) = $1 { $0 + dx } else { $0 } }
        let dy = e.reduce(0.0) { if case .moveBy(_, let dy) = $1 { $0 + dy } else { $0 } }
        XCTAssertGreaterThan(dx, 100, "dragged right")
        XCTAssertLessThan(abs(dy), dx / 5, "mostly horizontal")
        XCTAssertEqual(buttons(e), [], "a plain drag is not a click")
    }

    func testHoldThenDragDragsWithTheButtonDown() {
        at(0.3, 0.5).press(forDuration: 0.8, thenDragTo: at(0.6, 0.5))
        let e = log.waitFor(settle: 0.5) { self.buttons($0).count >= 2 }
        XCTAssertEqual(buttons(e), ["left↓", "left↑"])
        let down = e.firstIndex { $0 == .button(.left, down: true) }!
        let up = e.firstIndex { $0 == .button(.left, down: false) }!
        XCTAssertTrue(e[down..<up].contains { if case .moveBy = $0 { true } else { false } }, "moved while held")
    }

    // MARK: Zoom

    func testPinchZoomsLocallyWithoutClickingOrScrollingTheMac() {
        screen.pinch(withScale: 3, velocity: 2)
        XCTAssertGreaterThan(zoom, 1.5)
        let e = log.waitFor(settle: 0.5) { _ in false }
        XCTAssertEqual(buttons(e), [])
        let scrolled = e.reduce(0.0) { if case .scroll(let dx, let dy, _, _) = $1 { $0 + abs(dx) + abs(dy) } else { $0 } }
        XCTAssertLessThan(scrolled, 40, "a pinch may start as a scroll but must stop scrolling once it's a pinch")
    }

    func testZoomButtonTogglesFillAndDoesNotClickTheMac() {
        app.buttons["Zoom"].tap()
        XCTAssertGreaterThan(zoom, 1.5, "fills the short side")
        app.buttons["Zoom"].tap()
        XCTAssertEqual(zoom, 1, accuracy: 0.01)
        XCTAssertEqual(buttons(log.waitFor(settle: 0.5) { _ in false }), [], "toolbar taps stay on the iPad")
    }

    // MARK: Direct mode

    func testDirectModeClicksWhereYouTap() throws {
        app.buttons["Touch mode"].tap()
        XCTAssertTrue((screen.value as? String ?? "").contains("mode=direct"))
        // A quarter of the way across the Mac picture, wherever the picture is.
        let c = content
        at(c.minX + 0.25 * c.width, c.minY + 0.5 * c.height).tap()
        let e = log.waitFor { self.buttons($0).count >= 2 }
        guard case .moveTo(let x, let y)? = e.first(where: { if case .moveTo = $0 { true } else { false } }) else {
            return XCTFail("no moveTo in \(e)")
        }
        XCTAssertEqual(x, 0.25, accuracy: 0.02, "screen \(screen.frame) in window \(app.windows.firstMatch.frame); value \(String(describing: screen.value))")
        XCTAssertEqual(y, 0.5, accuracy: 0.02)
        XCTAssertEqual(buttons(e), ["left↓", "left↑"])
    }

    // MARK: Keyboard

    /// Taps the on-screen keyboard's own keys. XCUITest's typeText won't type
    /// into a plain UIKeyInput view (it wants a text field with "keyboard focus").
    private func tapKeys(_ text: String) {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5),
                      "no on-screen keyboard; turn off I/O > Keyboard > Connect Hardware Keyboard in the simulator")
        for c in text {
            // The space bar's label was " " before iOS 27, "space" since.
            let key = c == " " && keyboard.keys["space"].exists ? keyboard.keys["space"] : keyboard.keys[String(c)]
            XCTAssertTrue(key.waitForExistence(timeout: 2),
                          "no key \(c); keys: \(keyboard.keys.allElementsBoundByIndex.map { "\($0.identifier)|\($0.label)" })")
            key.tap()
        }
    }

    func testOnScreenKeyboardTypesText() {
        app.buttons["Keyboard"].tap()
        tapKeys("hi there")
        let e = log.waitFor(settle: 0.5) { KeyText.typed($0).count >= 8 }
        XCTAssertEqual(KeyText.typed(e), "hi there")
    }

    func testStickyCommandTurnsTheNextLetterIntoAShortcut() {
        app.buttons["Keyboard"].tap()
        tapKeys("")
        app.buttons["⌘"].tap()
        tapKeys("c")
        let e = log.waitFor(settle: 0.5) { $0.contains(.key(code: 55, down: false)) }
        let keys = e.compactMap { ev -> String? in
            guard case .key(let code, let down) = ev else { return nil }
            return "\(code)\(down ? "↓" : "↑")"
        }
        XCTAssertEqual(keys, ["55↓", "8↓", "8↑", "55↑"], "⌘ down, c, ⌘ up")
    }
}

/// Reads the host's input log (JSON lines) from the Mac filesystem.
final class InputLog {
    private let url: URL
    private var offset = 0

    init(path: String) { url = URL(fileURLWithPath: path) }

    private func all() -> [InputEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONDecoder().decode(InputEvent.self, from: Data($0)) }
    }

    /// Only events after this point count.
    func mark() { offset = all().count }

    /// Polls until `done` holds, then keeps collecting for `settle` seconds.
    func waitFor(timeout: TimeInterval = 5, settle: TimeInterval = 0.2, _ done: @escaping ([InputEvent]) -> Bool) -> [InputEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        var events: [InputEvent] = []
        repeat {
            events = Array(all().dropFirst(offset))
            if done(events) { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        Thread.sleep(forTimeInterval: settle)
        return Array(all().dropFirst(offset))
    }
}

/// What a sequence of input events types, whether the simulator delivered
/// the keystrokes as text (on-screen keyboard) or as key codes (hardware keyboard).
enum KeyText {
    static let letters: [UInt16: Character] = {
        var m: [UInt16: Character] = [49: " "]
        let codes: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { m[codes[i]] = c }
        return m
    }()

    static func typed(_ events: [InputEvent]) -> String {
        var s = ""
        for e in events {
            switch e {
            case .text(let t): s += t
            case .key(let code, true): if let c = letters[code] { s.append(c) }
            default: break
            }
        }
        return s
    }
}

/// Every test above again, in window mode, plus its own. Against the dry-run host, which also runs with
/// `-dryRunWindows YES`: it streams a real Mac window but never resizes it.
final class WindowModeUITests: RemoteMacUITests {
    override var windowMode: Bool { true }

    func testStreamsOneWindowAndTheToolbarListsThem() {
        XCTAssertTrue((screen.value as? String ?? "").contains("window=on"), "value: \(String(describing: screen.value))")
        app.buttons["Windows"].tap()
        XCTAssertTrue(app.buttons["Show whole display"].waitForExistence(timeout: 3))
        app.buttons["Show whole display"].tap()
        let off = NSPredicate(format: "value CONTAINS 'window=off'")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: off, evaluatedWith: screen)], timeout: 5), .completed)
    }
}


