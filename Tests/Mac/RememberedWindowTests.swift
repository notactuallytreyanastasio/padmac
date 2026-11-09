import CoreGraphics
import XCTest

final class RememberedWindowTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private func window(_ id: UInt32, pid: pid_t = 42, app: String = "Example") -> MacWindow {
        MacWindow(id: id, pid: pid, app: app, title: "", frame: CGRect(x: 0, y: 0, width: 700, height: 500))
    }
    override func setUp() {
        suite = "remembered-window-test-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testReconnectRestoresTheSelectedWindowEvenWhenAnotherIsFrontmost() throws {
        let store = RememberedWindowStore(defaults: defaults, boot: 123)
        store.remember(window(2), client: "iPhone")
        let reconnected = RememberedWindowStore(defaults: defaults, boot: 123)
        let selection = try XCTUnwrap(reconnected.load(client: "iPhone"))
        XCTAssertEqual(selection.restoredID(in: [window(1), window(2)]), 2)
    }
    func testClosedAndReusedWindowNumbersDoNotRestoreAnUnrelatedWindow() throws {
        let store = RememberedWindowStore(defaults: defaults, boot: 123)
        store.remember(window(2), client: "iPhone")
        let selection = try XCTUnwrap(store.load(client: "iPhone"))
        XCTAssertNil(selection.restoredID(in: [window(1)]))
        XCTAssertNil(selection.restoredID(in: [window(2, pid: 99)]))
        XCTAssertNil(selection.restoredID(in: [window(2, app: "Other")]))
    }
    func testDevicesKeepIndependentSelections() throws {
        let store = RememberedWindowStore(defaults: defaults, boot: 123)
        store.remember(window(2), client: "iPhone")
        store.remember(window(3), client: "iPad")
        XCTAssertEqual(store.load(client: "iPhone")?.id, 2)
        XCTAssertEqual(store.load(client: "iPad")?.id, 3)
    }
    func testNewBootOrUnavailableBootIdentityDoesNotReuseOldWindowNumbers() {
        let store = RememberedWindowStore(defaults: defaults, boot: 123)
        store.remember(window(2), client: "iPhone")
        XCTAssertNil(RememberedWindowStore(defaults: defaults, boot: 124).load(client: "iPhone"))
        XCTAssertNil(RememberedWindowStore(defaults: defaults, boot: nil).load(client: "iPhone"))
    }
    func testMalformedPreferencesFallBackWithoutBreakingConnection() {
        defaults.set(Data("invalid".utf8), forKey: "lastWindow.iPhone")
        XCTAssertNil(RememberedWindowStore(defaults: defaults, boot: 123).load(client: "iPhone"))
    }
}
