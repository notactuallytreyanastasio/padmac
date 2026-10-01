import AppKit
import CoreGraphics

/// Turns InputEvents into CGEvents posted at the HID level. Needs Accessibility permission.
///
/// Modifier state is tracked here and stamped onto every event explicitly.
/// Posting a flagsChanged event for Command does not make the next synthesized
/// key event carry the Command flag, so without this Cmd-C arrives as plain "c".
final class InputInjector {
    /// Where events go and where the world is read from. Tests replace it to
    /// capture events instead of moving the real cursor.
    struct System {
        var post: (CGEvent) -> Void
        /// Gesture events go to the session tap, where the Dock listens.
        var postGesture: (CGEvent) -> Void
        var after: (TimeInterval, @escaping () -> Void) -> Void
        var spaces: (CGDirectDisplayID) -> Int?
        var bounds: (CGDirectDisplayID) -> CGRect
        var cursor: () -> CGPoint
        var now: () -> TimeInterval
        var doubleClickInterval: TimeInterval

        static let live = System(
            post: { $0.post(tap: .cghidEventTap) },
            postGesture: { $0.post(tap: .cgSessionEventTap) },
            after: { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) },
            spaces: { Spaces.count(on: $0) },
            bounds: { CGDisplayBounds($0) },
            cursor: { CGEvent(source: nil)?.location ?? .zero },
            now: { ProcessInfo.processInfo.systemUptime },
            doubleClickInterval: NSEvent.doubleClickInterval)
    }

    var displayID: CGDirectDisplayID
    private let system: System
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttons = Set<MouseButton>()
    private var heldKeys = Set<UInt16>()
    private var capsLock = false
    private var lastDown: (button: MouseButton, time: TimeInterval, at: CGPoint, count: Int)?
    private var swipeState: (axis: SwipeAxis, offset: Double, lastDelta: Double)?
    private var scrollRemainder = (x: 0.0, y: 0.0)
    private var swipeGeneration = 0

    init(displayID: CGDirectDisplayID, system: System = .live) {
        self.displayID = displayID
        self.system = system
    }

    private var bounds: CGRect { system.bounds(displayID) }

    private var posted: (at: CGPoint, time: TimeInterval)?

    /// Where the cursor is, for the purpose of the next event.
    ///
    /// Reading the real cursor back right after posting a move returns the old
    /// position: the window server has not applied it yet. A burst of relative
    /// moves built on that loses deltas (20 x +10 arrived as +120). So during a
    /// burst trust our own last position, and only re-read the real one once the
    /// iPad has been idle long enough that the local mouse may have moved it.
    private var cursor: CGPoint {
        if let p = posted, system.now() - p.time < 0.3 { return p.at }
        return system.cursor()
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
        case .scroll(let dx, let dy, let phase, let momentum):
            scroll(dx, dy, phase, momentum)
        case .key(let code, let down):
            key(code, down: down)
        case .text(let text):
            type(text)
        case .swipe(let axis, let phase, let distance):
            swipe(axis, phase, distance)
        case .releaseAll:
            releaseAll()
        }
    }

    func releaseAll() {
        for b in buttons { press(b, down: false) }
        for k in heldKeys { key(k, down: false) }
        // A swipe left open leaves the Dock stuck between two desktops.
        if let s = swipeState { swipe(s.axis, .cancelled, 0) }
    }

    /// Scroll events only carry whole pixels. Rounding each one dropped the slow
    /// end of every scroll (0.4px a frame is 0), so the fractions carry over.
    private func scroll(_ dx: Double, _ dy: Double, _ phase: GesturePhase?, _ momentum: MomentumPhase?) {
        if phase == .began || momentum == .began { scrollRemainder = (0, 0) }
        let x = dx + scrollRemainder.x, y = dy + scrollRemainder.y
        let ix = x.rounded(.towardZero), iy = y.rounded(.towardZero)
        scrollRemainder = (x - ix, y - iy)
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
        if let phase {
            // CGScrollPhase
            let bits: Int64 = switch phase { case .began: 1; case .changed: 2; case .ended: 4; case .cancelled: 8 }
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: bits)
        }
        if let momentum {
            // CGMomentumScrollPhase
            let v: Int64 = switch momentum { case .began: 1; case .changed: 2; case .ended: 3 }
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: v)
        }
        e.flags = flags
        system.post(e)
    }

    /// Fingers moving left or up give a positive Dock offset: next desktop, Mission Control.
    private func swipe(_ axis: SwipeAxis, _ phase: GesturePhase, _ distance: Double) {
        let scale = axis == .horizontal ? DockSwipe.offsetPerSpace(spaces: system.spaces(displayID) ?? 2) : 1
        let offset = -distance * scale
        switch phase {
        case .began:
            if let s = swipeState { swipe(s.axis, .cancelled, 0) }
            swipeGeneration += 1
            swipeState = (axis, offset, offset)
            postSwipe(axis, .began, offset)
        case .changed:
            guard let s = swipeState, s.axis == axis, offset != s.offset else { return }
            swipeState = (axis, offset, offset - s.offset)
            postSwipe(axis, .changed, offset)
        case .ended, .cancelled:
            guard let s = swipeState else { return }
            swipeState = nil
            // Lifting while moving back toward the start cancels, as on a trackpad.
            var p: DockSwipe.Phase = phase == .ended ? .ended : .cancelled
            if p == .ended && (s.lastDelta < 0) != (s.offset < 0) { p = .cancelled }
            let events = DockSwipe.events(axis: s.axis, phase: p, offset: s.offset, exitSpeed: s.lastDelta * 100)
            events.forEach(system.postGesture)
            // The Dock sometimes drops the end event under load and stays mid-swipe;
            // Mac Mouse Fix found sending it again 0.2s later fixes that.
            let generation = swipeGeneration
            system.after(0.2) { [weak self] in
                guard let self, self.swipeGeneration == generation else { return }
                events.forEach(self.system.postGesture)
            }
        }
    }

    private func postSwipe(_ axis: SwipeAxis, _ phase: DockSwipe.Phase, _ offset: Double) {
        DockSwipe.events(axis: axis, phase: phase, offset: offset).forEach(system.postGesture)
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
        system.post(e)
        posted = (p, system.now())
    }

    private func press(_ button: MouseButton, down: Bool) {
        if down { buttons.insert(button) } else if buttons.remove(button) == nil { return }
        let p = cursor
        let now = system.now()

        var count = 1
        if down {
            if let last = lastDown, last.button == button, now - last.time < system.doubleClickInterval,
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
        system.post(e)
    }

    private func key(_ code: UInt16, down: Bool) {
        var isRepeat = false
        if code == 57 { // caps lock toggles on press
            if down { capsLock.toggle() } else { return }
        } else if down {
            // The iPad repeats held keys by resending key-down.
            isRepeat = !heldKeys.insert(code).inserted
        } else if heldKeys.remove(code) == nil {
            return
        }
        let isModifier = Self.modifierFlags[code] != nil || code == 57
        if isRepeat && isModifier { return }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        if isModifier { e.type = .flagsChanged }
        if isRepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        e.flags = flags
        system.post(e)
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
                    system.post(e)
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
