import ColorSync
import CoreGraphics
import Foundation

/// The Dock's own "swipe between desktops" and "Mission Control" gestures,
/// synthesized the way a trackpad delivers them.
///
/// There is no public API for this. The event layout comes from Mac Mouse Fix
/// (TouchSimulator.m) and was checked on macOS 26.2: an offset of +1.25 moved
/// from desktop 1 to 2 of 5, -1.25 moved back; a vertical +1.0 opened Mission
/// Control and -1.0 closed it. macOS 27 ignores these fields and reads an
/// IOHIDEvent attached to the event instead (Mac Mouse Fix f92d2d53a), so there
/// the Dock event carries one of those too, and the gesture event is dropped.
/// Its progress runs the opposite way to the old offset: on macOS 27.2 a positive
/// value moved from desktop 2 of 3 to desktop 1.
enum DockSwipe {
    enum Phase: Int {
        // IOHIDEventPhaseBits
        case began = 1, changed = 2, ended = 4, cancelled = 8
    }

    /// The events the Dock expects for one step of a swipe.
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
        if #available(macOS 27, *),
           DockSwipeHID.attach(to: dock, motion: Int(type), phase: phase, offset: offset, exitSpeed: exitSpeed) {
            return [dock]
        }
        return [dock, gesture]
    }

    /// How much offset moves one desktop, which depends on how many there are
    /// (Mac Mouse Fix: 2 spaces -> 2.0, 5 -> 1.25).
    static func offsetPerSpace(spaces: Int) -> Double {
        spaces <= 1 ? 2 : 1 + 1 / Double(spaces - 1)
    }
}

/// The IOHIDEvent macOS 27's Dock reads, built with private IOKit and SkyLight
/// calls, looked up at runtime so a missing symbol is a nil, not a crash.
enum DockSwipeHID {
    private typealias Create = @convention(c) (CFAllocator?, UInt32, UInt64, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias SetInteger = @convention(c) (CFTypeRef, UInt32, Int) -> Void
    private typealias SetDouble = @convention(c) (CFTypeRef, UInt32, Double) -> Void
    private typealias Append = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
    // Copies the event's contents, so the caller keeps (and releases) its own reference.
    private typealias Attach = @convention(c) (CGEvent, CFTypeRef) -> Void

    // IOHIDEventTypes.h and IOHIDEventFieldDefs.h. A field is its event type << 16 | index.
    private static let dockSwipeType: UInt32 = 23, velocityType: UInt32 = 9
    private static let motion = dockSwipeType << 16 | 1, progress = dockSwipeType << 16 | 2, flavor = dockSwipeType << 16 | 5
    private static let velocityX = velocityType << 16, velocityY = velocityType << 16 | 1
    private static let flavorDockPrimary = 3
    private static let phaseShift: UInt32 = 24

    private static let calls: (Create, SetInteger, SetDouble, Append, Attach)? = {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let create = dlsym(iokit, "IOHIDEventCreate"), let setInteger = dlsym(iokit, "IOHIDEventSetIntegerValue"),
              let setDouble = dlsym(iokit, "IOHIDEventSetDoubleValue"), let append = dlsym(iokit, "IOHIDEventAppendEvent"),
              let attach = dlsym(sl, "SLEventSetIOHIDEvent") else {
            NSLog("RemoteMac: IOHIDEvent calls unavailable; swipes won't reach the Dock on macOS 27")
            return nil
        }
        return (unsafeBitCast(create, to: Create.self), unsafeBitCast(setInteger, to: SetInteger.self),
                unsafeBitCast(setDouble, to: SetDouble.self), unsafeBitCast(append, to: Append.self),
                unsafeBitCast(attach, to: Attach.self))
    }()

    /// False if the private calls are missing.
    static func attach(to event: CGEvent, motion swipeMotion: Int, phase: DockSwipe.Phase, offset: Double, exitSpeed: Double) -> Bool {
        guard let (create, setInteger, setDouble, append, attach) = calls,
              let hid = create(nil, dockSwipeType, 0, UInt32(phase.rawValue) << phaseShift)?.takeRetainedValue() else { return false }
        setInteger(hid, motion, swipeMotion)
        setInteger(hid, flavor, flavorDockPrimary)
        setDouble(hid, progress, -offset)
        if phase == .ended || phase == .cancelled, let velocity = create(nil, velocityType, 0, 0)?.takeRetainedValue() {
            setDouble(velocity, velocityX, -exitSpeed)
            setDouble(velocity, velocityY, -exitSpeed)
            append(hid, velocity, 0)
        }
        attach(event, hid)
        return true
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
