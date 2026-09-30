import Foundation
import Network

/// Listens on a fixed port (so manual IP entry works over VPNs) and advertises over Bonjour.
/// One iPad at a time: a new connection replaces the old one.
final class HostServer {
    private var listener: NWListener?
    private var session: HostSession?
    private let queue = DispatchQueue(label: "remotemac.listener")

    var onStatus: ((String) -> Void)?

    func start(code: String, name: String) throws {
        stop()
        let listener = try NWListener(using: PairingSecurity.parameters(code: code), on: NWEndpoint.Port(rawValue: Wire.port)!)
        listener.service = NWListener.Service(name: name, type: Wire.serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onStatus?("Waiting for iPad on port \(Wire.port)")
            case .failed(let e): self?.onStatus?("Listener failed: \(e.localizedDescription)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        session?.stop()
        session = nil
    }

    private func accept(_ connection: NWConnection) {
        session?.stop()
        let s = HostSession(connection: connection)
        s.onStatus = { [weak self] in self?.onStatus?($0) }
        s.onEnd = { [weak self] ended, error in
            self?.queue.async {
                guard let self, self.session === ended else { return }
                self.session = nil
                let why = error.map { ": \($0.localizedDescription)" } ?? ""
                self.onStatus?("Disconnected\(why). Waiting for iPad on port \(Wire.port)")
            }
        }
        session = s
        s.start()
    }
}
