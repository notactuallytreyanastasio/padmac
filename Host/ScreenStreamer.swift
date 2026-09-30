import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// Captures one display with ScreenCaptureKit and feeds it to a VideoEncoder.
///
/// ScreenCaptureKit only delivers a frame when something on screen changed, so
/// an idle desktop produces no video at all. Two consequences are handled here:
/// the most recent frame is kept so a keyframe can be produced on demand, and
/// after motion stops the last frame is re-encoded a couple of times so the
/// encoder can sharpen text that was smeared while it was moving.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Output {
        var canSend: () -> Bool
        var format: (Data) -> Void
        var frame: (Data) -> Void
        var stopped: (Error?) -> Void
    }

    private let out: Output
    private let queue = DispatchQueue(label: "remotemac.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var encoder: VideoEncoder?
    private var latest: CVPixelBuffer?
    private var latestCapture: UInt64 = 0
    private var dirty = false
    private var wantKeyframe = true
    private var refine: DispatchWorkItem?
    private(set) var displayID: CGDirectDisplayID = CGMainDisplayID()
    private(set) var codec = VideoCodec.h264

    init(output: Output) { self.out = output }

    func start(displayID wanted: CGDirectDisplayID?, maxWidth: Int, maxHeight: Int, codecs: [VideoCodec]) async throws -> ScreenInfo {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == (wanted ?? CGMainDisplayID()) })
                ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw StreamerError.noDisplay
        }
        displayID = display.displayID
        // HEVC first: VideoToolbox's H.264 encoder cannot do 5120-wide in hardware
        // (low-latency mode refuses it with -19354), HEVC does it in ~16ms a frame.
        codec = codecs.contains(.hevc) ? .hevc : .h264

        // SCDisplay reports points; the mode tells us the real pixel count.
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let pixelW = Double(mode?.pixelWidth ?? display.width * 2)
        let pixelH = Double(mode?.pixelHeight ?? display.height * 2)
        let limit = codec == .h264 ? 4096.0 : 8192.0
        let fit = min(1, Double(maxWidth) / pixelW, Double(maxHeight) / pixelH, limit / pixelW, limit / pixelH)
        let w = Int(pixelW * fit) & ~1, h = Int(pixelH * fit) & ~1

        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 5

        let encoder = try VideoEncoder(codec: codec, width: w, height: h)
        encoder.onFormat = out.format
        encoder.onFrame = out.frame
        self.encoder = encoder

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream

        let names = await MainActor.run { () -> [CGDirectDisplayID: String] in
            var n: [CGDirectDisplayID: String] = [:]
            for screen in NSScreen.screens {
                if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                    n[id] = screen.localizedName
                }
            }
            return n
        }
        let displays = content.displays.map {
            DisplayInfo(id: $0.displayID, name: names[$0.displayID] ?? "Display \($0.displayID)",
                        width: Double($0.width), height: Double($0.height))
        }
        return ScreenInfo(displayID: display.displayID, displayName: names[display.displayID] ?? "Display",
                          codec: codec, streamWidth: w, streamHeight: h,
                          screenWidth: Double(display.width), screenHeight: Double(display.height),
                          displays: displays)
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
        queue.async { [self] in
            refine?.cancel()
            encoder?.invalidate()
            encoder = nil
            latest = nil
        }
    }

    func requestKeyframe() {
        queue.async { [self] in
            wantKeyframe = true
            dirty = true
            pump()
        }
    }

    /// The network drained; send the newest frame if we skipped any.
    func drained() {
        queue.async { [self] in pump() }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sample.imageBuffer else { return }
        latest = pixels
        latestCapture = UInt64(max(0, sample.presentationTimeStamp.seconds) * 1e9)
        dirty = true
        pump()
        scheduleRefine()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        out.stopped(error)
    }

    // MARK: Encoding

    private func pump() {
        guard dirty, let pixels = latest, let encoder, out.canSend() else { return }
        dirty = false
        encoder.encode(pixels, captureNanos: latestCapture, forceKeyframe: wantKeyframe)
        wantKeyframe = false
    }

    private func scheduleRefine() {
        refine?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dirty = true
            self.pump()
            // One more pass a little later; each re-encode of a static image converges on it.
            let again = DispatchWorkItem { [weak self] in self?.dirty = true; self?.pump() }
            self.refine = again
            self.queue.asyncAfter(deadline: .now() + 0.4, execute: again)
        }
        refine = item
        queue.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

}

enum StreamerError: LocalizedError {
    case noDisplay
    case encoder(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display available to capture"
        case .encoder(let s): "Could not create video encoder (\(s))"
        }
    }
}

