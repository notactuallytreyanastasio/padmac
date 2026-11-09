import Foundation

/// Small QUIC datagrams, with one XOR recovery packet for each eight fragments.
/// Incomplete pictures expire instead of blocking later pictures or control input.
enum MediaDatagrams {
    static let chunkSize = 1000
    static let headerSize = 20
    static let maxMessageBytes = 2 << 20
    enum Kind: UInt8 { case video = 1, audio, cursor, auth = 240, accepted, ping, pong, videoAck }
    struct Message: Equatable {
        var kind: Kind
        var epoch: UInt32
        var id: UInt32
        var keyframe: Bool
        var data: Data
    }
    struct Fragment {
        let kind: Kind
        let keyframe: Bool
        let epoch: UInt32
        let id: UInt32
        let index: Int
        let count: Int
        let size: Int
        let parity: Bool
        let data: Data
    }

    static func packets(_ message: Message) -> [Data] {
        guard !message.data.isEmpty, message.data.count <= maxMessageBytes else { return [] }
        let bytes = [UInt8](message.data)
        let count = (bytes.count + chunkSize - 1) / chunkSize
        func packet(index: Int, data: Data) -> Data {
            var result = Data([0x50, 0x4D, message.kind.rawValue, message.keyframe ? 1 : 0])
            append(message.epoch, to: &result); append(message.id, to: &result)
            append(UInt16(index), to: &result); append(UInt16(count), to: &result)
            append(UInt32(bytes.count), to: &result)
            result.append(data)
            return result
        }
        var result: [Data] = []
        for group in stride(from: 0, to: count, by: 8) {
            var parity = [UInt8](repeating: 0, count: chunkSize)
            let end = min(group + 8, count)
            for index in group..<end {
                let fragment = Array(bytes[(index * chunkSize)..<min(bytes.count, (index + 1) * chunkSize)])
                result.append(packet(index: index, data: Data(fragment)))
                for (offset, byte) in fragment.enumerated() { parity[offset] ^= byte }
            }
            if end - group > 1 { result.append(packet(index: 0x8000 | (group / 8), data: Data(parity))) }
        }
        return result
    }

    static func parse(_ packet: Data) -> Fragment? {
        let b = [UInt8](packet)
        guard b.count > headerSize, b[0] == 0x50, b[1] == 0x4D, b[3] <= 1, let kind = Kind(rawValue: b[2]) else { return nil }
        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func u32(_ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i+1]) << 16 | UInt32(b[i+2]) << 8 | UInt32(b[i+3]) }
        let index = u16(12), count = u16(14), size = Int(u32(16)), parity = index & 0x8000 != 0
        let plainIndex = index & 0x7FFF
        guard size > 0, size <= maxMessageBytes, count == (size + chunkSize - 1) / chunkSize,
              parity ? plainIndex < (count + 7) / 8 : plainIndex < count else { return nil }
        let expected = parity ? chunkSize : min(chunkSize, size - plainIndex * chunkSize)
        guard b.count == headerSize + expected else { return nil }
        return Fragment(kind: kind, keyframe: b[3] == 1, epoch: u32(4), id: u32(8), index: plainIndex,
                        count: count, size: size, parity: parity, data: Data(b.dropFirst(headerSize)))
    }

    static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

struct MediaReassembler {
    private struct Key: Hashable { let kind: UInt8; let epoch: UInt32; let id: UInt32 }
    private struct Assembly {
        let first: TimeInterval
        let fragment: MediaDatagrams.Fragment
        var pieces: [Int: Data] = [:]
        var parity: [Int: Data] = [:]
    }
    private var pending: [Key: Assembly] = [:]
    private var delivered: [Key: TimeInterval] = [:]

    mutating func receive(_ packet: Data, at now: TimeInterval) -> MediaDatagrams.Message? {
        pending = pending.filter { _, value in now - value.first <= (value.fragment.keyframe ? 0.8 : 0.2) }
        delivered = delivered.filter { now - $0.value < 2 }
        guard let f = MediaDatagrams.parse(packet) else { return nil }
        let key = Key(kind: f.kind.rawValue, epoch: f.epoch, id: f.id)
        guard delivered[key] == nil else { return nil }
        if pending[key] == nil {
            if pending.count >= 12, let oldest = pending.min(by: { $0.value.first < $1.value.first })?.key { pending.removeValue(forKey: oldest) }
            pending[key] = Assembly(first: now, fragment: f)
        }
        guard var a = pending[key], a.fragment.count == f.count, a.fragment.size == f.size,
              a.fragment.keyframe == f.keyframe else { return nil }
        if f.parity { a.parity[f.index] = f.data } else { a.pieces[f.index] = f.data }
        for (group, parity) in a.parity {
            let indices = (group * 8)..<min(group * 8 + 8, f.count)
            let missing = indices.filter { a.pieces[$0] == nil }
            guard missing.count == 1, let index = missing.first else { continue }
            var recovered = [UInt8](parity)
            for other in indices where other != index {
                guard let piece = a.pieces[other] else { continue }
                for (offset, byte) in piece.enumerated() { recovered[offset] ^= byte }
            }
            a.pieces[index] = Data(recovered.prefix(min(MediaDatagrams.chunkSize, f.size - index * MediaDatagrams.chunkSize)))
        }
        guard a.pieces.count == f.count else { pending[key] = a; return nil }
        pending.removeValue(forKey: key)
        if delivered.count >= 1024, let oldest = delivered.min(by: { $0.value < $1.value })?.key { delivered.removeValue(forKey: oldest) }
        delivered[key] = now
        var data = Data(capacity: f.size)
        for index in 0..<f.count { data.append(a.pieces[index]!) }
        return MediaDatagrams.Message(kind: f.kind, epoch: f.epoch, id: f.id, keyframe: f.keyframe, data: data)
    }
}

/// A keyframe carries its own decoder configuration, so a reliable control
/// packet can never hold up an independently delivered media frame.
enum MediaVideo {
    static func encode(format: Data?, frame: Data) -> Data {
        let format = format ?? Data()
        var result = Data()
        MediaDatagrams.append(UInt16(format.count), to: &result)
        result.append(format); result.append(frame)
        return result
    }
    static func decode(_ data: Data) -> (format: Data?, frame: Data)? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }
        let n = Int(b[0]) << 8 | Int(b[1])
        guard b.count > n + 2 else { return nil }
        return (n == 0 ? nil : Data(b[2..<(n + 2)]), Data(b.dropFirst(n + 2)))
    }
}

/// Never feed an old picture, or a dependent picture after loss, to the decoder.
struct MediaVideoOrder {
    private var epoch: UInt32?
    private var last: UInt32?
    private var needsKeyframe = true
    mutating func accept(_ message: MediaDatagrams.Message) -> (decode: Bool, requestKeyframe: Bool) {
        if let epoch, message.epoch < epoch { return (false, false) }
        if epoch != message.epoch { epoch = message.epoch; last = nil; needsKeyframe = true }
        if let last, message.id <= last { return (false, false) }
        if message.keyframe { needsKeyframe = false }
        else if last == nil || message.id != last! &+ 1 { needsKeyframe = true }
        last = message.id
        return (!needsKeyframe, needsKeyframe)
    }
}
