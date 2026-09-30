import CoreGraphics
import XCTest

final class ViewportTests: XCTestCase {
    // A 32:9 ultrawide letterboxed in a 4:3 landscape iPad.
    let view = CGSize(width: 1000, height: 750)
    let content = CGRect(x: 0, y: 234.375, width: 1000, height: 281.25)

    private func assertCovers(_ v: Viewport, file: StaticString = #filePath, line: UInt = #line) {
        let tl = v.toScreen(CGPoint(x: v.content.minX, y: v.content.minY))
        let br = v.toScreen(CGPoint(x: v.content.maxX, y: v.content.maxY))
        let w = br.x - tl.x, h = br.y - tl.y
        if w >= v.viewSize.width {
            XCTAssertLessThanOrEqual(tl.x, 0.001, "gap on the left", file: file, line: line)
            XCTAssertGreaterThanOrEqual(br.x, v.viewSize.width - 0.001, "gap on the right", file: file, line: line)
        } else {
            XCTAssertEqual(tl.x, (v.viewSize.width - w) / 2, accuracy: 0.001, "not centred horizontally", file: file, line: line)
        }
        if h >= v.viewSize.height {
            XCTAssertLessThanOrEqual(tl.y, 0.001, "gap at the top", file: file, line: line)
            XCTAssertGreaterThanOrEqual(br.y, v.viewSize.height - 0.001, "gap at the bottom", file: file, line: line)
        } else {
            XCTAssertEqual(tl.y, (v.viewSize.height - h) / 2, accuracy: 0.001, "not centred vertically", file: file, line: line)
        }
    }

    func testStartsUnzoomedAndCentred() {
        let v = Viewport(viewSize: view, content: content)
        XCTAssertFalse(v.isZoomed)
        XCTAssertEqual(v.transform, .identity)
        assertCovers(v)
    }

    func testFillZoomRemovesTheLetterbox() {
        var v = Viewport(viewSize: view, content: content)
        XCTAssertEqual(v.fillZoom, 750 / 281.25, accuracy: 0.0001)
        v.set(zoom: v.fillZoom, offset: .zero)
        let top = v.toScreen(CGPoint(x: 0, y: content.minY)).y
        let bottom = v.toScreen(CGPoint(x: 0, y: content.maxY)).y
        XCTAssertEqual(top, 0, accuracy: 0.001)
        XCTAssertEqual(bottom, 750, accuracy: 0.001)
    }

    func testZoomIsClampedBetween1And8() {
        var v = Viewport(viewSize: view, content: content)
        v.set(zoom: 50, offset: .zero)
        XCTAssertEqual(v.zoom, Viewport.maxZoom)
        v.set(zoom: 0.2, offset: .zero)
        XCTAssertEqual(v.zoom, 1)
    }

    func testPanningNeverRevealsAGap() {
        var v = Viewport(viewSize: view, content: content)
        v.set(zoom: 4, offset: .zero)
        for t in [CGPoint(x: 1e6, y: 0), CGPoint(x: -1e6, y: 0), CGPoint(x: 0, y: 1e6), CGPoint(x: 0, y: -1e6), CGPoint(x: 37, y: -12)] {
            v.pan(by: t)
            assertCovers(v)
        }
    }

    func testZoomKeepsTheAnchorPointUnderTheFinger() {
        var v = Viewport(viewSize: view, content: content)
        v.set(zoom: 3, offset: CGPoint(x: -800, y: -900))
        let anchor = CGPoint(x: 400, y: 380)
        let under = v.fromScreen(anchor)
        v.zoom(to: 5, keeping: anchor)
        XCTAssertEqual(v.toScreen(under).x, anchor.x, accuracy: 0.001)
        XCTAssertEqual(v.toScreen(under).y, anchor.y, accuracy: 0.001)
    }

    func testPinchZoomsAndPansFromWhereItStarted() {
        var start = Viewport(viewSize: view, content: content)
        start.set(zoom: 3, offset: CGPoint(x: -1000, y: -900))
        let c0 = CGPoint(x: 500, y: 375)
        let point = start.fromScreen(c0)
        var v = start
        // Fingers spread to 2x and drift 60pt left: the same content stays under them.
        v.pinch(from: start, startCentroid: c0, scale: 2, centroid: CGPoint(x: 440, y: 375))
        XCTAssertEqual(v.zoom, 6)
        XCTAssertEqual(v.toScreen(point).x, 440, accuracy: 0.001)
        XCTAssertEqual(v.toScreen(point).y, 375, accuracy: 0.001)
    }

    func testFollowBringsTheCursorIntoTheMiddleAndNoFurther() {
        var v = Viewport(viewSize: view, content: content)
        v.set(zoom: 4, offset: .zero) // clamped to the top-left
        v.follow(x: 0.9, y: 0.5)
        let s = v.toScreen(CGPoint(x: content.minX + 0.9 * content.width, y: content.midY))
        XCTAssertEqual(s.x, view.width * 0.85, accuracy: 0.5, "moved just far enough")
        assertCovers(v)

        let before = v
        v.follow(x: 0.9, y: 0.5)
        XCTAssertEqual(v, before, "already visible: no movement")
    }

    func testFollowDoesNothingWhenNotZoomed() {
        var v = Viewport(viewSize: view, content: content)
        v.follow(x: 1, y: 1)
        XCTAssertEqual(v.transform, .identity)
    }

    func testScreenMappingIsInvertible() {
        var v = Viewport(viewSize: view, content: content)
        v.set(zoom: 2.5, offset: CGPoint(x: -300, y: -500))
        let p = CGPoint(x: 123, y: 456)
        XCTAssertEqual(v.fromScreen(v.toScreen(p)).x, p.x, accuracy: 1e-9)
        XCTAssertEqual(v.fromScreen(v.toScreen(p)).y, p.y, accuracy: 1e-9)
    }
}
