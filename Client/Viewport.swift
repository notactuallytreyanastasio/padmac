import CoreGraphics

/// Zoom and pan of the remote screen, as pure geometry.
///
/// Points are in the video view's own (unzoomed) coordinates. The view is
/// drawn at `screen = offset + zoom * point`. `content` is where the Mac
/// display sits inside the unzoomed view (aspect-fit, so letterboxed).
struct Viewport: Equatable {
    static let maxZoom: CGFloat = 8

    var viewSize: CGSize
    var content: CGRect
    /// Where the display is centred while it is smaller than the view: the
    /// whole view, or in window mode the safe area. Nil is the whole view.
    var area: CGRect?
    private(set) var zoom: CGFloat = 1
    private(set) var offset: CGPoint = .zero

    init(viewSize: CGSize, content: CGRect) {
        self.viewSize = viewSize
        self.content = content
        clamp()
    }

    var isZoomed: Bool { zoom > 1.01 }

    var transform: CGAffineTransform {
        CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: offset.x, ty: offset.y)
    }

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: offset.x + zoom * p.x, y: offset.y + zoom * p.y)
    }

    func fromScreen(_ s: CGPoint) -> CGPoint {
        CGPoint(x: (s.x - offset.x) / zoom, y: (s.y - offset.y) / zoom)
    }

    /// The zoom that makes the display fill the view's short side (letterbox gone).
    var fillZoom: CGFloat {
        guard content.width > 0, content.height > 0 else { return 1 }
        return min(Self.maxZoom, max(viewSize.width / content.width, viewSize.height / content.height))
    }

    mutating func set(zoom z: CGFloat, offset o: CGPoint) {
        zoom = min(max(z, 1), Self.maxZoom)
        offset = o
        clamp()
    }

    /// Zoom by `factor`, keeping the content under the screen point `anchor` fixed.
    mutating func zoom(to z: CGFloat, keeping anchor: CGPoint) {
        let p = fromScreen(anchor)
        let nz = min(max(z, 1), Self.maxZoom)
        set(zoom: nz, offset: CGPoint(x: anchor.x - nz * p.x, y: anchor.y - nz * p.y))
    }

    /// A pinch relative to the state it began in: the content point that was
    /// under `startCentroid` ends up under `centroid`, so pinching also pans.
    mutating func pinch(from start: Viewport, startCentroid: CGPoint, scale: CGFloat, centroid: CGPoint) {
        let p = start.fromScreen(startCentroid)
        let nz = min(max(start.zoom * scale, 1), Self.maxZoom)
        set(zoom: nz, offset: CGPoint(x: centroid.x - nz * p.x, y: centroid.y - nz * p.y))
    }

    mutating func pan(by t: CGPoint) {
        set(zoom: zoom, offset: CGPoint(x: offset.x + t.x, y: offset.y + t.y))
    }

    /// Shift just enough to bring the display point (normalised 0...1) inside
    /// the middle of the view, leaving `margin` of the view on each side.
    mutating func follow(x: Double, y: Double, margin: CGFloat = 0.15) {
        guard isZoomed else { return }
        let s = toScreen(CGPoint(x: content.minX + CGFloat(x) * content.width, y: content.minY + CGFloat(y) * content.height))
        let mx = viewSize.width * margin, my = viewSize.height * margin
        var o = offset
        if s.x < mx { o.x += mx - s.x } else if s.x > viewSize.width - mx { o.x -= s.x - (viewSize.width - mx) }
        if s.y < my { o.y += my - s.y } else if s.y > viewSize.height - my { o.y -= s.y - (viewSize.height - my) }
        if o != offset { set(zoom: zoom, offset: o) }
    }

    /// Never show empty space the display could cover; centre it when it is smaller than the view.
    private mutating func clamp() {
        let a = area ?? CGRect(origin: .zero, size: viewSize)
        func axis(_ o: CGFloat, _ lo: CGFloat, _ len: CGFloat, _ start: CGFloat, _ room: CGFloat, _ span: CGFloat) -> CGFloat {
            let size = zoom * len
            if size <= room { return start + (room - size) / 2 - zoom * lo }
            return min(max(o, span - zoom * (lo + len)), -zoom * lo)
        }
        offset = CGPoint(x: axis(offset.x, content.minX, content.width, a.minX, a.width, viewSize.width),
                         y: axis(offset.y, content.minY, content.height, a.minY, a.height, viewSize.height))
    }
}
