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
    private var retries = 0
    /// Between start() and stop(): a pending retry after stop() does nothing.
    private var wanted = false

    func start() {
        wanted = true
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
            Task { @MainActor in self?.update(state, of: b) }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        wanted = false
        teardown()
    }

    private func teardown() {
        browser?.cancel()
        browser = nil
    }

    /// A failed browser stays failed, so it is replaced. Seen on iPhone Duo at
    /// first launch: -65569 DefunctConnection, the connection to the Bonjour
    /// daemon dropped around the Local Network permission prompt.
    private func update(_ state: NWBrowser.State, of b: NWBrowser) {
        guard b === browser else { return }
        switch state {
        case .ready:
            retries = 0
            problem = nil
        case .failed(let e):
            retries += 1
            problem = "Browsing failed: \(e.localizedDescription). Retrying… If this stays, check Settings › Privacy & Security › Local Network."
            teardown()
            let delay = min(8, 0.5 * pow(2, Double(retries - 1)))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.wanted else { return }
                self.start()
            }
        case .waiting(let e):
            problem = "Browsing is waiting: \(e.localizedDescription). Check Settings › Privacy & Security › Local Network."
        default:
            break
        }
    }
}
