import AppKit
import ApplicationServices
import CoreGraphics

/// A Mac window as the window server lists it. `frame` is in global display
/// coordinates: points, top-left origin, the space CGEvents and AX use.
struct MacWindow: Equatable {
    var id: CGWindowID
    var pid: pid_t
    var app: String
    var title: String
    var frame: CGRect

    var info: WindowInfo { WindowInfo(id: id, app: app, title: title, width: frame.width, height: frame.height) }
}

/// The windows window mode moves between: ordinary app windows on the Mac's
/// current desktop. Windows on other desktops and minimized ones are not
/// listed; AX only reaches windows on the current Space.
enum WindowList {
    /// The window server's layer-0 windows that Accessibility calls real
    /// windows, frontmost first. Layer 0 alone is not enough: iTerm2 keeps a
    /// 1512x68 untitled strip there that AX does not list.
    static func switchable() -> [MacWindow] {
        let all = onScreen()
        var standard: [pid_t: Set<CGWindowID>] = [:]
        for pid in Set(all.map(\.pid)) { standard[pid] = AXWindow.standardWindowIDs(pid: pid) }
        return all.filter { standard[$0.pid]?.contains($0.id) == true }
    }

    /// Frontmost first.
    static func onScreen() -> [MacWindow] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = getpid()
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let frame = bounds(w), frame.width >= 100, frame.height >= 60,
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular else { return nil }
            return MacWindow(id: id, pid: pid, app: w[kCGWindowOwnerName as String] as? String ?? "",
                             title: w[kCGWindowName as String] as? String ?? "", frame: frame)
        }
    }

    /// Where a window is now, or nil if it closed or left the current desktop.
    static func frame(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let w = list.first, w[kCGWindowIsOnscreen as String] as? Bool == true else { return nil }
        return bounds(w)
    }

    private static func bounds(_ w: [String: Any]) -> CGRect? {
        (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
    }

    /// The usable part (no menu bar, no Dock) of the screen under `point`, in
    /// global display coordinates. Main thread.
    @MainActor static func visibleFrame(at point: CGPoint) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        // NSScreen is bottom-left origin, measured from the primary screen.
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height) }
        let screen = NSScreen.screens.first { flip($0.frame).contains(point) } ?? NSScreen.main
        return screen.map { flip($0.visibleFrame) }
    }
}

/// The swipe order. Raising a window moves it to the front of the z-order, so
/// swiping by z-order would bounce between the same two windows. The order is
/// the order windows were first seen in; new windows join at the end.
struct WindowRing: Equatable {
    private(set) var order: [CGWindowID] = []

    mutating func update(_ zOrder: [CGWindowID]) {
        let present = Set(zOrder)
        order = order.filter(present.contains) + zOrder.filter { !order.contains($0) }
    }

    /// `n` places on from `id`, wrapping around. From a window that is gone, the first.
    func step(from id: CGWindowID?, by n: Int) -> CGWindowID? {
        guard !order.isEmpty else { return nil }
        guard let id, let i = order.firstIndex(of: id) else { return order[0] }
        let c = order.count
        return order[((i + n) % c + c) % c]
    }
}

enum WindowFit {
    /// Where to put a window the client wants `size` big: that size, scaled
    /// down to fit `visible` keeping its aspect ratio, centred where the window
    /// was and then pushed inside `visible`.
    static func place(_ size: CGSize, from current: CGRect, in visible: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return current }
        let k = min(1, visible.width / size.width, visible.height / size.height)
        let w = (size.width * k).rounded(.down), h = (size.height * k).rounded(.down)
        let x = min(max(current.midX - w / 2, visible.minX), visible.maxX - w)
        let y = min(max(current.midY - h / 2, visible.minY), visible.maxY - h)
        return CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
    }
}

@_silgen_name("_AXUIElementGetWindow") @discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Another app's window through the Accessibility API (the host already has
/// that permission, for input). Every call is a round trip to the app, so
/// none of this belongs on the session queue.
enum AXWindow {
    /// A hung app would otherwise stall each call for the 6s default.
    private static let timeout: Float = 0.5

    static func element(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { w in
            var wid: CGWindowID = 0
            return _AXUIElementGetWindow(w, &wid) == .success && wid == id
        }.map { AXUIElementSetMessagingTimeout($0, timeout); return $0 }
    }

    /// Windows AltTab would offer: standard windows, and dialogs with a title.
    /// Floating panels and system dialogs are left out.
    static func standardWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        var ids = Set<CGWindowID>()
        for w in windows {
            let subrole = copy(w, kAXSubroleAttribute) as? String
            let titled = !((copy(w, kAXTitleAttribute) as? String) ?? "").isEmpty
            guard subrole == kAXStandardWindowSubrole || (subrole == kAXDialogSubrole && titled) else { continue }
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(w, &id) == .success { ids.insert(id) }
        }
        return ids
    }

    static func frame(_ w: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = copy(w, kAXPositionAttribute), let sv = copy(w, kAXSizeAttribute),
              AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// False for full-screen windows and ones the app won't let be resized.
    static func resizable(_ w: AXUIElement) -> Bool {
        if (copy(w, "AXFullScreen") as? Bool) == true { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    /// Moves and resizes, and returns where the window actually ended up: apps
    /// enforce minimum sizes and snap to grids, so it is not always `r`.
    /// Position, size, position: an app that clamps the size may shift the origin.
    @discardableResult static func setFrame(_ w: AXUIElement, _ r: CGRect, pid: pid_t) -> CGRect? {
        // The enhanced-UI animation some apps run for VoiceOver reports wrong frames mid-move.
        let app = AXUIElementCreateApplication(pid)
        let enhanced = (copy(app, "AXEnhancedUserInterface") as? Bool) == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
        var origin = r.origin, size = r.size
        let pos = AXValueCreate(.cgPoint, &origin)!, sz = AXValueCreate(.cgSize, &size)!
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
        return frame(w)
    }

    /// Brings the window to the front and gives its app the keyboard.
    static func raise(_ w: AXUIElement, pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate()
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private static func copy(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
    }
}
