import Foundation

/// iPadOS keeps ⌘Tab and ⌘Space for itself: with a hardware keyboard the app
/// never sees them, and the iPad switches apps or opens its own Spotlight
/// instead. (Jump Desktop hits the same wall and uses the same answer.)
/// ⌥ stands in for ⌘ on those keys:
///
///   ⌥Tab    the Mac's ⌘Tab switcher. Keep holding ⌥ and tap Tab (⇧ to go
///           back); releasing ⌥ releases ⌘ and switches, exactly as on a Mac.
///   ⌥`      ⌘`, next window of the same app; holds like ⌥Tab.
///   ⌥Space  ⌘Space, Spotlight.
///
/// Every other key, and ⌥ with anything else, passes through unchanged, so
/// ⌥-letter characters and ⌥-arrow word jumps still work.
struct KeyRemapper {
    static let options: Set<UInt16> = [58, 61] // left, right ⌥
    static let command: UInt16 = 55
    static let tab: UInt16 = 48
    static let grave: UInt16 = 50
    static let space: UInt16 = 49

    /// The ⌥ key physically held, if any.
    private(set) var optionHeld: UInt16?
    /// ⌘ is down on the Mac in place of ⌥ (the switcher is open).
    private(set) var switching = false
    /// ⌥Space was turned into ⌘Space; swallow its repeats and its release.
    private var spaceMapped = false

    typealias Key = (code: UInt16, down: Bool)

    mutating func handle(_ code: UInt16, down: Bool) -> [Key] {
        if Self.options.contains(code) {
            if down {
                optionHeld = code
                return [(code, true)]
            }
            optionHeld = nil
            if switching {
                // ⌥ is already up on the Mac; letting go of ⌘ picks the app.
                switching = false
                return [(Self.command, false)]
            }
            return [(code, false)]
        }

        if code == Self.space && spaceMapped {
            if !down { spaceMapped = false }
            return [] // held-key repeats would toggle Spotlight on and off
        }

        guard let option = optionHeld else { return [(code, down)] }

        switch code {
        case Self.tab, Self.grave:
            var out: [Key] = []
            if down && !switching {
                switching = true
                out += [(option, false), (Self.command, true)]
            }
            out.append((code, down))
            return out
        case Self.space where down && !switching:
            spaceMapped = true
            // Put ⌥ back afterwards: it is still physically held.
            return [(option, false), (Self.command, true), (Self.space, true), (Self.space, false), (Self.command, false), (option, true)]
        default:
            return [(code, down)]
        }
    }

    /// The app lost focus; whatever is held will be released wholesale.
    mutating func reset() { self = KeyRemapper() }
}
