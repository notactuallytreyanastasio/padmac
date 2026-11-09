import CoreGraphics
import Darwin
import Foundation

/// Window numbers are only meaningful while that app process and Mac boot live.
struct RememberedWindow: Codable, Equatable {
    var id: CGWindowID
    var pid: pid_t
    var app: String
    var boot: Int64

    func restoredID(in windows: [MacWindow]) -> CGWindowID? {
        windows.first { $0.id == id && $0.pid == pid && $0.app == app }?.id
    }
}

/// Stored on the Mac, so reconnecting by Bonjour or by a VPN address restores
/// the same selection without requiring another client update.
final class RememberedWindowStore {
    private let defaults: UserDefaults
    private let boot: Int64?
    private static let prefix = "lastWindow."

    init(defaults: UserDefaults = .standard, boot: Int64? = RememberedWindowStore.currentBoot()) {
        self.defaults = defaults; self.boot = boot
    }
    func load(client: String) -> RememberedWindow? {
        guard let boot, let data = defaults.data(forKey: Self.prefix + client),
              let selection = try? JSONDecoder().decode(RememberedWindow.self, from: data),
              selection.boot == boot else { return nil }
        return selection
    }
    func remember(_ window: MacWindow, client: String) {
        guard let boot else { return }
        let selection = RememberedWindow(id: window.id, pid: window.pid, app: window.app, boot: boot)
        defaults.set(try? JSONEncoder().encode(selection), forKey: Self.prefix + client)
    }
    static func currentBoot() -> Int64? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return nil }
        return Int64(value.tv_sec)
    }
}
