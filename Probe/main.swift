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
//   probe <host[:port]> <code> [out.png] [--h264] [--move] [--displays] [--clipboard]
// Connects over TLS-PSK, decodes video with VideoToolbox, writes a sharp frame
// as PNG, and prints PASS/FAIL for each optional check. Run it on the host Mac:
// the checks read the real cursor and pasteboard back.

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: probe <host[:port]> <code> [out.png] [--h264] [--move] [--displays] [--clipboard]"); exit(2) }
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

let savedClipboard = NSPasteboard.general.string(forType: .string)
func restoreClipboard() {
    guard flags.contains("--clipboard") else { return }
    NSPasteboard.general.clearContents()
    if let savedClipboard { NSPasteboard.general.setString(savedClipboard, forType: .string) }
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
            after(1.0) { check(clipboardReceived.count == n, "concealed clipboard item not sent") }
        }
    }
}

conn.onReady = {
    print("TLS ready")
    conn.send(.hello, json: Hello(clientName: "probe", maxWidth: 8192, maxHeight: 8192,
                                  codecs: flags.contains("--h264") ? [.h264] : [.hevc, .h264]))
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
    case .clipboard:
        clipboardReceived.append(String(decoding: payload, as: UTF8.self))
    case .error:
        print("host error: \(String(decoding: payload, as: UTF8.self))")
    default:
        print("unexpected \(type)")
    }
}
conn.start()

let duration = flags.contains("--clipboard") ? 6.5 : 4.5
DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
    let secs = Date().timeIntervalSince(start)
    print(String(format: "%d frames (%d key), %d decoded, %.1f KB avg, %.2f Mbit/s over %.1fs, %d cursor reports",
                 frames, keyframes, decoded, Double(bytes) / Double(max(frames, 1)) / 1024, Double(bytes) * 8 / secs / 1e6, secs, cursorReports))
    check(frames > 0 && decoded >= frames - 2, "video decodes")
    if !latencies.isEmpty {
        let l = latencies.sorted()
        func pct(_ p: Double) -> Double { l[min(l.count - 1, Int(Double(l.count) * p))] }
        print(String(format: "capture-to-decoded latency: p50 %.1fms  p95 %.1fms  max %.1fms  (n=%d, excludes Wi-Fi)", pct(0.5), pct(0.95), l.last!, l.count))
        // Generous: this Mac measures ~19ms. A regression to a queue building up shows as 100+.
        check(pct(0.5) < 50, String(format: "median latency %.1fms under 50ms", pct(0.5)))
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
