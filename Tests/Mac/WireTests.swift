import XCTest

final class WireTests: XCTestCase {
    func testVideoFormatRoundTripsBothCodecs() throws {
        let hevc = [Data([0x40, 1, 2]), Data([0x42, 3, 4, 5]), Data([0x44, 6])]
        let decoded = try XCTUnwrap(VideoFormatPayload.decode(VideoFormatPayload.encode(codec: .hevc, parameterSets: hevc)))
        XCTAssertEqual(decoded.codec, .hevc)
        XCTAssertEqual(decoded.parameterSets, hevc)

        let h264 = [Data(repeating: 0x67, count: 300), Data([0x68, 1])] // > 255 bytes exercises the u16 length
        let d2 = try XCTUnwrap(VideoFormatPayload.decode(VideoFormatPayload.encode(codec: .h264, parameterSets: h264)))
        XCTAssertEqual(d2.codec, .h264)
        XCTAssertEqual(d2.parameterSets, h264)
    }

    func testVideoFormatRejectsMalformed() {
        let good = VideoFormatPayload.encode(codec: .hevc, parameterSets: [Data([1, 2, 3])])
        XCTAssertNil(VideoFormatPayload.decode(Data()), "empty")
        XCTAssertNil(VideoFormatPayload.decode(Data([7, 1, 0, 1, 9])), "unknown codec")
        XCTAssertNil(VideoFormatPayload.decode(Data([1, 0])), "no parameter sets")
        XCTAssertNil(VideoFormatPayload.decode(good.dropLast()), "truncated set")
        XCTAssertNil(VideoFormatPayload.decode(good + Data([0])), "trailing bytes")
        XCTAssertNil(VideoFormatPayload.decode(Data([1, 2, 0, 1, 9])), "count larger than content")
    }

    func testFramePayloadCarriesFlagsAndCaptureTime() throws {
        let body = Data([0, 0, 0, 2, 0xAA, 0xBB])
        for (key, refresh) in [(true, false), (false, true), (false, false), (true, true)] {
            let nanos: UInt64 = 0x0123_4567_89AB_CDEF
            let p = try XCTUnwrap(FramePayload.parse(FramePayload.header(keyframe: key, refresh: refresh, captureNanos: nanos) + body))
            XCTAssertEqual(p.keyframe, key)
            XCTAssertEqual(p.refresh, refresh)
            XCTAssertEqual(p.captureNanos, nanos)
            XCTAssertEqual(Data(p.body), body)
        }
        XCTAssertNil(FramePayload.parse(FramePayload.header(keyframe: true, captureNanos: 1)), "header without body")
    }

    func testFramePayloadParsesSlices() throws {
        // Payloads arrive as slices of larger buffers; indices must not assume 0.
        let whole = Data([9, 9, 9]) + FramePayload.header(keyframe: true, captureNanos: 42) + Data([1, 2])
        let p = try XCTUnwrap(FramePayload.parse(whole.dropFirst(3)))
        XCTAssertEqual(p.captureNanos, 42)
        XCTAssertEqual(Array(p.body), [1, 2])
    }

    func testCursorPayload() throws {
        let c = try XCTUnwrap(CursorPayload.decode(CursorPayload.encode(x: 0.25, y: 0.75)))
        XCTAssertEqual(c.x, 0.25)
        XCTAssertEqual(c.y, 0.75)
        XCTAssertNil(CursorPayload.decode(Data(count: 7)))
    }

    func testEveryInputEventRoundTrips() throws {
        let events: [InputEvent] = [
            .moveBy(dx: 1.5, dy: -2), .moveTo(x: 0.1, y: 0.9),
            .button(.left, down: true), .button(.right, down: false), .button(.middle, down: true),
            .scroll(dx: 0, dy: -12.5), .key(code: 55, down: true), .text("héllo 😀\n"), .releaseAll,
        ]
        for e in events {
            XCTAssertEqual(try JSONDecoder().decode(InputEvent.self, from: JSONEncoder().encode(e)), e)
        }
    }

    func testHelloFromOlderClientDecodes() throws {
        // Fields added later must be optional or older clients can't connect.
        let json = #"{"clientName":"old","maxWidth":1920,"maxHeight":1080}"#
        let h = try JSONDecoder().decode(Hello.self, from: Data(json.utf8))
        XCTAssertNil(h.codecs)
        XCTAssertNil(h.displayID)
    }

    func testPairingCodes() {
        XCTAssertEqual(PairingSecurity.normalize("abcd-efgh"), "ABCDEFGH")
        XCTAssertEqual(PairingSecurity.normalize(" ab cd\tef gh "), "ABCDEFGH")
        XCTAssertEqual(PairingSecurity.display("abcdefgh"), "ABCD-EFGH")
        // 0/O and 1/I are left out of the alphabet so a code can't be misread.
        XCTAssertEqual(PairingSecurity.normalize("O0I1"), "")

        var seen = Set<String>()
        for _ in 0..<1000 {
            let c = PairingSecurity.newCode()
            XCTAssertEqual(c.count, 8)
            XCTAssertEqual(PairingSecurity.normalize(c), c)
            seen.insert(c)
        }
        XCTAssertEqual(seen.count, 1000)
    }
}
