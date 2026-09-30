import Foundation
import Network

struct DiscoveredHost: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let endpoint: NWEndpoint
}

/// Bonjour discovery of Macs running the host.
@MainActor
final class HostBrowser: ObservableObject {
    @Published var hosts: [DiscoveredHost] = []
    @Published var problem: String?
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: Wire.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { r -> DiscoveredHost? in
                guard case .service(let name, _, _, _) = r.endpoint else { return nil }
                return DiscoveredHost(name: name, endpoint: r.endpoint)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in self?.hosts = hosts }
        }
        b.stateUpdateHandler = { [weak self] state in
            let msg: String? = switch state {
            case .failed(let e), .waiting(let e): "Browsing failed: \(e.localizedDescription). Check Local Network permission in Settings."
            default: nil
            }
            Task { @MainActor in self?.problem = msg }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
