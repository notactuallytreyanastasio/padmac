import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// Captures one display with ScreenCaptureKit and hardware-encodes it to H.264.
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
    private var encoder: VTCompressionSession?
    private var latest: CVPixelBuffer?
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

        try makeEncoder(width: w, height: h)

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
            if let encoder { VTCompressionSessionInvalidate(encoder) }
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
        var props: CFDictionary?
        if wantKeyframe {
            wantKeyframe = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixels, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample else { return }
            self?.emit(sample)
        }
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

    private func emit(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let keyframe = !notSync

        if keyframe, let fmt = sample.formatDescription {
            // Always resend with a keyframe: a client that just connected needs it.
            let sets = VideoFormat.parameterSets(of: fmt, codec: codec)
            guard !sets.isEmpty else { return NSLog("RemoteMac: keyframe without parameter sets") }
            out.format(VideoFormatPayload.encode(codec: codec, parameterSets: sets))
        }

        guard let block = sample.dataBuffer else { return }
        let len = CMBlockBufferGetDataLength(block)
        var payload = Data(count: 1 + len)
        payload[0] = keyframe ? 1 : 0
        payload.withUnsafeMutableBytes { buf in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: buf.baseAddress! + 1)
        }
        out.frame(payload)
    }

    private func makeEncoder(width: Int, height: Int) throws {
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, encoderSpecification: spec,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw StreamerError.encoder(status) }

        // Screen content is mostly static text: spend bits per pixel, not per frame.
        // HEVC gets the same sharpness for about 60% of the bits.
        let perPixel = codec == .hevc ? 3 : 5
        let bitrate = min(40_000_000, max(6_000_000, width * height * perPixel))
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 20,
        ]
        for (k, v) in props {
            let s = VTSessionSetProperty(session, key: k, value: v as CFTypeRef)
            if s != noErr { NSLog("RemoteMac: encoder rejected \(k) = \(v): \(s)") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
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

