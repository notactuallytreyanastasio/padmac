import IOKit.pwr_mgt
import Network
import XCTest

/// The real HostServer and HostSession, driven over the wire. Runs in dry-run
/// mode with an input log, so the protocol wiring is tested without screen
/// capture and without posting events.
final class HostServerTests: XCTestCase {
    private let port: UInt16 = 47_531
    private var server: HostServer!
    private var logURL: URL!
    private let queue = DispatchQueue(label: "test.host")
    private var clients: [FramedConnection] = []

    override func setUpWithError() throws {
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("input-\(UUID()).jsonl")
        let d = UserDefaults.standard
        d.set(Int(port), forKey: "port")
        d.set(true, forKey: "dryRunInput")
        d.set(logURL.path, forKey: "inputLog")
        server = HostServer()
        try server.start(code: "TESTCODE", name: "test-\(UUID().uuidString.prefix(6))")
        Thread.sleep(forTimeInterval: 0.3)
    }

    override func tearDown() {
        clients.forEach { $0.cancel() }
        server.stop()
        for k in ["port", "dryRunInput", "inputLog"] { UserDefaults.standard.removeObject(forKey: k) }
        try? FileManager.default.removeItem(at: logURL)
    }

    private func client() -> (FramedConnection, XCTestExpectation) {
        let c = FramedConnection(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                              using: PairingSecurity.parameters(code: "TESTCODE")), queue: queue)
        let ready = expectation(description: "ready")
        c.onReady = { ready.fulfill() }
        clients.append(c)
        return (c, ready)
    }

    private func loggedEvents() -> [InputEvent] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(InputEvent.self, from: Data($0.utf8)) }
    }

    func testInputEventsReachTheInjectorInOrder() throws {
        let (c, ready) = client()
        c.start()
        wait(for: [ready], timeout: 5)
        let sent: [InputEvent] = [.moveTo(x: 0.5, y: 0.5), .button(.left, down: true), .button(.left, down: false),
                                  .key(code: 55, down: true), .text("hi"), .key(code: 55, down: false)]
        for e in sent { c.send(.input, json: e) }
        let deadline = Date().addingTimeInterval(3)
        while loggedEvents().count < sent.count && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(loggedEvents(), sent)
    }

    func testMalformedInputHangsUp() throws {
        let (c, ready) = client()
        let closed = expectation(description: "closed")
        c.onClose = { _ in closed.fulfill() }
        c.start()
        wait(for: [ready], timeout: 5)
        c.send(.input, Data("{not json".utf8))
        wait(for: [closed], timeout: 5)
    }

    func testClientSendingHostMessagesHangsUp() throws {
        let (c, ready) = client()
        let closed = expectation(description: "closed")
        c.onClose = { _ in closed.fulfill() }
        c.start()
        wait(for: [ready], timeout: 5)
        c.send(.videoFrame, Data([1, 2, 3]))
        wait(for: [closed], timeout: 5)
    }

    func testAConnectionWithoutTheCodeCannotKickTheCurrentClientOff() throws {
        let (current, ready) = client()
        var closed = false
        current.onClose = { _ in closed = true }
        current.start()
        wait(for: [ready], timeout: 5)

        // A wrong code, and a raw TCP connect that never handshakes.
        let wrong = FramedConnection(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                                  using: PairingSecurity.parameters(code: "WRONGCOD")), queue: queue)
        let rejected = expectation(description: "wrong code rejected")
        wrong.onClose = { _ in rejected.fulfill() }
        wrong.start()
        clients.append(wrong)
        let raw = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        raw.start(queue: queue)
        wait(for: [rejected], timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        raw.cancel()

        XCTAssertFalse(closed, "the paired client must stay connected")
        current.send(.input, json: InputEvent.releaseAll)
        let deadline = Date().addingTimeInterval(3)
        while loggedEvents().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(loggedEvents(), [.releaseAll], "and still be the one in control")
    }

    func testANewClientReplacesTheOldAndTellsItWhy() throws {
        let (first, r1) = client()
        let firstClosed = expectation(description: "first closed")
        var reason: String?
        // A bare disconnect would make the displaced iPad reconnect and knock the new one off.
        first.onMessage = { t, d in if t == .error { reason = String(decoding: d, as: UTF8.self) } }
        first.onClose = { _ in firstClosed.fulfill() }
        first.start()
        wait(for: [r1], timeout: 5)
        let (second, r2) = client()
        second.start()
        wait(for: [r2, firstClosed], timeout: 5)
        XCTAssertTrue(reason?.hasPrefix("Another device connected") == true, "got \(String(describing: reason))")
        second.send(.input, json: InputEvent.releaseAll)
        let deadline = Date().addingTimeInterval(3)
        while loggedEvents().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(loggedEvents(), [.releaseAll])
    }
}

final class PowerAssertionTests: XCTestCase {
    private func displaySleepPrevented() -> Bool {
        var byProcess: Unmanaged<CFDictionary>?
        IOPMCopyAssertionsByProcess(&byProcess)
        let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] ?? [:]
        return (all[NSNumber(value: getpid())] ?? []).contains {
            $0[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleDisplaySleep
        }
    }

    func testHeldWhileAliveReleasedAfter() {
        XCTAssertFalse(displaySleepPrevented())
        var a: PowerAssertion? = PowerAssertion(reason: "test")
        XCTAssertTrue(a!.held)
        XCTAssertTrue(displaySleepPrevented())
        a = nil
        XCTAssertFalse(displaySleepPrevented())
    }

    func testAPairedConnectionHoldsTheDisplayAwake() throws {
        UserDefaults.standard.set(47_532, forKey: "port")
        defer { UserDefaults.standard.removeObject(forKey: "port") }
        let server = HostServer()
        try server.start(code: "TESTCODE", name: "power-test")
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.3)

        let queue = DispatchQueue(label: "test.power")
        let c = FramedConnection(NWConnection(host: "127.0.0.1", port: 47_532, using: PairingSecurity.parameters(code: "TESTCODE")), queue: queue)
        let ready = expectation(description: "ready")
        c.onReady = { ready.fulfill() }
        c.start()
        wait(for: [ready], timeout: 5)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(displaySleepPrevented(), "connected")

        c.cancel()
        let deadline = Date().addingTimeInterval(3)
        while displaySleepPrevented() && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(displaySleepPrevented(), "released when the iPad goes away")
    }
}
