import Foundation
import Network

/// Length-prefixed messages over an NWConnection. All callbacks run on `queue`.
final class FramedConnection {
    let connection: NWConnection
    let queue: DispatchQueue

    var onMessage: ((MessageType, Data) -> Void)?
    var onReady: (() -> Void)?
    /// Called once, with the reason, when the connection is gone for good.
    var onClose: ((Error?) -> Void)?
    /// Called on `queue` when in-flight video drops back under the limit.
    var onDrain: (() -> Void)?

    private var closed = false
    private let lock = NSLock()
    private var videoInFlight = 0
    static let maxVideoInFlight = 2

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
            case .failed(let error):
                self.close(error)
            case .waiting(let error):
                // Refused / unreachable / TLS rejected: surface it instead of retrying forever.
                self.close(error)
            case .cancelled:
                self.close(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        readHeader()
    }

    func cancel() { connection.cancel() }

    /// True when the pipe can take another video frame without building latency.
    var canSendVideo: Bool {
        lock.lock(); defer { lock.unlock() }
        return videoInFlight < Self.maxVideoInFlight
    }

    func send(_ type: MessageType, _ payload: Data = Data()) {
        var frame = Data(capacity: Wire.headerSize + payload.count)
        frame.append(type.rawValue)
        let n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: n) { frame.append(contentsOf: $0) }
        frame.append(payload)

        let isVideo = type == .videoFrame
        if isVideo { lock.lock(); videoInFlight += 1; lock.unlock() }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if isVideo {
                self.lock.lock(); self.videoInFlight -= 1; let now = self.videoInFlight; self.lock.unlock()
                if now < Self.maxVideoInFlight { self.onDrain?() }
            }
            if let error { self.close(error) }
        })
    }

    func send<T: Encodable>(_ type: MessageType, json value: T) {
        send(type, try! JSONEncoder().encode(value))
    }

    private func close(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(error)
        onMessage = nil; onReady = nil; onClose = nil; onDrain = nil
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: Wire.headerSize, maximumLength: Wire.headerSize) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let error { return self.close(error) }
            guard let data, data.count == Wire.headerSize else {
                return self.close(isComplete ? nil : ProtocolError.truncated)
            }
            let b = [UInt8](data)
            guard let type = MessageType(rawValue: b[0]) else { return self.close(ProtocolError.unknownType(b[0])) }
            let len = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
            guard len <= Wire.maxPayload else { return self.close(ProtocolError.tooLarge(len)) }
            if len == 0 {
                self.onMessage?(type, Data())
                self.readHeader()
            } else {
                self.readBody(type, len)
            }
        }
    }

    private func readBody(_ type: MessageType, _ len: Int) {
        connection.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            if let error { return self.close(error) }
            guard let data, data.count == len else { return self.close(ProtocolError.truncated) }
            self.onMessage?(type, data)
            self.readHeader()
        }
    }
}

enum ProtocolError: LocalizedError {
    case truncated
    case unknownType(UInt8)
    case tooLarge(Int)
    case badPayload(MessageType)

    var errorDescription: String? {
        switch self {
        case .truncated: "Connection closed mid-message"
        case .unknownType(let t): "Unknown message type 0x\(String(t, radix: 16))"
        case .tooLarge(let n): "Message of \(n) bytes exceeds limit"
        case .badPayload(let t): "Malformed \(t) payload"
        }
    }
}
