import AppKit
import CoreGraphics

/// Turns InputEvents into CGEvents posted at the HID level. Needs Accessibility permission.
///
/// Modifier state is tracked here and stamped onto every event explicitly.
/// Posting a flagsChanged event for Command does not make the next synthesized
/// key event carry the Command flag, so without this Cmd-C arrives as plain "c".
final class InputInjector {
    var displayID: CGDirectDisplayID
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttons = Set<MouseButton>()
    private var heldKeys = Set<UInt16>()
    private var capsLock = false
    private var lastDown: (button: MouseButton, time: TimeInterval, at: CGPoint, count: Int)?

    init(displayID: CGDirectDisplayID) { self.displayID = displayID }

    private var bounds: CGRect { CGDisplayBounds(displayID) }

    private var posted: (at: CGPoint, time: TimeInterval)?

    /// Where the cursor is, for the purpose of the next event.
    ///
    /// Reading the real cursor back right after posting a move returns the old
    /// position: the window server has not applied it yet. A burst of relative
    /// moves built on that loses deltas (20 x +10 arrived as +120). So during a
    /// burst trust our own last position, and only re-read the real one once the
    /// iPad has been idle long enough that the local mouse may have moved it.
    private var cursor: CGPoint {
        if let p = posted, ProcessInfo.processInfo.systemUptime - p.time < 0.3 { return p.at }
        return CGEvent(source: nil)?.location ?? .zero
    }

    private static let modifierFlags: [UInt16: CGEventFlags] = [
        55: .maskCommand, 54: .maskCommand,
        56: .maskShift, 60: .maskShift,
        58: .maskAlternate, 61: .maskAlternate,
        59: .maskControl, 62: .maskControl,
        63: .maskSecondaryFn,
    ]

    private var flags: CGEventFlags {
        var f = CGEventFlags()
        for k in heldKeys { if let m = Self.modifierFlags[k] { f.insert(m) } }
        if capsLock { f.insert(.maskAlphaShift) }
        return f
    }

    func handle(_ event: InputEvent) {
        switch event {
        case .moveBy(let dx, let dy):
            let p = cursor
            move(to: CGPoint(x: p.x + dx, y: p.y + dy))
        case .moveTo(let x, let y):
            let b = bounds
            move(to: CGPoint(x: b.minX + x * b.width, y: b.minY + y * b.height))
        case .button(let button, let down):
            press(button, down: down)
        case .scroll(let dx, let dy):
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        case .key(let code, let down):
            key(code, down: down)
        case .text(let text):
            type(text)
        case .releaseAll:
            releaseAll()
        }
    }

    func releaseAll() {
        for b in buttons { press(b, down: false) }
        for k in heldKeys { key(k, down: false) }
    }

    private func move(to target: CGPoint) {
        let b = bounds
        let p = CGPoint(x: min(max(target.x, b.minX), b.maxX - 1), y: min(max(target.y, b.minY), b.maxY - 1))
        let (type, button): (CGEventType, CGMouseButton) =
            buttons.contains(.left) ? (.leftMouseDragged, .left) :
            buttons.contains(.right) ? (.rightMouseDragged, .right) :
            buttons.contains(.middle) ? (.otherMouseDragged, .center) : (.mouseMoved, .left)
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
        posted = (p, ProcessInfo.processInfo.systemUptime)
    }

    private func press(_ button: MouseButton, down: Bool) {
        if down { buttons.insert(button) } else if buttons.remove(button) == nil { return }
        let p = cursor
        let now = ProcessInfo.processInfo.systemUptime

        var count = 1
        if down {
            if let last = lastDown, last.button == button, now - last.time < NSEvent.doubleClickInterval,
               hypot(last.at.x - p.x, last.at.y - p.y) < 5 {
                count = last.count + 1
            }
            lastDown = (button, now, p, count)
        } else {
            count = lastDown?.count ?? 1
        }

        let (type, cg): (CGEventType, CGMouseButton) = switch (button, down) {
        case (.left, true): (.leftMouseDown, .left)
        case (.left, false): (.leftMouseUp, .left)
        case (.right, true): (.rightMouseDown, .right)
        case (.right, false): (.rightMouseUp, .right)
        case (.middle, true): (.otherMouseDown, .center)
        case (.middle, false): (.otherMouseUp, .center)
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cg) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private func key(_ code: UInt16, down: Bool) {
        if code == 57 { // caps lock toggles on press
            if down { capsLock.toggle() } else { return }
        } else if down {
            heldKeys.insert(code)
        } else if heldKeys.remove(code) == nil {
            return
        }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        if Self.modifierFlags[code] != nil || code == 57 { e.type = .flagsChanged }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private func type(_ text: String) {
        for part in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if part.offset > 0 { tap(36) } // Return
            let units = Array(part.element.utf16)
            // CGEventKeyboardSetUnicodeString silently truncates past 20 UTF-16 units.
            var i = 0
            while i < units.count {
                var chunk = Array(units[i..<min(i + 20, units.count)])
                // Don't split a surrogate pair across events.
                if let last = chunk.last, UTF16.isLeadSurrogate(last), i + chunk.count < units.count { chunk.removeLast() }
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                    chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                    e.post(tap: .cghidEventTap)
                }
                i += chunk.count
            }
        }
    }

    private func tap(_ code: UInt16) {
        key(code, down: true)
        key(code, down: false)
    }
}
