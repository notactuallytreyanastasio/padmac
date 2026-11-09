import Foundation
import Network

final class QUICMediaHost {
    var onChange: ((Bool) -> Void)?
    var onDrain: (() -> Void)?
    var onVideoLoss: (() -> Void)?
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var pending: [QUICMediaChannel] = []
    private let lock = NSLock()
    private var channel: QUICMediaChannel?
    private var format: Data?
    private var epoch: UInt32 = 0
    private var stopped = false
    init(queue: DispatchQueue) { self.queue = queue }
    private var current: QUICMediaChannel? { lock.lock(); defer { lock.unlock() }; return channel }
    var isReady: Bool { current?.isReady == true }
    var canSendVideo: Bool { current?.canSendVideo == true }

    func start(offer: @escaping (MediaOffer) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let identity = QUICIdentity.shared
            self?.queue.async { [weak self] in
                guard let self, !self.stopped, let identity else { return }
                do {
                    let listener = try NWListener(using: MediaSecurity.server(identity: identity.identity), on: .any)
                    let token = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
                    listener.stateUpdateHandler = { [weak listener] state in
                        if case .ready = state, let port = listener?.port {
                            offer(MediaOffer(port: port.rawValue, certificateSHA256: identity.fingerprint, token: token))
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self, self.pending.count < 4 else { connection.cancel(); return }
                        let media = QUICMediaChannel(connection: connection, token: token, client: false, queue: self.queue)
                        media.onReady = { [weak self, weak media] in
                            guard let self, let media else { return }
                            self.pending.removeAll { $0 === media }
                            self.lock.lock(); let old = self.channel; self.channel = media; self.lock.unlock()
                            old?.stop()
                            NSLog("RemoteMac: QUIC media authenticated")
                            self.onChange?(true)
                        }
                        media.onClose = { [weak self, weak media] in
                            guard let self, let media else { return }
                            self.pending.removeAll { $0 === media }
                            self.lock.lock()
                            let wasCurrent = self.channel === media
                            if wasCurrent { self.channel = nil }
                            self.lock.unlock()
                            if wasCurrent { self.onChange?(false) }
                        }
                        media.onDrain = { [weak self] in self?.onDrain?() }
                        media.onVideoLoss = { [weak self] in self?.onVideoLoss?() }
                        self.pending.append(media)
                        media.start()
                    }
                    self.listener = listener
                    listener.start(queue: self.queue)
                } catch { NSLog("RemoteMac: QUIC listener unavailable: %@", error.localizedDescription) }
            }
        }
    }
    func stop() {
        stopped = true
        listener?.cancel(); listener = nil
        let waiting = pending; pending = []
        lock.lock(); let old = channel; channel = nil; lock.unlock()
        waiting.forEach { $0.stop() }; old?.stop()
    }
    func beginEpoch(_ epoch: UInt32) { lock.lock(); self.epoch = epoch; format = nil; lock.unlock() }
    func accepts(_ epoch: UInt32) -> Bool { lock.lock(); defer { lock.unlock() }; return self.epoch == epoch }
    @discardableResult func setFormat(_ data: Data, epoch: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.epoch == epoch else { return false }
        format = data; return true
    }
    func video(_ frame: Data, epoch: UInt32) -> Bool {
        guard accepts(epoch) else { return true }
        guard let channel = current, channel.isReady else { return false }
        guard let parsed = FramePayload.parse(frame) else { return true }
        lock.lock(); let configuration = parsed.keyframe ? format : nil; lock.unlock()
        let data = MediaVideo.encode(format: configuration, frame: frame)
        guard data.count <= MediaDatagrams.maxMessageBytes else { channel.stop(); return false }
        channel.send(.video, data: data, epoch: epoch, keyframe: parsed.keyframe)
        return true
    }
    func send(_ kind: MediaDatagrams.Kind, data: Data) -> Bool {
        guard let channel = current, channel.isReady else { return false }
        channel.send(kind, data: data)
        return true
    }
}
