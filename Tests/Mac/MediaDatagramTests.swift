import XCTest

final class MediaDatagramTests: XCTestCase {
    private func message(id: UInt32 = 1, epoch: UInt32 = 1, keyframe: Bool = true, size: Int = 20_017) -> MediaDatagrams.Message {
        .init(kind: .video, epoch: epoch, id: id, keyframe: keyframe, data: Data((0..<size).map { UInt8($0 % 251) }))
    }

    func testReorderingAndOneMissingPacketPerGroupRecoverExactly() {
        let original = message()
        let packets = MediaDatagrams.packets(original).filter { packet in
            let f = MediaDatagrams.parse(packet)!
            return f.parity || f.index % 8 != 0
        }
        XCTAssertTrue(packets.allSatisfy { $0.count <= 1020 })
        var assembler = MediaReassembler()
        let completed = packets.reversed().compactMap { assembler.receive($0, at: 1) }
        XCTAssertEqual(completed, [original])
        XCTAssertNil(assembler.receive(packets[0], at: 1.1), "duplicates must not decode twice")
    }

    func testAnIncompleteFrameDoesNotHoldUpANewerFrame() {
        var assembler = MediaReassembler()
        let old = message(id: 1)
        let oldPackets = MediaDatagrams.packets(old)
        // Two losses in the first group exceed the recovery packet's ability.
        for packet in oldPackets {
            let f = MediaDatagrams.parse(packet)!
            if !f.parity && (f.index == 0 || f.index == 1) { continue }
            XCTAssertNil(assembler.receive(packet, at: 1))
        }
        let new = message(id: 2, size: 53)
        XCTAssertEqual(assembler.receive(MediaDatagrams.packets(new)[0], at: 1.1), new)
        XCTAssertNil(assembler.receive(oldPackets[0], at: 2), "expired pieces cannot complete the old frame")
    }

    func testRejectsMalformedFragmentSizesAndCounts() {
        let good = MediaDatagrams.packets(message(size: 123))[0]
        XCTAssertNil(MediaDatagrams.parse(Data()))
        XCTAssertNil(MediaDatagrams.parse(good.dropLast()))
        var wrong = good; wrong[0] = 0
        XCTAssertNil(MediaDatagrams.parse(wrong))
        wrong = good; wrong[14] = 0xFF
        XCTAssertNil(MediaDatagrams.parse(wrong))
    }

    func testLossAndOldEpochsNeverFeedDependentPicturesToDecoder() {
        var order = MediaVideoOrder()
        XCTAssertFalse(order.accept(message(id: 1, keyframe: false)).decode)
        XCTAssertTrue(order.accept(message(id: 2)).decode)
        XCTAssertTrue(order.accept(message(id: 3, keyframe: false)).decode)
        XCTAssertTrue(order.accept(message(id: 5, keyframe: false)).requestKeyframe)
        XCTAssertFalse(order.accept(message(id: 4, keyframe: false)).decode)
        XCTAssertTrue(order.accept(message(id: 6)).decode)
        XCTAssertFalse(order.accept(message(id: 7, epoch: 2, keyframe: false)).decode)
        XCTAssertTrue(order.accept(message(id: 8, epoch: 2)).decode)
        XCTAssertFalse(order.accept(message(id: 9, epoch: 1)).decode)
    }

    func testKeyframeCarriesDecoderConfiguration() throws {
        let format = Data([1, 2, 3]), frame = Data([4, 5, 6])
        let decoded = try XCTUnwrap(MediaVideo.decode(MediaVideo.encode(format: format, frame: frame)))
        XCTAssertEqual(decoded.format, format)
        XCTAssertEqual(decoded.frame, frame)
        XCTAssertNil(MediaVideo.decode(Data([0, 30, 1])))
    }
}
