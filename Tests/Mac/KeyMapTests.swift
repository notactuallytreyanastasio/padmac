import Carbon.HIToolbox
import XCTest

/// Checks the iPad's HID -> Mac key code table against macOS itself: each Mac
/// code is translated through the real US keyboard layout and must produce the
/// character the USB HID spec assigns to that usage.
final class KeyMapTests: XCTestCase {
    private var layout: UnsafePointer<UCKeyboardLayout>!
    private var layoutData: CFData!

    override func setUpWithError() throws {
        let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US"] as CFDictionary
        let list = try XCTUnwrap(TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])
        let us = try XCTUnwrap(list.first, "US layout not installed")
        let raw = try XCTUnwrap(TISGetInputSourceProperty(us, kTISPropertyUnicodeKeyLayoutData))
        layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        layout = UnsafeRawPointer(CFDataGetBytePtr(layoutData)).assumingMemoryBound(to: UCKeyboardLayout.self)
    }

    private func type(_ code: UInt16, shift: Bool = false) -> String {
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let mods: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                       OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        return String(utf16CodeUnits: chars, count: len)
    }

    /// USB HID Usage Tables, Keyboard/Keypad page (0x07).
    private let hidCharacters: [Int: String] = {
        var m: [Int: String] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { m[4 + i] = String(c) }
        for (i, c) in "1234567890".enumerated() { m[30 + i] = String(c) }
        let rest: [Int: String] = [44: " ", 45: "-", 46: "=", 47: "[", 48: "]", 49: "\\", 51: ";", 52: "'", 53: "`", 54: ",", 55: ".", 56: "/",
                                   84: "/", 85: "*", 86: "-", 87: "+", 89: "1", 90: "2", 91: "3", 92: "4", 93: "5", 94: "6", 95: "7", 96: "8", 97: "9", 98: "0", 99: "."]
        return m.merging(rest) { a, _ in a }
    }()

    func testPrintableKeysProduceTheirHIDCharacterOnAUSMac() throws {
        for (usage, expected) in hidCharacters.sorted(by: { $0.key < $1.key }) {
            let code = try XCTUnwrap(KeyMap.hidToMac[usage], "HID usage \(usage) (\(expected)) is not mapped")
            XCTAssertEqual(type(code), expected, "HID usage \(usage) -> Mac key \(code)")
        }
    }

    func testNamedKeysMatchCarbonConstants() {
        let named: [Int: Int] = [
            40: kVK_Return, 41: kVK_Escape, 42: kVK_Delete, 43: kVK_Tab, 57: kVK_CapsLock,
            58: kVK_F1, 63: kVK_F6, 69: kVK_F12, 104: kVK_F13, 111: kVK_F20,
            74: kVK_Home, 75: kVK_PageUp, 76: kVK_ForwardDelete, 77: kVK_End, 78: kVK_PageDown,
            79: kVK_RightArrow, 80: kVK_LeftArrow, 81: kVK_DownArrow, 82: kVK_UpArrow,
            88: kVK_ANSI_KeypadEnter, 100: kVK_ISO_Section,
            224: kVK_Control, 225: kVK_Shift, 226: kVK_Option, 227: kVK_Command,
            228: kVK_RightControl, 229: kVK_RightShift, 230: kVK_RightOption, 231: kVK_RightCommand,
        ]
        for (usage, vk) in named {
            XCTAssertEqual(KeyMap.hidToMac[usage].map(Int.init), vk, "HID usage \(usage)")
        }
    }

    func testModifierSetMatchesTheModifierKeys() {
        for usage in 224...231 {
            XCTAssertTrue(KeyMap.modifiers.contains(KeyMap.hidToMac[usage]!), "HID \(usage)")
        }
        XCTAssertFalse(KeyMap.modifiers.contains(KeyMap.hidToMac[4]!))
    }

    func testOnScreenKeyboardCharactersRoundTrip() throws {
        // keyFor(character:) is used when a sticky modifier is on (⌘ then "c").
        let all = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890!@#$%^&*()-=_+[]{}\\|;:'\",.<>/?`~ "
        for c in all {
            let k = try XCTUnwrap(KeyMap.keyFor(character: c), "no key for \(c)")
            XCTAssertEqual(type(k.code, shift: k.shift), String(c), "\(c) -> key \(k.code) shift \(k.shift)")
        }
        XCTAssertNil(KeyMap.keyFor(character: "é"))
    }
}
