import ColorSync
import CoreGraphics
import Foundation

/// The Dock's own "swipe between desktops" and "Mission Control" gestures,
/// synthesized the way a trackpad delivers them.
///
/// There is no public API for this. The event layout comes from Mac Mouse Fix
/// (TouchSimulator.m) and was checked on macOS 26.2: an offset of +1.25 moved
/// from desktop 1 to 2 of 5, -1.25 moved back; a vertical +1.0 opened Mission
/// Control and -1.0 closed it. Mac Mouse Fix notes that macOS 27 ignores these
/// fields and needs a private IOHIDEvent instead, which this does not do.
enum DockSwipe {
    enum Phase: Int {
        // IOHIDEventPhaseBits
        case began = 1, changed = 2, ended = 4, cancelled = 8
    }

    /// The two events the Dock expects for one step of a swipe.
    static func events(axis: SwipeAxis, phase: Phase, offset: Double, exitSpeed: Double = 0) -> [CGEvent] {
        let type = axis == .horizontal ? 1.0 : 2.0
        guard let gesture = CGEvent(source: nil), let dock = CGEvent(source: nil) else { return [] }

        func set(_ e: CGEvent, _ field: UInt32, _ v: Double) { e.setDoubleValueField(CGEventField(rawValue: field)!, value: v) }
        set(gesture, 55, 29)                  // NSEventTypeGesture
        set(gesture, 41, 33231)

        set(dock, 55, 30)                     // the Dock-control event type
        set(dock, 110, 23)                    // kIOHIDEventTypeDockSwipe
        set(dock, 132, Double(phase.rawValue))
        set(dock, 134, Double(phase.rawValue))
        set(dock, 124, offset)
        // The same offset again, as the bit pattern of a Float32 in an integer field.
        dock.setIntegerValueField(CGEventField(rawValue: 135)!, value: Int64(Float(offset).bitPattern))
        set(dock, 41, 33231)
        // The swipe type, encoded as the bit pattern of a tiny float (1 -> 1.4e-45).
        let encodedType = Double(Float(bitPattern: UInt32(type)))
        set(dock, 119, encodedType)
        set(dock, 139, encodedType)
        set(dock, 123, type)
        set(dock, 165, type)
        dock.setIntegerValueField(CGEventField(rawValue: 136)!, value: 0)
        if phase == .ended || phase == .cancelled {
            set(dock, 129, exitSpeed)
            set(dock, 130, exitSpeed)
        }
        return [dock, gesture]
    }

    /// How much offset moves one desktop, which depends on how many there are
    /// (Mac Mouse Fix: 2 spaces -> 2.0, 5 -> 1.25).
    static func offsetPerSpace(spaces: Int) -> Double {
        spaces <= 1 ? 2 : 1 + 1 / Double(spaces - 1)
    }
}

/// Read-only access to Spaces through private SkyLight calls, looked up at
/// runtime so a missing symbol is a nil, not a crash.
enum Spaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let calls: (MainConnection, CopyManagedDisplaySpaces)? = {
        guard let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let main = dlsym(sl, "CGSMainConnectionID"), let copy = dlsym(sl, "CGSCopyManagedDisplaySpaces") else {
            NSLog("RemoteMac: SkyLight Spaces calls unavailable; swipes assume 2 desktops")
            return nil
        }
        return (unsafeBitCast(main, to: MainConnection.self), unsafeBitCast(copy, to: CopyManagedDisplaySpaces.self))
    }()

    private static func entry(for display: CGDirectDisplayID) -> [String: Any]? {
        guard let (main, copy) = calls,
              let all = copy(main())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let uuid = CGDisplayCreateUUIDFromDisplayID(display).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
        // With "Displays have separate Spaces" off there is one entry, called "Main".
        return all.first { ($0["Display Identifier"] as? String) == uuid } ?? (all.count == 1 ? all[0] : nil)
    }

    /// Desktops and full-screen apps on a display, in order.
    static func count(on display: CGDirectDisplayID) -> Int? {
        (entry(for: display)?["Spaces"] as? [Any])?.count
    }

    /// Position of the active space on a display (0-based).
    static func activeIndex(on display: CGDirectDisplayID) -> Int? {
        guard let e = entry(for: display), let spaces = e["Spaces"] as? [[String: Any]],
              let current = (e["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int else { return nil }
        return spaces.firstIndex { ($0["ManagedSpaceID"] as? Int) == current }
    }
}
