import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Network

/// One connected iPad: streams a display out, applies its input, reports the
/// cursor, and keeps the clipboards in step.
final class HostSession {
    let peer: String
    private let conn: FramedConnection
    private let queue = DispatchQueue(label: "remotemac.session", qos: .userInteractive)
    private var hello: Hello?
    private var quality = StreamQuality.full
    private var streamer: ScreenStreamer?
    private var generation = 0
    private let injector: InputInjector
    private let inputLog: FileHandle?
    private var cursorTimer: DispatchSourceTimer?
    private var lastCursor: (Float, Float)?
    private var clipboard: ClipboardWatcher?
    private var screenObserver: NSObjectProtocol?
    private var awake: PowerAssertion?
    private let audioOn = AtomicFlag()
    private let decoder = JSONDecoder()
    /// Window mode, and the size the client wants the window. Nil: the whole display.
    private var windowRequest: WindowRequest?
    private var ring = WindowRing()
    private var shown: MacWindow?
    /// Where each window we resized was, to put it back when the session ends.
    private var originals: [CGWindowID: (pid: pid_t, frame: CGRect)] = [:]
    private var windowTimer: DispatchSourceTimer?
    private var lastPolledFrame: CGRect?
    private var starting = false
    private var windowRetries = 0
    private let dryRunWindows = UserDefaults.standard.bool(forKey: "dryRunWindows")
    private var focusTimer: DispatchSourceTimer?
    private var lastTextFocus: Bool?

    var onStatus: ((String) -> Void)?
    var onEnd: ((HostSession, Error?) -> Void)?
    /// The TLS handshake succeeded: this peer knows the pairing code.
    var onAuthenticated: ((HostSession) -> Void)?

    init(connection: NWConnection) {
        peer = connection.endpoint.debugDescription
        conn = FramedConnection(connection, queue: queue)
        // Development flags, for UI tests that must not move the real cursor:
        //   -dryRunInput YES   track input state but post nothing
        //   -inputLog <path>   append every received InputEvent as a JSON line
        //   -dryRunWindows YES window mode lists and switches windows but never raises or resizes them
        let d = UserDefaults.standard
        var system = InputInjector.System.live
        if d.bool(forKey: "dryRunInput") { system.post = { _ in }; system.postGesture = { _ in } }
        injector = InputInjector(displayID: CGMainDisplayID(), system: system)
        inputLog = d.string(forKey: "inputLog").flatMap { path in
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            let h = FileHandle(forWritingAtPath: path)
            h?.seekToEndOfFile()
            return h
        }
    }

    func start() {
        conn.onMessage = { [weak self] type, payload in self?.handle(type, payload) }
        conn.onDrain = { [weak self] in self?.streamer?.drained() }
        conn.onReady = { [weak self] in
            guard let self else { return }
            self.onAuthenticated?(self)
            // Past the TLS handshake, so this is a paired iPad: wake the display and keep it on.
            self.awake = PowerAssertion(reason: "Remote Mac: iPad connected")
        }
        conn.onClose = { [weak self] error in
            guard let self else { return }
            self.teardown()
            self.onEnd?(self, error)
        }
        conn.start()
    }

    func stop() { conn.cancel() }

    /// Another device connected. Say so before hanging up: the iPad treats a
    /// reason from the host as final, where a bare disconnect makes it
    /// reconnect, and two iPads would then take turns knocking each other off.
    func supersede(by peer: String) {
        let conn = self.conn
        queue.async {
            conn.send(.error, Data("Another device connected to this Mac (\(peer)).".utf8))
            self.queue.asyncAfter(deadline: .now() + 0.3) { conn.cancel() }
        }
    }

    private func teardown() {
        awake = nil
        streamer?.stop()
        streamer = nil
        generation += 1
        cursorTimer?.cancel()
        windowTimer?.cancel()
        focusTimer?.cancel()
        injector.releaseAll()
        restoreWindows()
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
            audioOn.value = h.audio == true
            quality = h.quality ?? .full
            windowRequest = h.window
            onStatus?("Connected: \(h.clientName)")
            startStream(on: h.displayID)
            startCursorReports()
            startWindowWatch()
            startFocusWatch()
            startClipboard()
            watchDisplayChanges()
        case .input:
            guard let event = try? decoder.decode(InputEvent.self, from: payload) else { return fail(.badPayload(type)) }
            if let inputLog { inputLog.write(payload + Data("\n".utf8)) }
            injector.handle(event)
        case .requestKeyframe:
            streamer?.requestKeyframe()
        case .selectDisplay:
            guard let s = try? decoder.decode(SelectDisplay.self, from: payload) else { return fail(.badPayload(type)) }
            startStream(on: s.displayID)
        case .setQuality:
            guard let q = try? decoder.decode(StreamQuality.self, from: payload) else { return fail(.badPayload(type)) }
            guard q != quality else { return }
            quality = q
            if let s = streamer { startStream(on: s.displayID) }
        case .setWindowMode:
            guard let m = try? decoder.decode(WindowModeChange.self, from: payload) else { return fail(.badPayload(type)) }
            let was = windowRequest
            windowRequest = m.window
            guard hello != nil, m.window != was else { return }
            if m.window == nil {
                restoreWindows()
                shown = nil
            }
            startStream(on: streamer?.displayID)
        case .switchWindow:
            guard let sw = try? decoder.decode(SwitchWindow.self, from: payload), windowRequest != nil else { return fail(.badPayload(type)) }
            startStream(on: streamer?.displayID, choice: sw.windowID.map { .id($0) } ?? .step(sw.step ?? 0))
        case .audioEnabled:
            guard payload.count == 1 else { return fail(.badPayload(type)) }
            audioOn.value = payload.first == 1
        case .clipboard:
            let text = String(decoding: payload, as: UTF8.self)
            // Synchronously: the iPad's paste button sends ⌘V right behind this.
            DispatchQueue.main.sync { self.clipboard?.set(.text(text)) }
        case .clipboardImage:
            // Synchronously, for the same reason as text.
            DispatchQueue.main.sync { self.clipboard?.set(.image(payload)) }
        case .screenInfo, .videoFormat, .videoFrame, .error, .cursor, .audio, .textFocus:
            fail(.badPayload(type))
        }
    }

    private func fail(_ error: ProtocolError) {
        NSLog("RemoteMac: \(peer): \(error.localizedDescription)")
        conn.cancel()
    }

    /// (Re)start capture of a display. Also used when the display's mode changes,
    /// since SCStream keeps delivering the old size, scaled, after a resolution switch.
    private func startStream(on displayID: UInt32?, choice: WindowChoice = .keep(resize: true)) {
        guard let hello else { return }
        streamer?.stop()
        generation += 1
        starting = true
        let gen = generation
        let request = windowRequest, ring = self.ring, current = shown?.id, touch = !dryRunWindows
        let conn = self.conn
        let streamer = ScreenStreamer(output: .init(
            canSend: { conn.canSendVideo },
            format: { conn.send(.videoFormat, $0) },
            frame: { conn.send(.videoFrame, $0) },
            audio: { [audioOn] in if audioOn.value { conn.send(.audio, $0) } },
            stopped: { error in
                NSLog("RemoteMac: capture stopped: \(error?.localizedDescription ?? "-")")
                conn.cancel()
            }))
        self.streamer = streamer
        Task {
            do {
                var chosen: Picked?
                if let request { chosen = await Self.pick(choice, current: current, ring: ring, size: request, touch: touch) }
                var info = try await streamer.start(displayID: displayID, window: chosen?.window,
                                                    maxWidth: hello.maxWidth, maxHeight: hello.maxHeight,
                                                    codecs: hello.codecs ?? [.h264], audio: hello.audio == true,
                                                    quality: quality)
                queue.async {
                    guard gen == self.generation else { return streamer.stop() }
                    self.starting = false
                    self.windowRetries = 0
                    self.injector.displayID = streamer.displayID
                    self.injector.region = chosen?.window?.frame
                    self.shown = chosen?.window
                    self.lastPolledFrame = chosen?.window?.frame
                    if let chosen {
                        self.ring = chosen.ring
                        if let o = chosen.original, self.originals[o.id] == nil { self.originals[o.id] = (o.pid, o.frame) }
                        info.windows = chosen.windows
                    }
                    self.lastCursor = nil
                    conn.send(.screenInfo, json: info)
                    streamer.requestKeyframe()
                }
            } catch StreamerError.noWindow(let id) {
                // Closed between being listed and being captured: show another.
                queue.async {
                    guard gen == self.generation else { return }
                    self.windowRetries += 1
                    NSLog("RemoteMac: window \(id) went away before capture started (attempt \(self.windowRetries))")
                    guard self.windowRetries <= 3 else { return self.giveUp("Window \(id) kept disappearing before it could be captured.") }
                    self.shown = nil
                    self.startStream(on: displayID)
                }
            } catch {
                queue.async {
                    guard gen == self.generation else { return }
                    NSLog("RemoteMac: capture failed: \(error)")
                    self.giveUp(CGPreflightScreenCaptureAccess()
                        ? "Screen capture failed: \(error.localizedDescription)"
                        : "This Mac has not given Remote Mac Host Screen Recording permission. Grant it from the host's menu bar icon, then reopen the host.")
                }
            }
        }
    }

    /// Tell the client why, which it treats as final, and hang up.
    private func giveUp(_ why: String) {
        onStatus?(why)
        conn.send(.error, Data(why.utf8))
        // Let the message flush before hanging up.
        queue.asyncAfter(deadline: .now() + 0.5) { [conn] in conn.cancel() }
    }

    // MARK: Window mode

    enum WindowChoice {
        /// The window already shown, or the frontmost if it is gone. `resize`
        /// false when it moved or resized on the Mac: follow it, don't fight it.
        case keep(resize: Bool)
        /// Along the swipe order.
        case step(Int)
        case id(CGWindowID)
    }

    struct Picked {
        var window: MacWindow?
        var ring: WindowRing
        /// In swipe order.
        var windows: [WindowInfo]
        var original: (id: CGWindowID, pid: pid_t, frame: CGRect)?
    }

    /// Lists the windows, picks one, raises it and resizes it to `size`
    /// (unless `touch` is false). AX round trips to other apps: off the session queue.
    static func pick(_ choice: WindowChoice, current: CGWindowID?, ring: WindowRing, size: WindowRequest, touch: Bool = true) async -> Picked {
        let list = WindowList.switchable()
        var ring = ring
        ring.update(list.map(\.id))
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let windows = ring.order.compactMap { byID[$0]?.info }
        let still = current.flatMap { byID[$0] == nil ? nil : $0 }
        let id: CGWindowID?
        var resize = touch
        switch choice {
        case .keep(let r):
            id = still ?? list.first?.id
            resize = touch && (r || still == nil)
        case .step(let n): id = ring.step(from: current, by: n)
        case .id(let wanted): id = byID[wanted] != nil ? wanted : still ?? list.first?.id
        }
        guard let id, var w = byID[id] else { return Picked(window: nil, ring: ring, windows: windows) }

        var original: (CGWindowID, pid_t, CGRect)?
        if let el = AXWindow.element(pid: w.pid, id: id) {
            if resize {
                AXWindow.raise(el, pid: w.pid)
                let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
                if AXWindow.resizable(el), let visible = await MainActor.run(body: { WindowList.visibleFrame(at: center) }),
                   let before = AXWindow.frame(el) {
                    original = (id, w.pid, before)
                    let target = WindowFit.place(CGSize(width: size.width, height: size.height), from: before, in: visible)
                    let got = AXWindow.setFrame(el, target, pid: w.pid)
                    if got?.size != target.size {
                        NSLog("RemoteMac: \(w.app) window \(id) asked for \(target.size), took \(got.map { "\($0.size)" } ?? "nothing")")
                    }
                    // The window server, which capture reads, applies it a moment after the app does.
                    try? await Task.sleep(nanoseconds: 60_000_000)
                } else {
                    NSLog("RemoteMac: \(w.app) window \(id) can't be resized (full screen or fixed size); showing it as it is")
                }
            }
        } else {
            NSLog("RemoteMac: \(w.app) window \(id) has no Accessibility element; showing it as it is")
        }
        w.frame = WindowList.frame(of: id) ?? w.frame
        let info = w.info
        return Picked(window: w, ring: ring, windows: windows.map { $0.id == id ? info : $0 }, original: original)
    }

    /// Follows the shown window: if it closes, shows another; if it moves or
    /// is resized on the Mac, restarts capture on its new frame once it holds still.
    private func startWindowWatch() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in
            guard let self, self.windowRequest != nil, !self.starting, let s = self.streamer, let shown = self.shown else { return }
            guard let now = WindowList.frame(of: shown.id) else {
                NSLog("RemoteMac: \(shown.app) window \(shown.id) closed or left the desktop; showing another")
                self.shown = nil
                return self.startStream(on: s.displayID)
            }
            defer { self.lastPolledFrame = now }
            if now != shown.frame && now == self.lastPolledFrame {
                self.startStream(on: s.displayID, choice: .keep(resize: false))
            }
        }
        t.resume()
        windowTimer = t
    }

    /// Tells the client when keyboard focus moves into or out of a text input,
    /// so it can bring up its keyboard. Polled: AX focus notifications need an
    /// observer per app, and the frontmost app changes. AX round trips, so on
    /// its own queue, not the session's.
    private func startFocusWatch() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "remotemac.focus", qos: .utility))
        t.schedule(deadline: .now() + 0.3, repeating: .milliseconds(300))
        let conn = self.conn
        t.setEventHandler { [weak self] in
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            let now = AXWindow.focusIsText(pid: pid)
            self?.queue.async {
                guard let self, now != self.lastTextFocus else { return }
                self.lastTextFocus = now
                conn.send(.textFocus, Data([now ? 1 : 0]))
            }
        }
        t.resume()
        focusTimer = t
    }

    /// Puts every window this session resized back where it was.
    private func restoreWindows() {
        let o = originals
        originals = [:]
        injector.region = nil
        guard !o.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for (id, v) in o {
                if let el = AXWindow.element(pid: v.pid, id: id) { AXWindow.setFrame(el, v.frame, pid: v.pid) }
            }
        }
    }

    /// The client needs the cursor position to keep it in view when zoomed.
    private func startCursorReports() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(16))
        t.setEventHandler { [weak self] in
            guard let self, self.streamer != nil, let p = CGEvent(source: nil)?.location else { return }
            let b = self.injector.region ?? CGDisplayBounds(self.injector.displayID)
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
            let w = ClipboardWatcher { clip in
                switch clip {
                case .text(let text): conn.send(.clipboard, Data(text.utf8))
                case .image(let png): conn.send(.clipboardImage, png)
                }
            }
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

/// Sends the Mac's clipboard to the iPad when it changes, and applies the iPad's.
/// Main thread only. Takes the pasteboard as a parameter so tests can use a private one.
final class ClipboardWatcher {
    enum Clip: Equatable {
        case text(String)
        /// PNG data.
        case image(Data)
    }

    static let maxImageBytes = 16 << 20
    static let maxTextBytes = 1 << 20

    private let pasteboard: NSPasteboard
    private let send: (Clip) -> Void
    private var timer: Timer?
    private var seen: Int
    /// The last clip that crossed the wire, either way. With Universal Clipboard
    /// on, text the iPad receives comes back to the Mac's pasteboard a moment
    /// later as a "new" copy. Without this the host would send it again,
    /// iOS would sync it back again, and so on.
    private var lastExchanged: Clip?

    init(pasteboard: NSPasteboard = .general, send: @escaping (Clip) -> Void) {
        self.pasteboard = pasteboard
        self.send = send
        seen = pasteboard.changeCount - 1 // send what's there on connect
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func stop() { timer?.invalidate() }

    func set(_ clip: Clip) {
        lastExchanged = clip
        pasteboard.clearContents()
        switch clip {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        case .image(let png):
            // Mac apps differ in which they read, so offer both.
            pasteboard.declareTypes([.png, .tiff], owner: nil)
            pasteboard.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        }
        seen = pasteboard.changeCount // don't echo it back
    }

    /// Checks for a change now. The timer calls this twice a second.
    func poll() {
        guard pasteboard.changeCount != seen else { return }
        seen = pasteboard.changeCount
        guard let clip = current(), clip != lastExchanged else { return }
        lastExchanged = clip
        send(clip)
    }

    /// An image wins over text: copying an image usually also puts its URL or
    /// file name on the pasteboard, and the image is what was meant.
    private func current() -> Clip? {
        let types = pasteboard.types ?? []
        // Password managers mark secrets; those stay on the Mac.
        let secret: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        if types.contains(where: { secret.contains($0.rawValue) }) { return nil }

        if let png = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap(Self.png(fromTIFF:)) {
            guard png.count <= Self.maxImageBytes else {
                NSLog("RemoteMac: clipboard image of \(png.count) bytes is over the \(Self.maxImageBytes)-byte limit; not sent")
                return nil
            }
            return .image(png)
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty, text.utf8.count <= Self.maxTextBytes {
            return .text(text)
        }
        return nil
    }

    private static func png(fromTIFF tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}

/// Wakes the display and holds it awake for as long as the object lives.
/// Without this the Mac's idle timer blanks the screen mid-session, because
/// synthesized input doesn't always count as user activity.
final class PowerAssertion {
    private var noSleep: IOPMAssertionID = 0
    private var activity: IOPMAssertionID = 0
    let held: Bool

    init(reason: String) {
        IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &activity)
        held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &noSleep) == kIOReturnSuccess
    }

    deinit {
        if held { IOPMAssertionRelease(noSleep) }
        if activity != 0 { IOPMAssertionRelease(activity) }
    }
}

/// A Bool shared between the session queue and the audio queue.
final class AtomicFlag {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
