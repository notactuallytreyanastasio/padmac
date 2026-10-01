import CoreMedia
import Foundation
import VideoToolbox

/// Hardware video encoder producing wire-ready payloads: a `videoFormat`
/// message before every keyframe, and a `videoFrame` message per frame.
/// Knows nothing about screen capture, so it can be tested with synthetic frames.
final class VideoEncoder {
    let codec: VideoCodec
    let width: Int
    let height: Int
    /// Called on VideoToolbox's thread, in encode order.
    var onFormat: ((Data) -> Void)?
    var onFrame: ((Data) -> Void)?

    private var session: VTCompressionSession?
    private var lastCapture: UInt64?

    init(codec: VideoCodec, width: Int, height: Int, quality: StreamQuality = .full) throws {
        self.codec = codec
        self.width = width
        self.height = height

        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                                encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { throw StreamerError.encoder(status) }

        // Screen content is mostly static text: spend bits per pixel, not per frame.
        let bitrate = quality.bitrate(width: width, height: height, codec: codec)
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: quality.framesPerSecond,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 20,
        ]
        for (k, v) in props {
            let r = VTSessionSetProperty(s, key: k, value: v as CFTypeRef)
            if r != noErr { NSLog("RemoteMac: encoder rejected \(k) = \(v): \(r)") }
        }
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }

    deinit { invalidate() }

    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    /// Encoding the same `captureNanos` twice marks the second frame as a refresh.
    func encode(_ pixels: CVPixelBuffer, captureNanos: UInt64, forceKeyframe: Bool) {
        guard let session else { return }
        let props = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let refresh = captureNanos == lastCapture
        lastCapture = captureNanos
        // Encoder timestamps must only increase, and a refresh re-encodes an old
        // capture, so the capture time travels beside the frame instead.
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        let called = UInt64(pts.seconds * 1e9)
        defer { if Trace.latency { Trace.record("encode call (blocking)", since: called) } }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self else { return }
            guard status == noErr, let sample else { return NSLog("RemoteMac: encode failed: \(status)") }
            self.emit(sample, captured: captureNanos, refresh: refresh)
        }
    }

    /// Block until every submitted frame has been emitted. For tests and shutdown.
    func flush() {
        if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
    }

    private func emit(_ sample: CMSampleBuffer, captured: UInt64, refresh: Bool) {
        if Trace.latency && !refresh { Trace.record("capture->encoded", since: captured) }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        if keyframe, let fmt = sample.formatDescription {
            // Always resend with a keyframe: a client that just connected needs it.
            let sets = VideoFormat.parameterSets(of: fmt, codec: codec)
            guard !sets.isEmpty else { return NSLog("RemoteMac: keyframe without parameter sets") }
            onFormat?(VideoFormatPayload.encode(codec: codec, parameterSets: sets))
        }

        guard let block = sample.dataBuffer else { return }
        let len = CMBlockBufferGetDataLength(block)
        var payload = FramePayload.header(keyframe: keyframe, refresh: refresh, captureNanos: captured)
        payload.count += len
        payload.withUnsafeMutableBytes { buf in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: buf.baseAddress! + FramePayload.headerSize)
        }
        onFrame?(payload)
    }
}
