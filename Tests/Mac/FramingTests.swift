import Network
import XCTest

/// FramedConnection over a real TLS-PSK loopback socket.
final class FramingTests: XCTestCase {
    private let queue = DispatchQueue(label: "test.framing")
    private var listener: NWListener?
    private var server: FramedConnection?
    private var client: FramedConnection?

    override func tearDown() {
        client?.cancel()
        server?.cancel()
        listener?.cancel()
    }

    /// Starts a listener; `accepted` is called with the server side of each connection.
    private func listen(code: String, accepted: @escaping (NWConnection) -> Void) throws -> UInt16 {
        let l = try NWListener(using: PairingSecurity.parameters(code: code), on: .any)
        let ready = expectation(description: "listening")
        l.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        l.newConnectionHandler = accepted
        l.start(queue: queue)
        listener = l
        wait(for: [ready], timeout: 5)
        return try XCTUnwrap(l.port?.rawValue)
    }

    private func connect(port: UInt16, code: String) -> FramedConnection {
        FramedConnection(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                      using: PairingSecurity.parameters(code: code)), queue: queue)
    }

    func testMessagesArriveIntactAndInOrder() throws {
        var received: [(MessageType, Data)] = []
        let done = expectation(description: "all received")
        var rng = SystemRandomNumberGenerator()
        var sent: [(MessageType, Data)] = (0..<300).map { i in
            let n = [0, 1, 5, 100, 65_536, 200_000].randomElement(using: &rng)!
            return (i % 2 == 0 ? .input : .clipboard, Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        }
        sent.append((.videoFrame, Data(repeating: 0xAB, count: 5 << 20)))
        let port = try listen(code: "TESTCODE") { conn in
            let s = FramedConnection(conn, queue: self.queue)
            s.onMessage = { t, d in
                received.append((t, d))
                if received.count == sent.count { done.fulfill() }
            }
            s.start()
            self.server = s
        }
        let c = connect(port: port, code: "TESTCODE")
        c.onReady = { for (t, d) in sent { c.send(t, d) } }
        c.start()
        client = c
        wait(for: [done], timeout: 20)
        XCTAssertEqual(received.map(\.0), sent.map(\.0))
        XCTAssertEqual(received.map(\.1), sent.map(\.1))
    }

    func testWrongPairingCodeFailsTheHandshake() throws {
        let port = try listen(code: "TESTCODE") { conn in
            let s = FramedConnection(conn, queue: self.queue)
            s.onMessage = { _, _ in XCTFail("server received a message from an unauthenticated client") }
            s.start()
            self.server = s
        }
        let closed = expectation(description: "closed")
        let c = connect(port: port, code: "WRONGCOD")
        c.onReady = { XCTFail("handshake should not complete") }
        c.onClose = { error in
            guard case .tls = error as? NWError else { return XCTFail("expected a TLS error, got \(String(describing: error))") }
            closed.fulfill()
        }
        c.start()
        client = c
        wait(for: [closed], timeout: 10)
    }

    /// Writes raw bytes after the TLS handshake and returns why the server hung up.
    private func serverCloseReason(afterRaw bytes: Data) throws -> Error? {
        var reason: Error?
        let closed = expectation(description: "server closed")
        let port = try listen(code: "TESTCODE") { conn in
            let s = FramedConnection(conn, queue: self.queue)
            s.onMessage = { t, _ in XCTFail("delivered a bogus \(t)") }
            s.onClose = { reason = $0; closed.fulfill() }
            s.start()
            self.server = s
        }
        let raw = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: PairingSecurity.parameters(code: "TESTCODE"))
        raw.stateUpdateHandler = { if case .ready = $0 { raw.send(content: bytes, completion: .idempotent) } }
        raw.start(queue: queue)
        wait(for: [closed], timeout: 10)
        raw.cancel()
        return reason
    }

    func testUnknownMessageTypeClosesTheConnection() throws {
        let reason = try serverCloseReason(afterRaw: Data([0x7F, 0, 0, 0, 0]))
        guard case .unknownType(0x7F) = reason as? ProtocolError else { return XCTFail("got \(String(describing: reason))") }
    }

    func testOversizedLengthClosesTheConnection() throws {
        let reason = try serverCloseReason(afterRaw: Data([MessageType.input.rawValue, 0x7F, 0xFF, 0xFF, 0xFF]))
        guard case .tooLarge = reason as? ProtocolError else { return XCTFail("got \(String(describing: reason))") }
    }

    func testVideoBackpressureWhenThePeerStopsReading() throws {
        // A server that accepts but never reads: the socket buffers fill up.
        let port = try listen(code: "TESTCODE") { conn in conn.start(queue: self.queue) }
        let ready = expectation(description: "ready")
        let c = connect(port: port, code: "TESTCODE")
        c.onReady = { ready.fulfill() }
        c.start()
        client = c
        wait(for: [ready], timeout: 5)

        XCTAssertTrue(c.canSendVideo)
        let big = Data(repeating: 1, count: 16 << 20)
        c.send(.videoFrame, big)
        c.send(.videoFrame, big)
        XCTAssertFalse(c.canSendVideo, "two unacknowledged frames should stop the encoder")
        // Non-video messages are never held back.
        c.send(.cursor, CursorPayload.encode(x: 0, y: 0))
        XCTAssertFalse(c.canSendVideo)
    }
}
