import AVFoundation
import Network
import UIKit
import UniformTypeIdentifiers

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
    private let player = AudioPlayer()
    /// The speaker button. Remembered between launches; on by default.
    @Published private(set) var audioEnabled = UserDefaults.standard.object(forKey: "audio") as? Bool ?? true
    /// The quality menu. Remembered between launches.
    @Published private(set) var quality = UserDefaults.standard.string(forKey: "quality").flatMap(StreamQuality.init) ?? .full
    /// Window mode, at this size; nil streams the whole display. Read when the
    /// Hello goes out, on the session queue, so it is behind a lock.
    var windowRequest: WindowRequest? {
        get { windowLock.lock(); defer { windowLock.unlock() }; return _windowRequest }
        set { windowLock.lock(); _windowRequest = newValue; windowLock.unlock() }
    }
    private var _windowRequest: WindowRequest?
    private let windowLock = NSLock()
    private let meterLock = NSLock()
    private var videoMeter = RateMeter()
    private var totalMeter = RateMeter()

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
        player.stop()
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

    /// Switch between one window (at `request`'s size) and the whole display,
    /// or resize the window after the screen changed shape (fold, rotation).
    func setWindowMode(_ request: WindowRequest?) {
        windowRequest = request
        conn?.send(.setWindowMode, json: WindowModeChange(window: request))
    }

    /// Window mode: the next (+1) or previous (-1) window in the swipe order.
    func switchWindow(step: Int) {
        conn?.send(.switchWindow, json: SwitchWindow(step: step))
    }

    func showWindow(_ id: UInt32) {
        conn?.send(.switchWindow, json: SwitchWindow(windowID: id))
    }

    func setQuality(_ q: StreamQuality) {
        quality = q
        UserDefaults.standard.set(q.rawValue, forKey: "quality")
        conn?.send(.setQuality, json: q)
    }

    /// Received video and total traffic over the last two seconds.
    func linkStats() -> (videoMbps: Double, fps: Double, totalMbps: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        meterLock.lock(); defer { meterLock.unlock() }
        let v = videoMeter.rate(at: now), t = totalMeter.rate(at: now)
        return (v.megabitsPerSecond, v.perSecond, t.megabitsPerSecond)
    }

    func setAudio(_ on: Bool) {
        audioEnabled = on
        UserDefaults.standard.set(on, forKey: "audio")
        conn?.send(.audioEnabled, Data([on ? 1 : 0]))
        if !on { player.stop() }
    }

    func sendClipboard(_ text: String) {
        conn?.send(.clipboard, Data(text.utf8))
    }

    func sendClipboardImage(_ png: Data) {
        conn?.send(.clipboardImage, png)
    }

    private func connect() {
        guard !stopped else { return }
        conn?.cancel()
        let native = UIScreen.main.nativeBounds.size
        // Twice the iPad's own pixels, so zooming in stays sharp. The host caps it at the Mac's native size.
        let hello = Hello(clientName: UIDevice.current.name,
                          maxWidth: min(8192, Int(max(native.width, native.height)) * 2),
                          maxHeight: min(8192, Int(min(native.width, native.height)) * 2),
                          codecs: [.hevc, .h264], displayID: displayID, audio: audioEnabled, quality: quality)
        let c = FramedConnection(NWConnection(to: endpoint, using: PairingSecurity.parameters(code: code)), queue: queue)
        conn = c
        queue.async { self.hostError = nil }
        // The window size as it is when the Hello goes out: the view may still
        // have been laying out when this connect started.
        c.onReady = { [weak self, weak c] in
            var hello = hello
            hello.window = self?.windowRequest
            c?.send(.hello, json: hello)
        }
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
        let now = ProcessInfo.processInfo.systemUptime
        meterLock.lock()
        totalMeter.add(bytes: payload.count + Wire.headerSize, at: now)
        if type == .videoFrame { videoMeter.add(bytes: payload.count, at: now) }
        meterLock.unlock()
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
            guard let frame = FramePayload.parse(payload) else { return fail(type) }
            video?.videoFrame(frame.body, keyframe: frame.keyframe)
        case .cursor:
            guard let (x, y) = CursorPayload.decode(payload) else { return fail(type) }
            DispatchQueue.main.async { self.onCursor?(x, y) }
        case .clipboard:
            let text = String(decoding: payload, as: UTF8.self)
            DispatchQueue.main.async { UIPasteboard.general.string = text }
        case .clipboardImage:
            let png = payload
            DispatchQueue.main.async { UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier) }
        case .audio:
            guard let (_, samples) = AudioPayload.decode(payload) else { return fail(type) }
            player.enqueue(samples)
        case .error:
            hostError = String(decoding: payload, as: UTF8.self)
        case .hello, .input, .requestKeyframe, .selectDisplay, .audioEnabled, .setQuality, .setWindowMode, .switchWindow:
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
