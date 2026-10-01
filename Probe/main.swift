import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers
import VideoToolbox

// End-to-end check of a running host, from the client's side of the wire:
//   probe <host[:port]> <code> [out.png] [--h264] [--move] [--displays] [--clipboard] [--swipe] [--audio] [--keys]
// Connects over TLS-PSK, decodes video with VideoToolbox, writes a sharp frame
// as PNG, and prints PASS/FAIL for each optional check. Run it on the host Mac:
// the checks read the real cursor and pasteboard back.

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: probe <host[:port]> <code> [out.png] [--h264] [--move] [--displays] [--clipboard] [--swipe] [--audio] [--keys]"); exit(2) }
let hostPort = args[1].split(separator: ":")
let host = String(hostPort[0]), port = hostPort.count > 1 ? UInt16(hostPort[1])! : Wire.port
let code = args[2]
let outPath = args.count > 3 && !args[3].hasPrefix("--") ? args[3] : "probe.png"
let flags = Set(args.filter { $0.hasPrefix("--") })

let queue = DispatchQueue(label: "probe")
let nw = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                      using: PairingSecurity.parameters(code: code))
let conn = FramedConnection(nw, queue: queue)

var format: CMVideoFormatDescription?
var decoder: VTDecompressionSession?
var frames = 0, keyframes = 0, bytes = 0, decoded = 0, cursorReports = 0
var infos: [ScreenInfo] = []
var start = Date()
var wrote = false
var failures = 0
var clipboardReceived: [String] = []
var latencies: [Double] = []
var audioFrames = 0, audioPeak: Int16 = 0, audioLatency: [Double] = []
var audioFirst: Date?, audioLast: Date?
var arrivals: [Double] = []
var worst: [(ms: Double, index: Int, bytes: Int, key: Bool)] = []

func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(what)")
}

func writePNG(_ pb: CVPixelBuffer) {
    let ci = CIImage(cvPixelBuffer: pb)
    let cg = CIContext().createCGImage(ci, from: ci.extent)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(outPath) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))")
}

func after(_ t: Double, _ f: @escaping () -> Void) { queue.asyncAfter(deadline: .now() + t, execute: f) }

func runMoveChecks(_ info: ScreenInfo) {
    func at() -> CGPoint { CGEvent(source: nil)!.location }
    let b = CGDisplayBounds(info.displayID)
    after(0.3) {
        conn.send(.input, json: InputEvent.moveTo(x: 0.25, y: 0.5))
        after(0.4) {
            let want = CGPoint(x: b.minX + b.width * 0.25, y: b.minY + b.height * 0.5), got = at()
            check(abs(got.x - want.x) < 2 && abs(got.y - want.y) < 2, "moveTo(0.25, 0.5): expected \(want), cursor at \(got)")
            let before = got
            for _ in 0..<20 { conn.send(.input, json: InputEvent.moveBy(dx: 10, dy: 5)) }
            after(0.4) {
                let want = CGPoint(x: before.x + 200, y: before.y + 100), got = at()
                check(abs(got.x - want.x) < 2 && abs(got.y - want.y) < 2, "20 x moveBy(10, 5): expected \(want), cursor at \(got)")
            }
        }
    }
}

/// Really changes desktop and back, checking the active Space through SkyLight.
func runSwipeChecks(_ info: ScreenInfo) {
    let display = info.displayID
    guard let count = Spaces.count(on: display), let start = Spaces.activeIndex(on: display) else {
        return check(false, "swipe: can't read Spaces")
    }
    guard count > 1 else { return check(false, "swipe: needs at least 2 desktops on this display, has \(count)") }
    // Fingers left (negative) go to the next desktop; use the previous one if this is the last.
    let toward: Double = start + 1 < count ? -1 : 1
    func swipe(_ d: Double, then: @escaping () -> Void) {
        conn.send(.input, json: InputEvent.swipe(axis: .horizontal, phase: .began, distance: d * 0.05))
        for i in 2...20 {
            after(Double(i) * 0.012) { conn.send(.input, json: InputEvent.swipe(axis: .horizontal, phase: .changed, distance: d * Double(i) * 0.05)) }
        }
        after(0.3) { conn.send(.input, json: InputEvent.swipe(axis: .horizontal, phase: .ended, distance: d)) }
        after(1.4, then)
    }
    swipe(toward) {
        let moved = Spaces.activeIndex(on: display)
        check(moved == start + (toward < 0 ? 1 : -1), "swipe changed desktop: \(start) -> \(moved.map(String.init) ?? "?") of \(count)")
        swipe(-toward) {
            let back = Spaces.activeIndex(on: display)
            check(back == start, "swipe back returned to desktop \(start): at \(back.map(String.init) ?? "?")")
        }
    }
}

/// Everything on the pasteboard, every type of every item, so it can be put back exactly.
/// ⌥Tab and ⌥Space typed on an iPad keyboard, through the same KeyRemapper the
/// app uses, must work the Mac's app switcher and Spotlight.
var remapper = KeyRemapper()
/// Typed at human speed, 80ms between physical key events, as someone holding ⌥ would.
func physical(_ keys: (UInt16, Bool)...) {
    for (i, k) in keys.enumerated() {
        after(Double(i) * 0.08) {
            for out in remapper.handle(k.0, down: k.1) { conn.send(.input, json: InputEvent.key(code: out.code, down: out.down)) }
        }
    }
}
/// Asks LaunchServices directly. NSWorkspace.frontmostApplication never updates
/// in a process that isn't running an AppKit run loop, so it kept reporting the
/// app from launch and made a working ⌘Tab look broken (and a broken one pass).
func frontmost() -> String? {
    func run(_ args: [String]) -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        p.arguments = args
        p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let line = run(["info", "-only", "bundleID", run(["front"])]) // "CFBundleIdentifier"="com.example"
    return line.split(separator: "\"").dropFirst(2).first.map(String.init) // ["CFBundleIdentifier", "=", id]
}
func spotlightOpen() -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { ($0[kCGWindowOwnerName as String] as? String) == "Spotlight" && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }
}

func runKeyChecks() {
    let start = frontmost()
    physical((58, true), (48, true), (48, false), (58, false)) // ⌥Tab
    after(1.0) {
        let switched = frontmost()
        check(switched != nil && switched != start, "⌥Tab switched the Mac's app: \(start ?? "?") -> \(switched ?? "?")")
        physical((58, true), (48, true), (48, false), (58, false)) // and back
        after(1.0) {
            let back = frontmost()
            check(back != nil && back == start, "⌥Tab again returned to \(start ?? "?"): at \(back ?? "?")")
            let before = spotlightOpen()
            physical((58, true), (49, true), (49, false), (58, false)) // ⌥Space
            after(1.0) {
                check(!before && spotlightOpen(), "⌥Space opened Spotlight")
                physical((53, true), (53, false)) // Escape
                after(1.5) { check(!spotlightOpen(), "Escape closed it") }
            }
        }
    }
}

let savedClipboard: [[NSPasteboard.PasteboardType: Data]] = (NSPasteboard.general.pasteboardItems ?? []).map { item in
    Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
}
func restoreClipboard() {
    guard flags.contains("--clipboard") else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.writeObjects(savedClipboard.map { types in
        let item = NSPasteboardItem()
        for (t, d) in types { item.setData(d, forType: t) }
        return item
    })
}
var imagesReceived: [Data] = []

func testImage(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
    for i in 0..<(w * h * 4) { rep.bitmapData![i] = UInt8(i % 253) }
    return rep
}

func runClipboardChecks() {
    let token = "remotemac-probe-\(UUID().uuidString.prefix(8))"
    // iPad -> Mac
    conn.send(.clipboard, Data("\(token)-to-mac".utf8))
    after(0.5) {
        let got = DispatchQueue.main.sync { NSPasteboard.general.string(forType: .string) }
        check(got == "\(token)-to-mac", "clipboard to Mac: pasteboard has \(got.map { "\"\($0)\"" } ?? "nil")")
        // Mac -> iPad: the host must send this, and must not have echoed ours back.
        DispatchQueue.main.sync {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(token)-from-mac", forType: .string)
        }
        after(1.0) {
            check(clipboardReceived.last == "\(token)-from-mac", "clipboard from Mac: received \(clipboardReceived.last ?? "nothing")")
            check(!clipboardReceived.contains("\(token)-to-mac"), "clipboard not echoed back")
            // A concealed item (what password managers write) must not be sent.
            let n = clipboardReceived.count
            DispatchQueue.main.sync {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
                pb.setString("hunter2", forType: .string)
            }
            after(1.0) {
                check(clipboardReceived.count == n, "concealed clipboard item not sent")
                runImageClipboardChecks()
            }
        }
    }
}

func runImageClipboardChecks() {
    // iPad -> Mac: a PNG lands on the Mac pasteboard as PNG and TIFF.
    let png = testImage(64, 48).representation(using: .png, properties: [:])!
    conn.send(.clipboardImage, png)
    after(0.5) {
        let (gotPNG, tiffWidth) = DispatchQueue.main.sync {
            (NSPasteboard.general.data(forType: .png), NSPasteboard.general.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0)?.pixelsWide })
        }
        check(gotPNG == png && tiffWidth == 64, "clipboard image to Mac: PNG \(gotPNG == png ? "identical" : "missing"), TIFF width \(tiffWidth.map(String.init) ?? "missing")")
        // Mac -> iPad: a TIFF-only image (what many Mac apps write) arrives as PNG.
        DispatchQueue.main.sync {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(testImage(120, 90).tiffRepresentation!, forType: .tiff)
        }
        after(1.0) {
            let rep = imagesReceived.last.flatMap { NSBitmapImageRep(data: $0) }
            check(rep?.pixelsWide == 120 && rep?.pixelsHigh == 90, "clipboard image from Mac: \(rep.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "nothing")")
        }
    }
}

conn.onReady = {
    print("TLS ready")
    conn.send(.hello, json: Hello(clientName: "probe", maxWidth: 8192, maxHeight: 8192,
                                  codecs: flags.contains("--h264") ? [.h264] : [.hevc, .h264],
                                  audio: flags.contains("--audio")))
}
conn.onClose = { error in
    print("closed: \(error.map { "\($0)" } ?? "clean")")
    restoreClipboard()
    exit(1)
}
conn.onMessage = { type, payload in
    switch type {
    case .screenInfo:
        let info = try! JSONDecoder().decode(ScreenInfo.self, from: payload)
        infos.append(info)
        print("screenInfo \(info.displayName) \(info.codec) stream \(info.streamWidth)x\(info.streamHeight) screen \(info.screenWidth)x\(info.screenHeight) of \(info.displays.map(\.name))")
        if infos.count == 1 {
            start = Date()
            if flags.contains("--move") { runMoveChecks(info) }
            if flags.contains("--clipboard") { after(2.5, runClipboardChecks) }
            if flags.contains("--swipe") { after(0.5) { runSwipeChecks(info) } }
            if flags.contains("--keys") { after(0.5, runKeyChecks) }
            if flags.contains("--audio") {
                // Something for the Mac to play; the host must capture it.
                after(1.0) {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                    p.arguments = ["/System/Library/Sounds/Ping.aiff"]
                    try? p.run()
                }
            }
            if flags.contains("--displays") {
                // With one display, re-selecting it still exercises the restart path.
                let target = info.displays.first(where: { $0.id != info.displayID }) ?? info.displays[0]
                after(1.5) {
                    print("selecting \(target.name)")
                    conn.send(.selectDisplay, json: SelectDisplay(displayID: target.id))
                }
            }
        } else if flags.contains("--displays") {
            let expectSwitch = infos[0].displays.count > 1
            check(expectSwitch ? info.displayID != infos[0].displayID : true, "stream restarted on \(info.displayName)")
            let decodedBefore = decoded
            after(1.0) { check(decoded > decodedBefore, "frames decoding after switch (\(decoded - decodedBefore))") }
        }
    case .videoFormat:
        guard let (codec, sets) = VideoFormatPayload.decode(payload),
              let f = VideoFormat.description(codec: codec, parameterSets: sets) else {
            print("FAIL bad videoFormat"); exit(1)
        }
        let dims = CMVideoFormatDescriptionGetDimensions(f)
        if format == nil || !CMFormatDescriptionEqual(format!, otherFormatDescription: f) {
            print("videoFormat \(codec) \(sets.count) parameter sets \(dims.width)x\(dims.height)")
            if let decoder { VTDecompressionSessionInvalidate(decoder) }
            decoder = nil
            VTDecompressionSessionCreate(allocator: nil, formatDescription: f, decoderSpecification: nil,
                                         imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &decoder)
        }
        format = f
    case .videoFrame:
        frames += 1; bytes += payload.count
        if FramePayload.parse(payload)?.keyframe == true { keyframes += 1 }
        guard let frame = FramePayload.parse(payload) else { print("FAIL bad frame payload"); exit(1) }
        let arrived = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1e9)
        if !frame.refresh, frame.captureNanos > 0, arrived > frame.captureNanos { arrivals.append(Double(arrived - frame.captureNanos) / 1e6) }
        guard let format, let decoder,
              let sb = VideoFormat.sampleBuffer(frame.body, format: format, displayImmediately: false) else {
            print("frame \(frames): no decoder yet"); return
        }
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let image else { print("decode error \(status)"); return }
            decoded += 1
            let now = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1e9)
            if !frame.refresh, frame.captureNanos > 0, now > frame.captureNanos {
                let ms = Double(now - frame.captureNanos) / 1e6
                latencies.append(ms)
                worst.append((ms, frames, payload.count, frame.keyframe))
            }
            // The refine passes land ~0.6s after the last change; wait for one of them.
            // Encoding a 5120-wide PNG takes ~230ms; doing it here stalled decoding
            // and showed up as a fake latency spike in the numbers below.
            if !wrote && Date().timeIntervalSince(start) > 1.2 { wrote = true; DispatchQueue.global().async { writePNG(image) } }
        }
        if status != noErr { print("decode submit error \(status)") }
    case .cursor:
        guard CursorPayload.decode(payload) != nil else { print("FAIL bad cursor payload"); exit(1) }
        cursorReports += 1
    case .audio:
        guard let (t, samples) = AudioPayload.decode(payload) else { print("FAIL bad audio payload"); exit(1) }
        let now = Date()
        audioFirst = audioFirst ?? now
        audioLast = now
        audioFrames += samples.count / 2
        audioPeak = max(audioPeak, samples.map { $0 == .min ? .max : abs($0) }.max() ?? 0)
        let arrived = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1e9)
        if t > 0, arrived > t { audioLatency.append(Double(arrived - t) / 1e6) }
    case .clipboardImage:
        imagesReceived.append(payload)
    case .clipboard:
        clipboardReceived.append(String(decoding: payload, as: UTF8.self))
    case .error:
        print("host error: \(String(decoding: payload, as: UTF8.self))")
    default:
        print("unexpected \(type)")
    }
}
conn.start()

let duration = flags.contains("--clipboard") ? 8.5 : flags.contains("--keys") ? 8.5 : flags.contains("--swipe") || flags.contains("--audio") ? 6.5 : 4.5
DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
    let secs = Date().timeIntervalSince(start)
    print(String(format: "%d frames (%d key), %d decoded, %.1f KB avg, %.2f Mbit/s over %.1fs, %d cursor reports",
                 frames, keyframes, decoded, Double(bytes) / Double(max(frames, 1)) / 1024, Double(bytes) * 8 / secs / 1e6, secs, cursorReports))
    check(frames > 0 && decoded >= frames - 2, "video decodes")
    if flags.contains("--audio") {
        let secs = max(0.001, (audioLast ?? Date()).timeIntervalSince(audioFirst ?? Date()))
        let rate = Double(audioFrames) / secs
        check(abs(rate - 48_000) < 48_000 * 0.15, String(format: "audio arrives at %.0f frames/s (48000 expected)", rate))
        check(audioPeak > 1600, "the ping was heard: peak \(audioPeak) of 32767")
        if !audioLatency.isEmpty {
            let l = audioLatency.sorted()
            print(String(format: "audio capture-to-arrival: p50 %.1fms  p95 %.1fms", l[l.count / 2], l[min(l.count - 1, Int(Double(l.count) * 0.95))]))
        }
    }
    if !latencies.isEmpty {
        let l = latencies.sorted()
        func pct(_ p: Double) -> Double { l[min(l.count - 1, Int(Double(l.count) * p))] }
        print(String(format: "capture-to-decoded latency: p50 %.1fms  p95 %.1fms  max %.1fms  (n=%d, excludes Wi-Fi)", pct(0.5), pct(0.95), l.last!, l.count))
        // Generous: this Mac measures 13-19ms. A regression to a queue building up shows as 100+.
        // A second capture+encode pipeline on the Mac (an iPad on the installed host) puts this
        // at ~125ms for the second stream, so test.sh passes --no-latency-check then, and says so.
        if !flags.contains("--no-latency-check") {
            check(pct(0.5) < 50, String(format: "median latency %.1fms under 50ms", pct(0.5)))
        }
        if !arrivals.isEmpty {
            let a = arrivals.sorted()
            print(String(format: "  of which capture-to-arrival: p50 %.1fms  p95 %.1fms (encode + TLS + socket)", a[a.count / 2], a[min(a.count - 1, Int(Double(a.count) * 0.95))]))
        }
        if flags.contains("--latency") {
            for w in worst.sorted(by: { $0.ms > $1.ms }).prefix(12) {
                print(String(format: "  frame #%d  %.1fms  %d KB%@", w.index, w.ms, w.bytes / 1024, w.key ? "  keyframe" : ""))
            }
        }
    }
    restoreClipboard()
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
