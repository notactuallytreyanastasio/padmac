import AVFoundation
import Network
import UIKit

protocol VideoSink: AnyObject {
    /// Called on the session queue.
    func videoFormat(_ format: CMVideoFormatDescription)
    func videoFrame(_ avcc: Data, keyframe: Bool)
}

/// One connection to a Mac: decodes the host's messages and sends input.
final class RemoteSession: ObservableObject {
    enum State: Equatable {
        case connecting
        case streaming
        case failed(String, badCode: Bool)
    }

    let hostName: String
    @Published private(set) var state = State.connecting
    @Published private(set) var screen: ScreenInfo?
    weak var video: VideoSink?

    private let queue = DispatchQueue(label: "remotemac.client", qos: .userInteractive)
    private let conn: FramedConnection
    private var format: CMVideoFormatDescription?
    private var hostError: String?

    init(hostName: String, endpoint: NWEndpoint, code: String) {
        self.hostName = hostName
        conn = FramedConnection(NWConnection(to: endpoint, using: PairingSecurity.parameters(code: code)), queue: queue)
    }

    func start() {
        let native = UIScreen.main.nativeBounds.size
        let hello = Hello(clientName: UIDevice.current.name,
                          maxWidth: Int(max(native.width, native.height)),
                          maxHeight: Int(min(native.width, native.height)))
        conn.onReady = { [conn] in conn.send(.hello, json: hello) }
        conn.onMessage = { [weak self] type, payload in self?.handle(type, payload) }
        conn.onClose = { [weak self] error in
            var (msg, badCode) = Self.describe(error)
            if let reason = self?.hostError { msg = reason; badCode = false }
            DispatchQueue.main.async { self?.state = .failed(msg, badCode: badCode) }
        }
        conn.start()
    }

    func stop() {
        send(.releaseAll)
        conn.cancel()
    }

    func send(_ event: InputEvent) {
        conn.send(.input, json: event)
    }

    func requestKeyframe() {
        conn.send(.requestKeyframe)
    }

    private func handle(_ type: MessageType, _ payload: Data) {
        switch type {
        case .screenInfo:
            guard let info = try? JSONDecoder().decode(ScreenInfo.self, from: payload) else { return conn.cancel() }
            DispatchQueue.main.async { self.screen = info; self.state = .streaming }
        case .videoFormat:
            guard let (sps, pps) = VideoFormatPayload.decode(payload),
                  let f = H264.formatDescription(sps: sps, pps: pps) else { return conn.cancel() }
            format = f
            video?.videoFormat(f)
        case .videoFrame:
            guard !payload.isEmpty else { return }
            video?.videoFrame(payload.dropFirst(), keyframe: payload[payload.startIndex] & 1 == 1)
        case .error:
            hostError = String(decoding: payload, as: UTF8.self)
        case .hello, .input, .requestKeyframe:
            conn.cancel()
        }
    }

    private static func describe(_ error: Error?) -> (String, Bool) {
        guard let error else { return ("The Mac closed the connection.", false) }
        if let nw = error as? NWError {
            switch nw {
            case .tls: return ("The Mac rejected the pairing code.", true)
            case .posix(let code) where code == .ECONNREFUSED: return ("Nothing is listening on the Mac. Is Remote Mac Host running?", false)
            default: break
            }
        }
        return (error.localizedDescription, false)
    }
}
