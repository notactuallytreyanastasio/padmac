import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers
import VideoToolbox

// End-to-end check of a running host, from the client's side of the wire:
//   probe <host> <code> [out.png] [--move]
// Connects over TLS-PSK, decodes video with VideoToolbox, writes the first
// sharp frame as a PNG and prints throughput. --move nudges the cursor.

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: probe <host> <code> [out.png] [--move]"); exit(2) }
let host = args[1], code = args[2]
let outPath = args.count > 3 && !args[3].hasPrefix("--") ? args[3] : "probe.png"
let doMove = args.contains("--move")

let queue = DispatchQueue(label: "probe")
let nw = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Wire.port)!,
                      using: PairingSecurity.parameters(code: code))
let conn = FramedConnection(nw, queue: queue)

var format: CMVideoFormatDescription?
var decoder: VTDecompressionSession?
var frames = 0, keyframes = 0, bytes = 0
var decoded = 0
var start = Date()
var wrote = false

func writePNG(_ pb: CVPixelBuffer) {
    let ci = CIImage(cvPixelBuffer: pb)
    let cg = CIContext().createCGImage(ci, from: ci.extent)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(outPath) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))")
}

conn.onReady = {
    print("TLS ready")
    conn.send(.hello, json: Hello(clientName: "probe", maxWidth: 1920, maxHeight: 1200))
}
conn.onClose = { error in
    print("closed: \(error.map { "\($0)" } ?? "clean")")
    exit(error == nil && frames > 0 ? 0 : 1)
}
conn.onMessage = { type, payload in
    switch type {
    case .screenInfo:
        let info = try! JSONDecoder().decode(ScreenInfo.self, from: payload)
        print("screenInfo \(info)")
        start = Date()
        if doMove {
            // Absolute, then relative; read the real cursor back after each step.
            func at() -> CGPoint { CGEvent(source: nil)!.location }
            let steps: [(String, [InputEvent], (CGPoint) -> CGPoint)] = [
                ("moveTo(0.25, 0.5)", [.moveTo(x: 0.25, y: 0.5)], { _ in CGPoint(x: info.screenWidth * 0.25, y: info.screenHeight * 0.5) }),
                ("20 x moveBy(10, 5)", Array(repeating: .moveBy(dx: 10, dy: 5), count: 20), { CGPoint(x: $0.x + 200, y: $0.y + 100) }),
            ]
            var t = 0.3
            for (name, events, expect) in steps {
                queue.asyncAfter(deadline: .now() + t) {
                    let before = at()
                    for e in events { conn.send(.input, json: e) }
                    queue.asyncAfter(deadline: .now() + 0.4) {
                        let want = expect(before), got = at()
                        let ok = abs(got.x - want.x) < 2 && abs(got.y - want.y) < 2
                        print("\(ok ? "PASS" : "FAIL") \(name): expected \(want), cursor at \(got)")
                    }
                }
                t += 0.8
            }
        }
    case .videoFormat:
        let (sps, pps) = VideoFormatPayload.decode(payload)!
        format = H264.formatDescription(sps: sps, pps: pps)
        let dims = CMVideoFormatDescriptionGetDimensions(format!)
        print("videoFormat sps=\(sps.count)B pps=\(pps.count)B \(dims.width)x\(dims.height)")
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil
        VTDecompressionSessionCreate(allocator: nil, formatDescription: format!, decoderSpecification: nil,
                                     imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &decoder)
    case .videoFrame:
        frames += 1; bytes += payload.count
        if payload[payload.startIndex] & 1 == 1 { keyframes += 1 }
        guard let format, let decoder,
              let sb = H264.sampleBuffer(avcc: payload.dropFirst(), format: format, displayImmediately: false) else {
            print("frame \(frames): no decoder yet"); return
        }
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let image else { print("decode error \(status)"); return }
            decoded += 1
            // The refine passes land ~0.6s after the last change; wait for one of them.
            if !wrote && Date().timeIntervalSince(start) > 1.2 { wrote = true; writePNG(image) }
        }
        if status != noErr { print("decode submit error \(status)") }
    case .error:
        print("host error: \(String(decoding: payload, as: UTF8.self))")
    default:
        print("unexpected \(type)")
    }
}
conn.start()

DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
    let secs = Date().timeIntervalSince(start)
    print(String(format: "%d frames (%d key), %d decoded, %.1f KB avg, %.2f Mbit/s over %.1fs",
                 frames, keyframes, decoded, Double(bytes) / Double(max(frames, 1)) / 1024, Double(bytes) * 8 / secs / 1e6, secs))
    exit(frames > 0 && decoded == frames ? 0 : 1)
}
dispatchMain()
