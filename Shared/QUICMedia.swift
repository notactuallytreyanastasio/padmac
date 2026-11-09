import CryptoKit
import Foundation
import Network
import Security

struct MediaOffer: Codable {
    var port: UInt16
    var certificateSHA256: Data
    var token: Data
}

enum MediaSecurity {
    static func options() -> NWProtocolQUIC.Options {
        let options = NWProtocolQUIC.Options(alpn: ["padmac-media-v1"])
        options.isDatagram = true
        options.maxDatagramFrameSize = 1200
        options.maxUDPPayloadSize = 1200
        options.idleTimeout = 15_000
        return options
    }
    static func client(fingerprint: Data, queue: DispatchQueue) -> NWParameters {
        let options = options()
        // This is a pin obtained inside the authenticated TLS-PSK control channel.
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificate = SecTrustGetCertificateAtIndex(trust, 0) else { return complete(false) }
            let hash = Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
            complete(hash == fingerprint && fingerprint.count == 32)
        }, queue)
        return NWParameters(quic: options)
    }
    static func server(identity: SecIdentity) -> NWParameters {
        let options = options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, sec_identity_create(identity)!)
        return NWParameters(quic: options)
    }
}

/// One authenticated QUIC datagram flow. A maximum of two unacknowledged
/// pictures bounds latency all the way to the receiver, not just the socket.
final class QUICMediaChannel {
    var onReady: (() -> Void)?
    var onMessage: ((MediaDatagrams.Message) -> Void)?
    var onDrain: (() -> Void)?
    var onVideoLoss: (() -> Void)?
    var onClose: (() -> Void)?
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let token: Data
    private let client: Bool
    private let lock = NSLock()
    private var ready = false
    private var slots = 0
    private var closed = false
    private var timer: DispatchSourceTimer?
    private let began = ProcessInfo.processInfo.systemUptime
    private var lastAuth: TimeInterval = 0
    private var lastPing: TimeInterval = 0
    private var reassembler = MediaReassembler()
    private var sequence: [UInt8: UInt32] = [:]
    private struct Waiting {
        let message: MediaDatagrams.Message
        let began: TimeInterval
    }
    private struct Flight: Hashable { let epoch: UInt32; let id: UInt32 }
    private var flights: [Flight: (TimeInterval, Bool)] = [:]
    private var videos: [Waiting] = []
    private var latest: [UInt8: Waiting] = [:]
    private var active: (Waiting, [Data], Int)?
    private var sending = 0

    init(connection: NWConnection, token: Data, client: Bool, queue: DispatchQueue) {
        self.connection = connection; self.token = token; self.client = client; self.queue = queue
    }
    deinit { timer?.cancel() }
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    var canSendVideo: Bool { lock.lock(); defer { lock.unlock() }; return ready && slots < 2 }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if self.client { self.sendImmediate(.auth, data: self.token) }
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume(); self.timer = timer
    }
    func stop() { queue.async { [weak self] in self?.finish() } }
    private func finish() {
        guard !closed else { return }
        closed = true
        lock.lock(); ready = false; slots = 0; lock.unlock()
        timer?.cancel(); timer = nil
        connection.cancel()
        onClose?()
        onClose = nil; onReady = nil; onMessage = nil; onDrain = nil; onVideoLoss = nil
    }

    func send(_ kind: MediaDatagrams.Kind, data: Data, epoch: UInt32 = 0, keyframe: Bool = false) {
        if kind == .video {
            lock.lock()
            guard ready, slots < 2 else { lock.unlock(); return }
            slots += 1; lock.unlock()
        }
        queue.async { [weak self] in
            guard let self, !self.closed, self.isReady else { return }
            let message = self.message(kind, data: data, epoch: epoch, keyframe: keyframe)
            let now = ProcessInfo.processInfo.systemUptime
            let waiting = Waiting(message: message, began: now)
            if kind == .video {
                self.flights[Flight(epoch: epoch, id: message.id)] = (now, keyframe)
                self.videos.append(waiting)
            } else { self.latest[kind.rawValue] = waiting }
            self.pump()
        }
    }
    private func message(_ kind: MediaDatagrams.Kind, data: Data, epoch: UInt32 = 0, keyframe: Bool = false) -> MediaDatagrams.Message {
        sequence[kind.rawValue, default: 0] &+= 1
        return .init(kind: kind, epoch: epoch, id: sequence[kind.rawValue]!, keyframe: keyframe, data: data)
    }
    private func sendImmediate(_ kind: MediaDatagrams.Kind, data: Data) {
        let message = message(kind, data: data)
        for packet in MediaDatagrams.packets(message) {
            connection.send(content: packet, contentContext: .init(identifier: "control", expiration: 250, priority: 1),
                            isComplete: true, completion: .contentProcessed { _ in })
        }
    }
    private func pump() {
        guard !closed, isReady else { return }
        while sending < 4 {
            if active == nil {
                let next: Waiting?
                if let cursor = latest.removeValue(forKey: MediaDatagrams.Kind.cursor.rawValue) { next = cursor }
                else if !videos.isEmpty { next = videos.removeFirst() }
                else if let key = latest.keys.first { next = latest.removeValue(forKey: key) }
                else { break }
                if let next { active = (next, MediaDatagrams.packets(next.message), 0) }
            }
            guard var current = active else { break }
            let expiry = current.0.message.keyframe ? 0.8 : 0.2
            if current.2 >= current.1.count || ProcessInfo.processInfo.systemUptime - current.0.began > expiry {
                active = nil; continue
            }
            let packet = current.1[current.2]
            current.2 += 1; active = current
            sending += 1
            connection.send(content: packet,
                            contentContext: .init(identifier: "media", expiration: UInt64(expiry * 1000)),
                            isComplete: true, completion: .contentProcessed { [weak self] _ in
                guard let self, !self.closed else { return }
                self.sending -= 1; self.pump()
            })
        }
    }
    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            if error != nil { return self.finish() }
            if let data {
                if !self.isReady {
                    guard let fragment = MediaDatagrams.parse(data), fragment.count == 1, fragment.size == 32,
                          fragment.kind == (self.client ? .accepted : .auth) else { self.receive(); return }
                }
                if let message = self.reassembler.receive(data, at: ProcessInfo.processInfo.systemUptime) { self.handle(message) }
            }
            self.receive()
        }
    }
    private func handle(_ message: MediaDatagrams.Message) {
        if !client, message.kind == .auth, message.data == token, token.count == 32 {
            sendImmediate(.accepted, data: token)
            becomeReady(); return
        }
        if client, message.kind == .accepted, message.data == token, token.count == 32 { becomeReady(); return }
        guard isReady else { return }
        switch message.kind {
        case .ping: sendImmediate(.pong, data: message.data)
        case .pong: break
        case .videoAck:
            let b = [UInt8](message.data)
            guard b.count == 8 else { return }
            func u32(_ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i+1]) << 16 | UInt32(b[i+2]) << 8 | UInt32(b[i+3]) }
            if flights.removeValue(forKey: Flight(epoch: u32(0), id: u32(4))) != nil {
                lock.lock(); slots -= 1; lock.unlock(); onDrain?()
            }
        case .video:
            var ack = Data(); MediaDatagrams.append(message.epoch, to: &ack); MediaDatagrams.append(message.id, to: &ack)
            sendImmediate(.videoAck, data: ack)
            sendImmediate(.videoAck, data: ack)
            onMessage?(message)
        case .audio, .cursor: onMessage?(message)
        case .auth, .accepted: break
        }
    }
    private func becomeReady() {
        guard !isReady else { return }
        lock.lock(); ready = true; lock.unlock()
        onReady?(); pump()
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if !isReady {
            if now - began > 6 { finish(); return }
            if client, now - lastAuth > 0.25, case .ready = connection.state {
                lastAuth = now; sendImmediate(.auth, data: token)
            }
            return
        }
        if now - lastPing > 2 { lastPing = now; sendImmediate(.ping, data: Data([1])) }
        let expired = flights.filter { now - $0.value.0 > ($0.value.1 ? 1 : 0.4) }
        if !expired.isEmpty {
            for key in expired.keys { flights.removeValue(forKey: key) }
            lock.lock(); slots -= expired.count; lock.unlock()
            onVideoLoss?(); onDrain?()
        }
        pump()
    }
}
