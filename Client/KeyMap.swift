import Foundation

/// USB HID usage (what UIKey.keyCode reports) to Mac virtual key code (kVK_*).
enum KeyMap {
    static let hidToMac: [Int: UInt16] = {
        var m: [Int: UInt16] = [:]
        let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        for (i, code) in letters.enumerated() { m[4 + i] = code }            // a...z
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        for (i, code) in digits.enumerated() { m[30 + i] = code }            // 1...9, 0
        let fkeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in fkeys.enumerated() { m[58 + i] = code }             // F1...F12
        let rest: [Int: UInt16] = [
            40: 36, 41: 53, 42: 51, 43: 48, 44: 49, 45: 27, 46: 24, 47: 33, 48: 30, 49: 42, 50: 42,
            51: 41, 52: 39, 53: 50, 54: 43, 55: 47, 56: 44, 57: 57,
            73: 114, 74: 115, 75: 116, 76: 117, 77: 119, 78: 121,
            79: 124, 80: 123, 81: 125, 82: 126,
            83: 71, 84: 75, 85: 67, 86: 78, 87: 69, 88: 76,
            89: 83, 90: 84, 91: 85, 92: 86, 93: 87, 94: 88, 95: 89, 96: 91, 97: 92, 98: 82, 99: 65,
            100: 10, 103: 81,
            104: 105, 105: 107, 106: 113, 107: 106, 108: 64, 109: 79, 110: 80, 111: 90,
            144: 104, 145: 102,
            224: 59, 225: 56, 226: 58, 227: 55, 228: 62, 229: 60, 230: 61, 231: 54,
        ]
        m.merge(rest) { a, _ in a }
        return m
    }()

    static let modifiers: Set<UInt16> = [55, 54, 56, 60, 58, 61, 59, 62, 57, 63]

    /// For the on-screen keyboard: a character typed while a sticky modifier is
    /// on has to go as a key press (Cmd-C), not as text. US layout.
    static func keyFor(character c: Character) -> (code: UInt16, shift: Bool)? {
        let plain = "abcdefghijklmnopqrstuvwxyz1234567890-=[]\\;',./` "
        let shifted = "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()_+{}|:\"<>?~"
        let plainHID = Array(4...29) + Array(30...39) + [45, 46, 47, 48, 49, 51, 52, 54, 55, 56, 53, 44]
        let shiftedHID = Array(4...29) + Array(30...39) + [45, 46, 47, 48, 49, 51, 52, 54, 55, 56, 53]
        if let i = plain.firstIndex(of: c) { return hidToMac[plainHID[plain.distance(from: plain.startIndex, to: i)]].map { ($0, false) } }
        if let i = shifted.firstIndex(of: c) { return hidToMac[shiftedHID[shifted.distance(from: shifted.startIndex, to: i)]].map { ($0, true) } }
        return nil
    }
}
