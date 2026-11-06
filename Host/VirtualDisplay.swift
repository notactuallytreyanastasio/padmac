import CoreGraphics
import Foundation
import ObjectiveC

/// A display that exists only for the iPad, shaped like its window, so the Mac
/// fills the iPad instead of being letterboxed inside it. Retina: one iPad
/// point is one Mac point, and the Mac renders two pixels for it.
///
/// There is no public API for this. CGVirtualDisplay's classes live in
/// CoreGraphics and are looked up at runtime, so a missing one is a nil, not a
/// crash. Checked on macOS 27.2. macOS removes the display when this is freed
/// or the host exits, and moves its windows to another display.
final class VirtualDisplay {
    private typealias ModeInit = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
    private typealias DisplayInit = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject) -> Unmanaged<AnyObject>?
    private typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool

    let id: CGDirectDisplayID
    private(set) var size: FitDisplay
    private let display: AnyObject

    init?(size: FitDisplay) {
        let initSelector = NSSelectorFromString("initWithDescriptor:")
        guard let descriptor = (NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type)?.init(),
              let cls = NSClassFromString("CGVirtualDisplay"), cls.instancesRespond(to: initSelector),
              let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc")) else { return nil }
        let ended: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in NSLog("RemoteMac: macOS ended the virtual display") }
        descriptor.perform(NSSelectorFromString("setDispatchQueue:"), with: DispatchQueue.main)
        descriptor.setValue(Wire.fitDisplayName, forKey: "name")
        descriptor.setValue(FitDisplay.maxPoints * 2, forKey: "maxPixelsWide")
        descriptor.setValue(FitDisplay.maxPoints * 2, forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: CGSize(width: 262, height: 196)), forKey: "sizeInMillimeters") // a 13-inch iPad
        descriptor.setValue(0x4d41, forKey: "vendorID")
        descriptor.setValue(0x1234, forKey: "productID")
        descriptor.setValue(1, forKey: "serialNum")
        descriptor.setValue(unsafeBitCast(ended, to: AnyObject.self), forKey: "terminationHandler")

        let create = unsafeBitCast(class_getMethodImplementation(cls, initSelector), to: DisplayInit.self)
        guard let display = create(allocated.toOpaque(), initSelector, descriptor)?.takeRetainedValue(),
              let id = (display as? NSObject)?.value(forKey: "displayID") as? CGDirectDisplayID, id != 0 else { return nil }
        self.display = display
        self.id = id
        self.size = size
        guard apply(size) else { return nil }
    }

    /// False if macOS refused the size.
    func resize(to size: FitDisplay) -> Bool {
        guard size != self.size else { return true }
        guard apply(size) else { return false }
        self.size = size
        return true
    }

    private func apply(_ size: FitDisplay) -> Bool {
        let modeSelector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let applySelector = NSSelectorFromString("applySettings:")
        guard let settings = (NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type)?.init(),
              let cls = NSClassFromString("CGVirtualDisplayMode"), cls.instancesRespond(to: modeSelector),
              let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc")),
              let displayClass: AnyClass = object_getClass(display), display.responds(to: applySelector) else { return false }
        let create = unsafeBitCast(class_getMethodImplementation(cls, modeSelector), to: ModeInit.self)
        guard let mode = create(allocated.toOpaque(), modeSelector, UInt32(size.width), UInt32(size.height), 60)?.takeRetainedValue() else { return false }
        settings.setValue(1, forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")
        let apply = unsafeBitCast(class_getMethodImplementation(displayClass, applySelector), to: Apply.self)
        return apply(display, applySelector, settings)
    }
}

/// Holds the virtual display across reconnects. iOS drops the socket whenever
/// the app is backgrounded, and if the display went with it, every window on it
/// would land on the Mac's own screen. Main thread only.
///
/// A reconnect can arrive before the old socket is noticed dead, so the display
/// remembers which session has it, and an older session can't take it away.
final class FitDisplayKeeper {
    static let shared = FitDisplayKeeper()
    /// How long the display outlives a dropped connection. `-fitGrace N` shortens it for tests.
    static var grace: TimeInterval {
        let set = UserDefaults.standard.double(forKey: "fitGrace")
        return set > 0 ? set : 60
    }

    private var display: VirtualDisplay?
    private var owner: ObjectIdentifier?
    private var removal: DispatchWorkItem?
    /// Windows brought onto the display, and where they came from.
    private var moved: [(id: CGWindowID, pid: pid_t, frame: CGRect)] = []

    func acquire(_ size: FitDisplay, for session: ObjectIdentifier) -> CGDirectDisplayID? {
        removal?.cancel()
        removal = nil
        owner = session
        if let display, display.resize(to: size) { return display.id }
        display = nil // refused the new size: make one that has it
        let modes = Self.currentModes()
        display = VirtualDisplay(size: size)
        if display == nil { NSLog("RemoteMac: could not create a virtual display") }
        // macOS remembers a resolution per combination of displays, so a new
        // display can knock the Mac's own one down (a 5120x1440 screen went to
        // 1920x1080). It applies that a moment later, hence the wait. Without the
        // virtual display macOS goes back to its memory for that combination.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Self.restore(modes) }
        // A new display is empty, and the iPad can't see the others to drag anything over.
        if let id = display?.id {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.bringFrontWindow(to: id) }
        }
        return display?.id
    }

    /// The window in front, cut down to fit if it must be. Only that one: bringing
    /// them all left the Mac's own screen empty and every window shrunk.
    private func bringFrontWindow(to id: CGDirectDisplayID) {
        guard display?.id == id, !UserDefaults.standard.bool(forKey: "dryRunWindows") else { return }
        let bounds = CGDisplayBounds(id)
        let visible = MainActor.assumeIsolated { WindowList.visibleFrame(at: CGPoint(x: bounds.midX, y: bounds.midY)) } ?? bounds
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var done: [(id: CGWindowID, pid: pid_t, frame: CGRect)] = []
            if let w = WindowList.switchable().first(where: { $0.onScreen && !bounds.intersects($0.frame) }),
               let el = AXWindow.element(pid: w.pid, id: w.id) {
                let size = CGSize(width: min(w.frame.width, visible.width), height: min(w.frame.height, visible.height))
                AXWindow.setFrame(el, WindowFit.place(size, from: visible, in: visible), pid: w.pid)
                done.append((w.id, w.pid, w.frame))
            }
            DispatchQueue.main.async { self?.moved += done }
        }
    }

    /// Windows go back first, so macOS doesn't shuffle them off the display as it goes.
    private func remove() {
        let windows = moved
        moved = []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for w in windows {
                if let el = AXWindow.element(pid: w.pid, id: w.id) { AXWindow.setFrame(el, w.frame, pid: w.pid) }
            }
            DispatchQueue.main.async { if self?.owner == nil { self?.display = nil } }
        }
    }

    private static func currentModes() -> [(CGDirectDisplayID, CGDisplayMode)] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { id in CGDisplayCopyDisplayMode(id).map { (id, $0) } }
    }

    private static func restore(_ modes: [(CGDirectDisplayID, CGDisplayMode)]) {
        let changed = modes.filter { id, mode in
            guard CGDisplayIsOnline(id) != 0, let now = CGDisplayCopyDisplayMode(id) else { return false }
            return now.ioDisplayModeID != mode.ioDisplayModeID
        }
        guard !changed.isEmpty else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for (id, mode) in changed { CGConfigureDisplayWithDisplayMode(config, id, mode, nil) }
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        if result != .success { NSLog("RemoteMac: could not restore display modes: \(result.rawValue)") }
    }

    func release(for session: ObjectIdentifier, after delay: TimeInterval) {
        guard owner == session else { return }
        owner = nil
        removal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.remove() }
        removal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
