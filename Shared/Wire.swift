import Foundation

/// The wire format shared by the Mac host and the iPad client.
///
/// Every message is `[type: u8][length: u32 big-endian][payload]`, carried over
/// TLS-PSK on TCP. Video payloads are raw bytes; everything else is JSON.
enum Wire {
    static let serviceType = "_remotemac._tcp"
    static let port: UInt16 = 47428
    static let headerSize = 5
    static let maxPayload = 32 << 20
}

enum MessageType: UInt8 {
    // host -> client
    case screenInfo = 0x01
    /// `[u16 sps length][sps][u16 pps length][pps]`
    case videoFormat = 0x02
    /// `[u8 flags][AVCC data: 4-byte length-prefixed NAL units]`, flags bit 0 = keyframe
    case videoFrame = 0x03
    /// UTF-8 text: why the host is about to close the connection.
    case error = 0x04

    // client -> host
    case hello = 0x10
    case input = 0x11
    case requestKeyframe = 0x12
}

struct ScreenInfo: Codable, Equatable {
    var displayName: String
    /// Encoded video size in pixels.
    var streamWidth: Int
    var streamHeight: Int
    /// The Mac display's size in points (the coordinate space input uses).
    var screenWidth: Double
    var screenHeight: Double
}

struct Hello: Codable {
    var clientName: String
    /// Largest video size the client wants, in pixels. The host fits the display inside it.
    var maxWidth: Int
    var maxHeight: Int
}

enum MouseButton: Int, Codable {
    case left, right, middle
}

enum InputEvent: Codable, Equatable {
    /// Relative pointer motion in Mac points (trackpad mode).
    case moveBy(dx: Double, dy: Double)
    /// Absolute pointer position, normalised 0...1 across the streamed display.
    case moveTo(x: Double, y: Double)
    case button(MouseButton, down: Bool)
    /// Scroll in pixels; positive dy moves content down (like a finger dragging it).
    case scroll(dx: Double, dy: Double)
    /// A Mac virtual key code (kVK_*), pressed or released.
    case key(code: UInt16, down: Bool)
    /// Literal text, typed as unicode regardless of the Mac's keyboard layout.
    case text(String)
    /// Release every button and key the host believes is held.
    case releaseAll
}

extension Data {
    mutating func appendBE16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xff)) }
}

enum VideoFormatPayload {
    static func encode(sps: Data, pps: Data) -> Data {
        var d = Data()
        d.appendBE16(UInt16(sps.count)); d.append(sps)
        d.appendBE16(UInt16(pps.count)); d.append(pps)
        return d
    }

    static func decode(_ data: Data) -> (sps: Data, pps: Data)? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }
        let spsLen = Int(b[0]) << 8 | Int(b[1])
        guard b.count >= 2 + spsLen + 2 else { return nil }
        let ppsAt = 2 + spsLen
        let ppsLen = Int(b[ppsAt]) << 8 | Int(b[ppsAt + 1])
        guard b.count == ppsAt + 2 + ppsLen else { return nil }
        return (Data(b[2..<ppsAt]), Data(b[(ppsAt + 2)...]))
    }
}
