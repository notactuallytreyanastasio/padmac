import AVFoundation
import Network
import UIKit

protocol VideoSink: AnyObject {
    /// Called on the session queue.
    func videoFormat(_ format: CMVideoFormatDescription)
    func videoFrame(_ data: Data, keyframe: Bool)
}

/// One Mac: keeps a connection to it alive, decodes its messages, sends input.
///
/// iOS tears the socket down whenever the app is backgrounded, so a dropped
/// connection is normal, not an error: the session reconnects with backoff, and
/// immediately when the app returns to the foreground. Only a rejected pairing
/// code or a reason sent by the host stops it.
final class RemoteSession: ObservableObject {
    enum State: Equatable {
        case connecting
        case streaming
        case reconnecting(String)
        case failed(String, badCode: Bool)
    }

    let hostName: String
    @Published private(set) var state = State.connecting
    @Published private(set) var screen: ScreenInfo?
    weak var video: VideoSink?
    /// Main thread: the Mac cursor, normalised to the streamed display.
    var onCursor: ((Double, Double) -> Void)?
    /// Main thread: a new stream started (first connect, reconnect, display switch).
    var onScreen: ((ScreenInfo) -> Void)?

    private let endpoint: NWEndpoint
    private let code: String
    private let queue = DispatchQueue(label: "remotemac.client", qos: .userInteractive)
    private var conn: FramedConnection? // main thread
    private var hostError: String?      // session queue
    private var stopped = false
    private var attempt = 0
    private var displayID: UInt32?
    private var foreground: NSObjectProtocol?

    init(hostName: String, endpoint: NWEndpoint, code: String) {
        self.hostName = hostName
        self.endpoint = endpoint
        self.code = code
    }

    func start() {
        foreground = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, case .reconnecting = self.state else { return }
            self.connect()
        }
        connect()
    }

    func stop() {
        stopped = true
        send(.releaseAll)
        conn?.cancel()
        conn = nil
        if let foreground { NotificationCenter.default.removeObserver(foreground) }
    }

    func send(_ event: InputEvent) {
        conn?.send(.input, json: event)
    }

    func requestKeyframe() {
        conn?.send(.requestKeyframe)
    }

    func selectDisplay(_ id: UInt32) {
        conn?.send(.selectDisplay, json: SelectDisplay(displayID: id))
    }

    func sendClipboard(_ text: String) {
        conn?.send(.clipboard, Data(text.utf8))
    }

    private func connect() {
        guard !stopped else { return }
        conn?.cancel()
        let native = UIScreen.main.nativeBounds.size
        // Twice the iPad's own pixels, so zooming in stays sharp. The host caps it at the Mac's native size.
        let hello = Hello(clientName: UIDevice.current.name,
                          maxWidth: min(8192, Int(max(native.width, native.height)) * 2),
                          maxHeight: min(8192, Int(min(native.width, native.height)) * 2),
                          codecs: [.hevc, .h264], displayID: displayID)
        let c = FramedConnection(NWConnection(to: endpoint, using: PairingSecurity.parameters(code: code)), queue: queue)
        conn = c
        queue.async { self.hostError = nil }
        c.onReady = { [weak c] in c?.send(.hello, json: hello) }
        c.onMessage = { [weak self] type, payload in self?.handle(type, payload) }
        c.onClose = { [weak self, weak c] error in
            guard let self else { return }
            let hostError = self.hostError
            DispatchQueue.main.async {
                guard self.conn === c else { return } // superseded
                self.lost(error, hostError: hostError)
            }
        }
        c.start()
    }

    private func lost(_ error: Error?, hostError: String?) {
        guard !stopped else { return }
        conn = nil
        let (message, badCode) = Self.describe(error)
        if let hostError {
            state = .failed(hostError, badCode: false)
        } else if badCode {
            state = .failed(message, badCode: true)
        } else {
            attempt += 1
            state = .reconnecting(message)
            let delay = min(8, 0.5 * pow(2, Double(attempt - 1)))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, case .reconnecting = self.state,
                      UIApplication.shared.applicationState == .active else { return }
                self.connect()
            }
        }
    }

    private func handle(_ type: MessageType, _ payload: Data) {
        switch type {
        case .screenInfo:
            guard let info = try? JSONDecoder().decode(ScreenInfo.self, from: payload) else { return fail(type) }
            DispatchQueue.main.async {
                self.attempt = 0
                self.displayID = info.displayID
                self.screen = info
                self.state = .streaming
                self.onScreen?(info)
            }
        case .videoFormat:
            guard let (codec, sets) = VideoFormatPayload.decode(payload),
                  let f = VideoFormat.description(codec: codec, parameterSets: sets) else { return fail(type) }
            video?.videoFormat(f)
        case .videoFrame:
            guard !payload.isEmpty else { return fail(type) }
            video?.videoFrame(payload.dropFirst(), keyframe: payload[payload.startIndex] & 1 == 1)
        case .cursor:
            guard let (x, y) = CursorPayload.decode(payload) else { return fail(type) }
            DispatchQueue.main.async { self.onCursor?(x, y) }
        case .clipboard:
            let text = String(decoding: payload, as: UTF8.self)
            DispatchQueue.main.async { UIPasteboard.general.string = text }
        case .error:
            hostError = String(decoding: payload, as: UTF8.self)
        case .hello, .input, .requestKeyframe, .selectDisplay:
            fail(type)
        }
    }

    private func fail(_ type: MessageType) {
        NSLog("RemoteMac: bad \(type) message from host")
        hostError = ProtocolError.badPayload(type).localizedDescription
        DispatchQueue.main.async { self.conn?.cancel() }
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
