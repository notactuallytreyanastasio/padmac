import Network
import XCTest

final class QUICMediaTests: XCTestCase {
    private let queue = DispatchQueue(label: "test.quic")
    private var listener: NWListener?
    private var channels: [QUICMediaChannel] = []
    override func tearDown() { channels.forEach { $0.stop() }; listener?.cancel() }

    private func connect(wrongPin: Bool = false, wrongToken: Bool = false,
                         receive: @escaping (MediaDatagrams.Message) -> Void,
                         serverReady: @escaping (QUICMediaChannel) -> Void) throws -> QUICMediaChannel {
        guard #available(macOS 15, *) else { throw XCTSkip("Memory-only identities require macOS 15") }
        let identity = try QUICIdentity.make()
        let token = Data(repeating: 0x47, count: 32)
        let listener = try NWListener(using: MediaSecurity.server(identity: identity.identity), on: .any)
        self.listener = listener
        let listening = expectation(description: "QUIC listener")
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.newConnectionHandler = { connection in
            let channel = QUICMediaChannel(connection: connection, token: token, client: false, queue: self.queue)
            channel.onReady = { serverReady(channel) }
            self.channels.append(channel)
            channel.start()
        }
        listener.start(queue: queue)
        wait(for: [listening], timeout: 5)
        let parameters = MediaSecurity.client(fingerprint: wrongPin ? Data(repeating: 0, count: 32) : identity.fingerprint, queue: queue)
        let connection = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: parameters)
        let client = QUICMediaChannel(connection: connection, token: wrongToken ? Data(repeating: 1, count: 32) : token, client: true, queue: queue)
        client.onMessage = receive
        channels.append(client)
        return client
    }

    func testAuthenticatedQUICDatagramsDeliverLargeVideoAndAcknowledgeIt() throws {
        let received = expectation(description: "video arrives over QUIC")
        let drained = expectation(description: "receiver ACK releases video budget")
        let bytes = Data((0..<120_017).map { UInt8($0 % 251) })
        var didDrain = false
        let client = try connect(receive: { message in
            XCTAssertEqual(message.kind, .video)
            XCTAssertEqual(message.epoch, 7)
            XCTAssertEqual(message.data, bytes)
            received.fulfill()
        }, serverReady: { server in
            server.onDrain = { if !didDrain { didDrain = true; drained.fulfill() } }
            server.send(.video, data: bytes, epoch: 7, keyframe: true)
        })
        client.start()
        wait(for: [received, drained], timeout: 10)
    }

    func testWrongCertificatePinCannotAuthenticate() throws {
        let closed = expectation(description: "bad pin rejected")
        let client = try connect(wrongPin: true, receive: { _ in XCTFail("unauthenticated media") }, serverReady: { _ in XCTFail("bad pin accepted") })
        client.onReady = { XCTFail("bad pin accepted") }
        client.onClose = { closed.fulfill() }
        client.start()
        wait(for: [closed], timeout: 9)
    }

    func testWrongSessionTokenCannotReceiveMedia() throws {
        let closed = expectation(description: "bad token rejected")
        let client = try connect(wrongToken: true, receive: { _ in XCTFail("unauthenticated media") }, serverReady: { _ in XCTFail("bad token accepted") })
        client.onReady = { XCTFail("bad token accepted") }
        client.onClose = { closed.fulfill() }
        client.start()
        wait(for: [closed], timeout: 9)
    }
}
