import Foundation

/// The wire format shared by the Mac host and the iPad client.
///
/// Every message is `[type: u8][length: u32 big-endian][payload]`, carried over
/// TLS-PSK on TCP. Video and cursor payloads are raw bytes; the rest is JSON or text.
enum Wire {
    static let serviceType = "_remotemac._tcp"
    static let port: UInt16 = 47428
    static let headerSize = 5
    static let maxPayload = 32 << 20
}

enum MessageType: UInt8 {
    // host -> client
    case screenInfo = 0x01
    /// `[u8 codec][u8 count]` then per parameter set `[u16 length][bytes]` (see VideoFormatPayload)
    case videoFormat = 0x02
    /// `[u8 flags][4-byte length-prefixed NAL units]`, flags bit 0 = keyframe
    case videoFrame = 0x03
    /// UTF-8 text: why the host is about to close the connection.
    case error = 0x04
    /// Two big-endian Float32: cursor position normalised to the streamed display.
    case cursor = 0x06

    // both directions
    /// UTF-8 text now on the sender's clipboard.
    case clipboard = 0x05

    // client -> host
    case hello = 0x10
    case input = 0x11
    case requestKeyframe = 0x12
    /// JSON `SelectDisplay`
    case selectDisplay = 0x13
}

enum VideoCodec: String, Codable {
    case h264, hevc
}

struct DisplayInfo: Codable, Equatable, Identifiable {
    var id: UInt32
    var name: String
    var width: Double
    var height: Double
}

struct ScreenInfo: Codable, Equatable {
    var displayID: UInt32
    var displayName: String
    var codec: VideoCodec
    /// Encoded video size in pixels.
    var streamWidth: Int
    var streamHeight: Int
    /// The Mac display's size in points (the coordinate space input uses).
    var screenWidth: Double
    var screenHeight: Double
    /// Every display the client can switch to.
    var displays: [DisplayInfo]
}

struct Hello: Codable {
    var clientName: String
    /// Largest video size the client wants, in pixels. The host fits the display inside it.
    var maxWidth: Int
    var maxHeight: Int
    /// Decodable codecs in order of preference. Absent means H.264 only.
    var codecs: [VideoCodec]?
    /// Display to start on; absent means the Mac's main display.
    var displayID: UInt32?
}

struct SelectDisplay: Codable {
    var displayID: UInt32
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
    static func encode(codec: VideoCodec, parameterSets: [Data]) -> Data {
        var d = Data([codec == .hevc ? 1 : 0, UInt8(parameterSets.count)])
        for p in parameterSets { d.appendBE16(UInt16(p.count)); d.append(p) }
        return d
    }

    static func decode(_ data: Data) -> (codec: VideoCodec, parameterSets: [Data])? {
        let b = [UInt8](data)
        guard b.count >= 2, b[0] <= 1 else { return nil }
        var sets: [Data] = []
        var i = 2
        for _ in 0..<Int(b[1]) {
            guard i + 2 <= b.count else { return nil }
            let n = Int(b[i]) << 8 | Int(b[i + 1])
            guard i + 2 + n <= b.count else { return nil }
            sets.append(Data(b[(i + 2)..<(i + 2 + n)]))
            i += 2 + n
        }
        guard i == b.count, !sets.isEmpty else { return nil }
        return (b[0] == 1 ? .hevc : .h264, sets)
    }
}

enum CursorPayload {
    static func encode(x: Float, y: Float) -> Data {
        var d = Data()
        for v in [x, y] { withUnsafeBytes(of: v.bitPattern.bigEndian) { d.append(contentsOf: $0) } }
        return d
    }

    static func decode(_ data: Data) -> (x: Double, y: Double)? {
        let b = [UInt8](data)
        guard b.count == 8 else { return nil }
        func f(_ i: Int) -> Double {
            Double(Float(bitPattern: UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])))
        }
        return (f(0), f(4))
    }
}
