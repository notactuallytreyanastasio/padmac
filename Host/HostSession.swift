import AppKit
import CoreGraphics
import Foundation
import Network

/// One connected iPad: streams a display out, applies its input, reports the
/// cursor, and keeps the clipboards in step.
final class HostSession {
    let peer: String
    private let conn: FramedConnection
    private let queue = DispatchQueue(label: "remotemac.session", qos: .userInteractive)
    private var hello: Hello?
    private var streamer: ScreenStreamer?
    private var generation = 0
    private let injector = InputInjector(displayID: CGMainDisplayID())
    private var cursorTimer: DispatchSourceTimer?
    private var lastCursor: (Float, Float)?
    private var clipboard: ClipboardWatcher?
    private var screenObserver: NSObjectProtocol?
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
        generation += 1
        cursorTimer?.cancel()
        injector.releaseAll()
        let clipboard = self.clipboard, observer = screenObserver
        DispatchQueue.main.async {
            clipboard?.stop()
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    private func handle(_ type: MessageType, _ payload: Data) {
        switch type {
        case .hello:
            guard hello == nil, let h = try? decoder.decode(Hello.self, from: payload) else { return fail(.badPayload(type)) }
            hello = h
            onStatus?("Connected: \(h.clientName)")
            startStream(on: h.displayID)
            startCursorReports()
            startClipboard()
            watchDisplayChanges()
        case .input:
            guard let event = try? decoder.decode(InputEvent.self, from: payload) else { return fail(.badPayload(type)) }
            injector.handle(event)
        case .requestKeyframe:
            streamer?.requestKeyframe()
        case .selectDisplay:
            guard let s = try? decoder.decode(SelectDisplay.self, from: payload) else { return fail(.badPayload(type)) }
            startStream(on: s.displayID)
        case .clipboard:
            let text = String(decoding: payload, as: UTF8.self)
            DispatchQueue.main.async { self.clipboard?.set(text) }
        case .screenInfo, .videoFormat, .videoFrame, .error, .cursor:
            fail(.badPayload(type))
        }
    }

    private func fail(_ error: ProtocolError) {
        NSLog("RemoteMac: \(peer): \(error.localizedDescription)")
        conn.cancel()
    }

    /// (Re)start capture of a display. Also used when the display's mode changes,
    /// since SCStream keeps delivering the old size, scaled, after a resolution switch.
    private func startStream(on displayID: UInt32?) {
        guard let hello else { return }
        streamer?.stop()
        generation += 1
        let gen = generation
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
        Task {
            do {
                let info = try await streamer.start(displayID: displayID, maxWidth: hello.maxWidth, maxHeight: hello.maxHeight,
                                                    codecs: hello.codecs ?? [.h264])
                queue.async {
                    guard gen == self.generation else { return streamer.stop() }
                    self.injector.displayID = streamer.displayID
                    self.lastCursor = nil
                    conn.send(.screenInfo, json: info)
                    streamer.requestKeyframe()
                }
            } catch {
                queue.async {
                    guard gen == self.generation else { return }
                    NSLog("RemoteMac: capture failed: \(error)")
                    let why = CGPreflightScreenCaptureAccess()
                        ? "Screen capture failed: \(error.localizedDescription)"
                        : "This Mac has not given Remote Mac Host Screen Recording permission. Grant it from the host's menu bar icon, then reopen the host."
                    self.onStatus?(why)
                    conn.send(.error, Data(why.utf8))
                    // Let the message flush before hanging up.
                    self.queue.asyncAfter(deadline: .now() + 0.5) { conn.cancel() }
                }
            }
        }
    }

    /// The client needs the cursor position to keep it in view when zoomed.
    private func startCursorReports() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(16))
        t.setEventHandler { [weak self] in
            guard let self, self.streamer != nil, let p = CGEvent(source: nil)?.location else { return }
            let b = CGDisplayBounds(self.injector.displayID)
            guard b.contains(p) else { return }
            let now = (Float((p.x - b.minX) / b.width), Float((p.y - b.minY) / b.height))
            if let last = self.lastCursor, last == now { return }
            self.lastCursor = now
            self.conn.send(.cursor, CursorPayload.encode(x: now.0, y: now.1))
        }
        t.resume()
        cursorTimer = t
    }

    private func startClipboard() {
        let conn = self.conn
        DispatchQueue.main.async {
            let w = ClipboardWatcher { text in conn.send(.clipboard, Data(text.utf8)) }
            self.queue.async { self.clipboard = w }
            w.start()
        }
    }

    private func watchDisplayChanges() {
        DispatchQueue.main.async {
            self.screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.asyncAfter(deadline: .now() + 0.5) {
                    guard let s = self.streamer else { return }
                    NSLog("RemoteMac: display configuration changed; restarting capture")
                    self.startStream(on: s.displayID)
                }
            }
        }
    }
}

/// Sends the Mac's clipboard text to the iPad when it changes, and applies the iPad's.
/// Main thread only.
final class ClipboardWatcher {
    private let send: (String) -> Void
    private var timer: Timer?
    private var seen = NSPasteboard.general.changeCount - 1 // send what's there on connect

    init(send: @escaping (String) -> Void) { self.send = send }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func stop() { timer?.invalidate() }

    func set(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        seen = pb.changeCount // don't echo it back
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != seen else { return }
        seen = pb.changeCount
        // Password managers mark secrets; those stay on the Mac.
        let skip: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        guard !(pb.types ?? []).contains(where: { skip.contains($0.rawValue) }),
              let text = pb.string(forType: .string), !text.isEmpty, text.utf8.count < 1 << 20 else { return }
        send(text)
    }
}
