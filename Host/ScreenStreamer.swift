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
        /// An AudioPayload, every 20ms while audio is on. Called on the audio queue.
        var audio: (Data) -> Void = { _ in }
        var stopped: (Error?) -> Void
    }

    private let out: Output
    private let queue = DispatchQueue(label: "remotemac.capture", qos: .userInteractive)
    /// Encoding blocks (30ms a frame at 5120x1440 under load), so it gets its own
    /// queue. On the capture queue it backed ScreenCaptureKit up to its full
    /// queue depth: every frame arrived ~150ms late instead of the newest ~30ms late.
    private let encodeQueue = DispatchQueue(label: "remotemac.encode", qos: .userInteractive)
    private var encoding = false
    private let audioQueue = DispatchQueue(label: "remotemac.audio", qos: .userInteractive)
    private var audioFormatChecked = false
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

    func start(displayID wanted: CGDirectDisplayID?, maxWidth: Int, maxHeight: Int, codecs: [VideoCodec], audio: Bool = false, quality: StreamQuality = .full) async throws -> ScreenInfo {
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
        let (w, h) = quality.streamSize(display: (pixelW, pixelH), clientMax: (maxWidth, maxHeight),
                                        codecLimit: codec == .h264 ? 4096 : 8192)

        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(quality.framesPerSecond))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 5
        if audio {
            // What the Mac delivers, measured: 48kHz planar Float32 stereo in 960-frame chunks.
            config.capturesAudio = true
            config.sampleRate = Int(AudioPayload.sampleRate)
            config.channelCount = AudioPayload.channels
            config.excludesCurrentProcessAudio = true
        }

        let encoder = try VideoEncoder(codec: codec, width: w, height: h, quality: quality)
        encoder.onFormat = out.format
        encoder.onFrame = out.frame
        self.encoder = encoder

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
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
        if type == .audio { return handleAudio(sample) }
        guard type == .screen, sample.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sample.imageBuffer else { return }
        latest = pixels
        latestCapture = UInt64(max(0, sample.presentationTimeStamp.seconds) * 1e9)
        if Trace.latency { Trace.record("capture->delivered", since: latestCapture) }
        dirty = true
        pump()
        scheduleRefine()
    }

    private func handleAudio(_ sample: CMSampleBuffer) {
        guard sample.isValid, let fmt = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
        let planarFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 && asbd.mBitsPerChannel == 32
        guard planarFloat, asbd.mSampleRate == AudioPayload.sampleRate, asbd.mChannelsPerFrame >= 1 else {
            // Not what we asked for. Say so once and send nothing, rather than noise.
            if !audioFormatChecked { NSLog("RemoteMac: unexpected audio format \(asbd); audio disabled") }
            audioFormatChecked = true
            return
        }
        let capture = UInt64(max(0, sample.presentationTimeStamp.seconds) * 1e9)
        try? sample.withAudioBufferList { list, _ in
            let left = list[0], right = list.count > 1 ? list[1] : list[0] // mono plays on both sides
            let n = Int(left.mDataByteSize) / 4
            let l = UnsafeBufferPointer(start: left.mData?.assumingMemoryBound(to: Float.self), count: n)
            let r = UnsafeBufferPointer(start: right.mData?.assumingMemoryBound(to: Float.self), count: n)
            out.audio(AudioPayload.encode(captureNanos: capture, left: l, right: r))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        out.stopped(error)
    }

    // MARK: Encoding

    /// Encode the newest frame, unless an encode is running: then it'll take
    /// whatever is newest when it finishes, and the frames in between are dropped.
    private func pump() {
        guard !encoding, dirty, let pixels = latest, let encoder, out.canSend() else { return }
        dirty = false
        encoding = true
        let capture = latestCapture, key = wantKeyframe
        wantKeyframe = false
        encodeQueue.async { [weak self] in
            if Trace.latency { Trace.record("capture->submitted", since: capture) }
            encoder.encode(pixels, captureNanos: capture, forceKeyframe: key)
            self?.queue.async {
                self?.encoding = false
                self?.pump()
            }
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


/// `-traceLatency YES`: logs where time goes between capture and the wire,
/// as a median every 30 samples per stage.
enum Trace {
    static let latency = UserDefaults.standard.bool(forKey: "traceLatency")
    private static var samples: [String: [Double]] = [:]
    private static let lock = NSLock()

    static func record(_ stage: String, since nanos: UInt64) {
        let now = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1e9)
        guard now > nanos else { return }
        lock.lock(); defer { lock.unlock() }
        samples[stage, default: []].append(Double(now - nanos) / 1e6)
        if let s = samples[stage], s.count >= 30 {
            let sorted = s.sorted()
            NSLog("RemoteMac trace: %@ p50 %.1fms p95 %.1fms", stage, sorted[15], sorted[28])
            samples[stage] = []
        }
    }
}
