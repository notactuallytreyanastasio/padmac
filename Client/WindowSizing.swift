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
