import CoreGraphics

/// How big to make the Mac window for the space the app has, in Mac points.
///
/// The window gets the shape of that space, and enough Mac points that Mac
/// apps lay out normally: about 840 wide in portrait, which most apps accept
/// as a minimum, and at least 600 tall. On an unfolded iPhone Duo in portrait
/// that is 1.35 Mac points per iPhone point; folded, the cover screen needs
/// about 1.8. Never fewer Mac points than iPhone points: blowing Mac text up
/// past its real size only wastes the screen. `textScale` above 1 makes
/// everything on the Mac bigger (fewer Mac points), below 1 smaller.
enum WindowSizing {
    static let targetWidth: CGFloat = 840
    static let targetHeight: CGFloat = 600
    static let maxMacPointsPerPoint: CGFloat = 2.5

    static func macPointsPerPoint(for space: CGSize, textScale: CGFloat = 1) -> CGFloat {
        guard space.width > 0, space.height > 0 else { return 1 }
        let fit = max(targetWidth / space.width, targetHeight / space.height) / max(textScale, 0.1)
        return min(max(fit, 1), maxMacPointsPerPoint)
    }

    static func request(for space: CGSize, textScale: CGFloat = 1) -> WindowRequest? {
        guard space.width >= 100, space.height >= 100 else { return nil }
        let k = macPointsPerPoint(for: space, textScale: textScale)
        return WindowRequest(width: (space.width * k).rounded(), height: (space.height * k).rounded())
    }
}

extension WindowSizing {
    /// The part of the screen the Mac window gets. Normally the safe area. With
    /// iPhone Duo partly open, the fold is an active division region: the window
    /// then takes the side above it (or before it, for an upright fold) and the
    /// other side is left as the trackpad, like a laptop's lid and deck.
    /// Only what is above `bottom`: the top of the toolbar, which sits above the
    /// on-screen keyboard when that is up. The bottom of a Mac window is where
    /// its text fields are; under the keyboard or the toolbar you can't see them.
    static func space(safe: CGRect, division: CGRect?, bottom: CGFloat? = nil) -> CGRect {
        var safe = safe
        if let b = bottom, b < safe.maxY { safe.size.height = max(0, b - safe.minY) }
        guard let d = division, safe.intersects(d) else { return safe }
        if d.width >= d.height {
            return CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: max(0, d.minY - safe.minY))
        }
        return CGRect(x: safe.minX, y: safe.minY, width: max(0, d.minX - safe.minX), height: safe.height)
    }
}

/// What the app runs on, for its defaults. Layout never branches on this:
/// the window is sized from the space the app actually has, so a folding
/// phone, iPad Split View and Stage Manager all come out right without knowing.
enum DeviceKind: Equatable {
    /// The whole Mac display fits: stream all of it.
    case pad
    /// Any iPhone, iPhone Duo folded or open included.
    case phone

    /// Whole display on an iPad, one window anywhere smaller.
    var prefersWindowMode: Bool { self != .pad }
}
