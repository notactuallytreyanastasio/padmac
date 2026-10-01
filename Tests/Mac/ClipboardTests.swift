import AppKit
import XCTest

/// ClipboardWatcher against a private pasteboard: the real one is never touched.
final class ClipboardTests: XCTestCase {
    private var pb: NSPasteboard!
    private var sent: [ClipboardWatcher.Clip] = []
    private var watcher: ClipboardWatcher!

    override func setUp() {
        pb = NSPasteboard(name: NSPasteboard.Name("remotemac-test-\(UUID())"))
        pb.clearContents()
        sent = []
        watcher = ClipboardWatcher(pasteboard: pb) { [unowned self] in self.sent.append($0) }
        watcher.poll() // drain whatever counted as "on connect"
        sent = []
    }

    override func tearDown() { pb.releaseGlobally() }

    private func image(_ w: Int, _ h: Int, noise: Bool = false) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
        let p = rep.bitmapData!
        for i in 0..<(w * h * 4) { p[i] = noise ? UInt8.random(in: 0...255) : UInt8(i % 251) }
        return rep
    }

    private func size(ofPNG data: Data) -> (Int, Int)? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    func testWhatIsThereOnConnectIsSent() {
        pb.clearContents()
        pb.setString("already here", forType: .string)
        let fresh = ClipboardWatcher(pasteboard: pb) { [unowned self] in self.sent.append($0) }
        fresh.poll()
        XCTAssertEqual(sent, [.text("already here")])
    }

    func testTextChangesAreSentOnce() {
        pb.clearContents()
        pb.setString("hello", forType: .string)
        watcher.poll()
        watcher.poll()
        XCTAssertEqual(sent, [.text("hello")])
    }

    func testTIFFOnlyImagesAreConvertedToPNG() throws {
        // Many Mac apps put only TIFF on the pasteboard.
        pb.clearContents()
        pb.setData(image(300, 200).tiffRepresentation!, forType: .tiff)
        watcher.poll()
        guard case .image(let png)? = sent.first else { return XCTFail("got \(sent)") }
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG signature")
        XCTAssertEqual(size(ofPNG: png)?.0, 300)
        XCTAssertEqual(size(ofPNG: png)?.1, 200)
    }

    func testAnImageWinsOverItsURL() {
        pb.clearContents()
        pb.declareTypes([.png, .string], owner: nil)
        pb.setData(image(10, 10).representation(using: .png, properties: [:])!, forType: .png)
        pb.setString("https://example.com/cat.png", forType: .string)
        watcher.poll()
        guard case .image? = sent.first else { return XCTFail("got \(sent)") }
        XCTAssertEqual(sent.count, 1)
    }

    func testPasswordManagerItemsStayOnTheMac() {
        pb.clearContents()
        pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        pb.setString("hunter2", forType: .string)
        watcher.poll()
        XCTAssertEqual(sent, [])
    }

    func testAnImageFromTheiPadIsOfferedAsPNGAndTIFFAndNotEchoed() throws {
        let png = image(64, 48).representation(using: .png, properties: [:])!
        watcher.set(.image(png))
        watcher.poll()
        XCTAssertEqual(sent, [], "not sent back to the iPad")
        XCTAssertEqual(pb.data(forType: .png), png)
        let tiff = try XCTUnwrap(pb.data(forType: .tiff), "for apps that only read TIFF")
        XCTAssertEqual(NSBitmapImageRep(data: tiff)?.pixelsWide, 64)
    }

    func testTextFromTheiPadIsNotEchoed() {
        watcher.set(.text("from the iPad"))
        watcher.poll()
        XCTAssertEqual(sent, [])
        XCTAssertEqual(pb.string(forType: .string), "from the iPad")
    }

    func testUniversalClipboardBouncingItBackIsNotResent() {
        pb.clearContents()
        pb.setString("copied on the Mac", forType: .string)
        watcher.poll()
        // iOS syncs the iPad's pasteboard back: same text, new change count.
        pb.clearContents()
        pb.setString("copied on the Mac", forType: .string)
        watcher.poll()
        XCTAssertEqual(sent, [.text("copied on the Mac")], "sent once, not bounced")
        // Same for what the iPad sent us.
        watcher.set(.text("from the iPad"))
        pb.clearContents()
        pb.setString("from the iPad", forType: .string)
        watcher.poll()
        XCTAssertEqual(sent.count, 1)
        // Anything new still goes.
        pb.clearContents()
        pb.setString("something else", forType: .string)
        watcher.poll()
        XCTAssertEqual(sent.last, .text("something else"))
    }

    func testImagesOverTheLimitAreNotSent() {
        // Noise doesn't compress: 2400x2400 RGBA is ~23 MB of PNG.
        let big = image(2400, 2400, noise: true).representation(using: .png, properties: [:])!
        XCTAssertGreaterThan(big.count, ClipboardWatcher.maxImageBytes)
        pb.clearContents()
        pb.setData(big, forType: .png)
        watcher.poll()
        XCTAssertEqual(sent, [])
    }
}
