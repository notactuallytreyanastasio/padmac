import CoreGraphics
import Foundation
import Network

/// One connected iPad: streams the screen out and applies its input.
final class HostSession {
    let peer: String
    private let conn: FramedConnection
    private let queue = DispatchQueue(label: "remotemac.session", qos: .userInteractive)
    private var streamer: ScreenStreamer?
    private var injector: InputInjector?
    private let decoder = JSONDecoder()

    var onStatus: ((String) -> Void)?
    var onEnd: ((HostSession, Error?) -> Void)?

    init(connection: NWConnection) {
        peer = connection.endpoint.debugDescription
        conn = FramedConnection(connection, queue: queue)
    }

    func start() {
        conn.onMessage = { [weak self] type, payload in self?.handle(type, payload) }
        conn.onDrain = { [weak self] in self?.streamer?.drained() }
        conn.onClose = { [weak self] error in
            guard let self else { return }
            self.teardown()
            self.onEnd?(self, error)
        }
        conn.start()
    }

    func stop() { conn.cancel() }

    private func teardown() {
        streamer?.stop()
        streamer = nil
        injector?.releaseAll()
    }

    private func handle(_ type: MessageType, _ payload: Data) {
        switch type {
        case .hello:
            guard let hello = try? decoder.decode(Hello.self, from: payload) else { return fail(.badPayload(type)) }
            begin(hello)
        case .input:
            guard let event = try? decoder.decode(InputEvent.self, from: payload) else { return fail(.badPayload(type)) }
            injector?.handle(event)
        case .requestKeyframe:
            streamer?.requestKeyframe()
        case .screenInfo, .videoFormat, .videoFrame, .error:
            fail(.badPayload(type))
        }
    }

    private func fail(_ error: ProtocolError) {
        NSLog("RemoteMac: \(peer): \(error.localizedDescription)")
        conn.cancel()
    }

    private func begin(_ hello: Hello) {
        guard streamer == nil else { return }
        let conn = self.conn
        let streamer = ScreenStreamer(output: .init(
            canSend: { conn.canSendVideo },
            format: { conn.send(.videoFormat, $0) },
            frame: { conn.send(.videoFrame, $0) },
            stopped: { error in
                NSLog("RemoteMac: capture stopped: \(error?.localizedDescription ?? "-")")
                conn.cancel()
            }))
        self.streamer = streamer
        onStatus?("Connected: \(hello.clientName)")
        Task {
            do {
                let info = try await streamer.start(maxWidth: hello.maxWidth, maxHeight: hello.maxHeight)
                queue.async {
                    self.injector = InputInjector(displayID: streamer.displayID)
                    conn.send(.screenInfo, json: info)
                    streamer.requestKeyframe()
                }
            } catch {
                NSLog("RemoteMac: capture failed: \(error)")
                let why = CGPreflightScreenCaptureAccess()
                    ? "Screen capture failed: \(error.localizedDescription)"
                    : "This Mac has not given Remote Mac Host Screen Recording permission. Grant it from the host's menu bar icon, then reopen the host."
                onStatus?(why)
                conn.send(.error, Data(why.utf8))
                // Let the message flush before hanging up.
                queue.asyncAfter(deadline: .now() + 0.5) { conn.cancel() }
            }
        }
    }
}
