import CoreMedia
import VideoToolbox
import XCTest

/// VideoEncoder -> wire payloads -> VideoFormat -> VideoToolbox decoder, with synthetic frames.
final class VideoPipelineTests: XCTestCase {
    private func frame(_ w: Int, _ h: Int, luma: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let p = pb!
        CVPixelBufferLockBaseAddress(p, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(p, 0), Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(p, 0) * h)
        memset(CVPixelBufferGetBaseAddressOfPlane(p, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(p, 1) * h / 2)
        CVPixelBufferUnlockBaseAddress(p, [])
        return p
    }

    private struct Encoded { var formats: [Data] = []; var frames: [Data] = [] }

    private func encode(_ codec: VideoCodec, _ w: Int, _ h: Int, _ inputs: [(luma: UInt8, capture: UInt64, key: Bool)]) throws -> Encoded {
        let enc = try VideoEncoder(codec: codec, width: w, height: h)
        var out = Encoded()
        let lock = NSLock()
        enc.onFormat = { d in lock.lock(); out.formats.append(d); lock.unlock() }
        enc.onFrame = { d in lock.lock(); out.frames.append(d); lock.unlock() }
        for i in inputs { enc.encode(frame(w, h, luma: i.luma), captureNanos: i.capture, forceKeyframe: i.key) }
        enc.flush()
        enc.invalidate()
        return out
    }

    /// Decodes every frame and returns the mean luma of each picture.
    private func decode(_ e: Encoded) throws -> [(w: Int, h: Int, luma: Double)] {
        let (codec, sets) = try XCTUnwrap(VideoFormatPayload.decode(try XCTUnwrap(e.formats.first)))
        let format = try XCTUnwrap(VideoFormat.description(codec: codec, parameterSets: sets))
        var session: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                    imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session), noErr)
        var pictures: [(Int, Int, Double)] = []
        for payload in e.frames {
            let f = try XCTUnwrap(FramePayload.parse(payload))
            let sample = try XCTUnwrap(VideoFormat.sampleBuffer(f.body, format: format, displayImmediately: false))
            let status = VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                XCTAssertEqual(status, noErr)
                guard let image else { return }
                CVPixelBufferLockBaseAddress(image, .readOnly)
                let base = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0), h = CVPixelBufferGetHeight(image), w = CVPixelBufferGetWidth(image)
                var sum = 0
                for y in Swift.stride(from: 0, to: h, by: 8) { for x in Swift.stride(from: 0, to: w, by: 8) { sum += Int(base[y * rowBytes + x]) } }
                let n = ((h + 7) / 8) * ((w + 7) / 8)
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
                pictures.append((w, h, Double(sum) / Double(n)))
            }
            XCTAssertEqual(status, noErr)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session!)
        VTDecompressionSessionInvalidate(session!)
        return pictures
    }

    func testHEVCAtUltrawideNativeResolutionDecodes() throws {
        // The size that H.264 can't do in hardware.
        let e = try encode(.hevc, 5120, 1440, [(40, 1, true), (200, 2, false), (200, 3, false)])
        XCTAssertEqual(e.frames.count, 3)
        let (codec, sets) = try XCTUnwrap(VideoFormatPayload.decode(e.formats[0]))
        XCTAssertEqual(codec, .hevc)
        XCTAssertEqual(sets.count, 3, "VPS, SPS, PPS")
        let pics = try decode(e)
        XCTAssertEqual(pics.count, 3)
        XCTAssertEqual(pics[0].w, 5120)
        XCTAssertEqual(pics[0].h, 1440)
        XCTAssertEqual(pics[0].luma, 40, accuracy: 6)
        XCTAssertEqual(pics[2].luma, 200, accuracy: 6)
    }

    func testH264Decodes() throws {
        let e = try encode(.h264, 1920, 1080, [(60, 1, true), (180, 2, false)])
        XCTAssertEqual(try XCTUnwrap(VideoFormatPayload.decode(e.formats[0])).parameterSets.count, 2, "SPS, PPS")
        let pics = try decode(e)
        XCTAssertEqual(pics.map(\.luma).last ?? 0, 180, accuracy: 6)
    }

    func testFormatIsSentBeforeEveryKeyframeAndOnlyThen() throws {
        let e = try encode(.hevc, 640, 360, [(10, 1, true), (20, 2, false), (30, 3, true), (40, 4, false)])
        let keys = e.frames.map { FramePayload.parse($0)!.keyframe }
        XCTAssertEqual(keys, [true, false, true, false])
        XCTAssertEqual(e.formats.count, 2, "a client joining at the second keyframe needs its own format message")
    }

    func testReencodingTheSameCaptureIsMarkedRefresh() throws {
        let e = try encode(.hevc, 640, 360, [(10, 100, true), (10, 100, false), (10, 100, false), (90, 200, false)])
        let frames = e.frames.map { FramePayload.parse($0)! }
        XCTAssertEqual(frames.map(\.refresh), [false, true, true, false])
        XCTAssertEqual(frames.map(\.captureNanos), [100, 100, 100, 200])
    }
}
