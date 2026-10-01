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
    /// See `FramePayload`.
    case videoFrame = 0x03
    /// UTF-8 text: why the host is about to close the connection.
    case error = 0x04
    /// Two big-endian Float32: cursor position normalised to the streamed display.
    case cursor = 0x06
    /// See `AudioPayload`. Only sent to a client whose Hello asked for audio.
    case audio = 0x07

    // both directions
    /// UTF-8 text now on the sender's clipboard.
    case clipboard = 0x05
    /// PNG image now on the sender's clipboard (at most 16 MB).
    case clipboardImage = 0x08

    // client -> host
    case hello = 0x10
    case input = 0x11
    case requestKeyframe = 0x12
    /// JSON `SelectDisplay`
    case selectDisplay = 0x13
    /// One byte: 1 to receive audio, 0 to stop (the iPad's speaker button).
    case audioEnabled = 0x14
    /// JSON `StreamQuality` (a bare string). The host restarts the stream at that quality.
    case setQuality = 0x15
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
    /// Stream the Mac's sound. Absent means no.
    var audio: Bool?
    /// Absent means full.
    var quality: StreamQuality?
}

struct SelectDisplay: Codable {
    var displayID: UInt32
}

/// Stream presets for the link you're on. Full is for home Wi-Fi; the others
/// keep a hotel network or a phone hotspot usable. Audio is 1.5 Mbit/s on top
/// of these, uncompressed; turn it off on a tight link.
enum StreamQuality: String, Codable, CaseIterable {
    case full, balanced, saver

    var title: String {
        switch self {
        case .full: "Full"
        case .balanced: "Balanced"
        case .saver: "Data saver"
        }
    }

    /// Widest stream, in pixels (nil: the display's own).
    var maxWidth: Int? {
        switch self {
        case .full: nil
        case .balanced: 2560
        case .saver: 1920
        }
    }

    /// Ceiling on the encoder's average bitrate.
    var maxBitrate: Int {
        switch self {
        case .full: 40_000_000
        case .balanced: 8_000_000
        case .saver: 2_500_000
        }
    }

    var framesPerSecond: Int { self == .saver ? 30 : 60 }

    /// Stream size for a display of `pixels`, within the client's limits and
    /// the codec's. Keeps the aspect ratio; even dimensions, as encoders need.
    func streamSize(display pixels: (w: Double, h: Double), clientMax: (w: Int, h: Int), codecLimit: Double) -> (w: Int, h: Int) {
        var fit = min(1, Double(clientMax.w) / pixels.w, Double(clientMax.h) / pixels.h, codecLimit / pixels.w, codecLimit / pixels.h)
        if let mw = maxWidth { fit = min(fit, Double(mw) / pixels.w) }
        return (Int(pixels.w * fit) & ~1, Int(pixels.h * fit) & ~1)
    }

    /// Average bitrate for a stream of this size: bits per pixel scaled to the
    /// codec (HEVC needs about 60% of H.264's), floored so small streams stay
    /// sharp, and never over this preset's ceiling.
    func bitrate(width: Int, height: Int, codec: VideoCodec) -> Int {
        let perPixel = codec == .hevc ? 3 : 5
        return min(maxBitrate, max(min(6_000_000, maxBitrate), width * height * perPixel))
    }
}

enum MouseButton: Int, Codable {
    case left, right, middle
}

enum SwipeAxis: String, Codable {
    /// Between desktops and full-screen apps.
    case horizontal
    /// Mission Control (up) and App Exposé (down).
    case vertical
}

enum GesturePhase: String, Codable {
    case began, changed, ended, cancelled
}

/// Momentum after the fingers lift, generated on the iPad.
enum MomentumPhase: String, Codable {
    case began, changed, ended
}

enum InputEvent: Codable, Equatable {
    /// Relative pointer motion in Mac points (trackpad mode).
    case moveBy(dx: Double, dy: Double)
    /// Absolute pointer position, normalised 0...1 across the streamed display.
    case moveTo(x: Double, y: Double)
    case button(MouseButton, down: Bool)
    /// Scroll in pixels; positive dy moves content down (like a finger dragging it).
    /// `phase` and `momentum` are what a Mac trackpad attaches: apps use them
    /// for rubber-banding and to know when a scroll is over. Both absent is a
    /// plain mouse-wheel-style scroll.
    case scroll(dx: Double, dy: Double, phase: GesturePhase? = nil, momentum: MomentumPhase? = nil)
    /// A Mac virtual key code (kVK_*), pressed or released.
    case key(code: UInt16, down: Bool)
    /// Literal text, typed as unicode regardless of the Mac's keyboard layout.
    case text(String)
    /// A three-finger trackpad-style swipe. `distance` is the fingers' total
    /// travel since the gesture began, as a fraction of the iPad view's width
    /// (horizontal) or height (vertical), signed in screen directions:
    /// negative is left or up. A full-width swipe moves one desktop.
    case swipe(axis: SwipeAxis, phase: GesturePhase, distance: Double)
    /// Release every button and key the host believes is held, and end any swipe.
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

/// `[u8 flags][u64 BE capture time, ns on the host clock][4-byte length-prefixed NAL units]`.
/// Flags bit 0 = keyframe, bit 1 = refresh (a re-encode of an already sent
/// capture, to sharpen it). The capture time lets a client on the same machine
/// (the probe) measure glass-to-decode latency; the iPad ignores it.
enum FramePayload {
    static let headerSize = 9

    static func header(keyframe: Bool, refresh: Bool = false, captureNanos: UInt64) -> Data {
        var d = Data([(keyframe ? 1 : 0) | (refresh ? 2 : 0)])
        withUnsafeBytes(of: captureNanos.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    static func parse(_ data: Data) -> (keyframe: Bool, refresh: Bool, captureNanos: UInt64, body: Data)? {
        guard data.count > headerSize else { return nil }
        let b = data.startIndex
        var t: UInt64 = 0
        for i in 1...8 { t = t << 8 | UInt64(data[b + i]) }
        return (data[b] & 1 == 1, data[b] & 2 == 2, t, data.dropFirst(headerSize))
    }
}

/// `[u64 BE capture time, ns on the host clock][interleaved Int16 little-endian, 2 channels, 48 kHz]`.
///
/// Uncompressed: 1.5 Mbit/s, less than idle video, and no codec delay. The Mac
/// delivers 20ms (960-frame) chunks of planar Float32.
enum AudioPayload {
    static let sampleRate = 48_000.0
    static let channels = 2
    static let headerSize = 8

    static func encode(captureNanos: UInt64, left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) -> Data {
        let frames = min(left.count, right.count)
        var d = Data(capacity: headerSize + frames * 4)
        withUnsafeBytes(of: captureNanos.bigEndian) { d.append(contentsOf: $0) }
        var samples = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            samples[2 * i] = toInt16(left[i])
            samples[2 * i + 1] = toInt16(right[i])
        }
        samples.withUnsafeBytes { raw in
            for v in raw.bindMemory(to: Int16.self) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        }
        return d
    }

    /// Interleaved samples (L R L R ...), or nil if the payload is malformed.
    static func decode(_ data: Data) -> (captureNanos: UInt64, samples: [Int16])? {
        let body = data.count - headerSize
        guard body >= 0, body % (2 * channels) == 0 else { return nil }
        let b = data.startIndex
        var t: UInt64 = 0
        for i in 0..<8 { t = t << 8 | UInt64(data[b + i]) }
        var samples = [Int16](repeating: 0, count: body / 2)
        for i in 0..<samples.count {
            let lo = UInt16(data[b + headerSize + 2 * i]), hi = UInt16(data[b + headerSize + 2 * i + 1])
            samples[i] = Int16(bitPattern: hi << 8 | lo)
        }
        return (t, samples)
    }

    static func toInt16(_ x: Float) -> Int16 {
        guard x.isFinite else { return 0 }
        return Int16(max(-32767, min(32767, (x * 32767).rounded())))
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
