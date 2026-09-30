import Network
import SwiftUI

@main
struct RemoteMacApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @State private var session: RemoteSession?

    var body: some View {
        if let session {
            RemoteScreen(session: session) { self.session = nil }
        } else {
            HostPicker { session = $0 }
        }
    }
}

struct RemoteScreen: View {
    @ObservedObject var session: RemoteSession
    let close: () -> Void

    var body: some View {
        ZStack {
            RemoteControllerView(session: session, close: close)
            switch session.state {
            case .connecting:
                ProgressView("Connecting to \(session.hostName)…").tint(.white).foregroundStyle(.white)
            case .streaming:
                EmptyView()
            case .reconnecting(let why):
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Reconnecting to \(session.hostName)…").foregroundStyle(.white)
                    Text(why).font(.caption).foregroundStyle(.white.opacity(0.7))
                    Button("Back") { session.stop(); close() }.buttonStyle(.bordered).tint(.white)
                }
                .padding(24)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
            case .failed(let message, let badCode):
                VStack(spacing: 16) {
                    Text(message).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("Back") {
                        if badCode { Keychain.set(nil, for: session.hostName) }
                        close()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(32)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onAppear { session.start() }
    }
}

struct RemoteControllerView: UIViewControllerRepresentable {
    let session: RemoteSession
    let close: () -> Void

    func makeUIViewController(context: Context) -> RemoteViewController {
        let vc = RemoteViewController(session: session)
        vc.onClose = close
        return vc
    }

    func updateUIViewController(_ vc: RemoteViewController, context: Context) {}
}

struct HostPicker: View {
    let connect: (RemoteSession) -> Void

    @StateObject private var browser = HostBrowser()
    @State private var address = UserDefaults.standard.string(forKey: "lastAddress") ?? ""
    @State private var pending: (name: String, endpoint: NWEndpoint)?
    @State private var code = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if browser.hosts.isEmpty {
                        Label("Looking for Macs running Remote Mac Host…", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(browser.hosts) { host in
                        Button {
                            open(host.name, host.endpoint)
                        } label: {
                            Label(host.name, systemImage: "desktopcomputer")
                        }
                    }
                } header: {
                    Text("On this network")
                } footer: {
                    if let problem = browser.problem { Text(problem).foregroundStyle(.red) }
                }

                Section {
                    HStack {
                        TextField("192.168.1.20 or my-mac.local", text: $address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit(openAddress)
                        Button("Connect", action: openAddress).disabled(address.isEmpty)
                    }
                } header: {
                    Text("By address")
                } footer: {
                    Text("Port \(String(Wire.port)). Use this over Tailscale or when Bonjour can't see the Mac.")
                }
            }
            .navigationTitle("Remote Mac")
        }
        .onAppear {
            browser.start()
            // Test hook: launch with `-autoconnect <host>[:port] -code <code>` to skip the UI.
            let d = UserDefaults.standard
            if let target = d.string(forKey: "autoconnect"), let c = d.string(forKey: "code") {
                let parts = target.split(separator: ":")
                let port = parts.count > 1 ? UInt16(parts[1]) ?? Wire.port : Wire.port
                start(String(parts[0]), .hostPort(host: NWEndpoint.Host(String(parts[0])), port: NWEndpoint.Port(rawValue: port)!), c)
            }
        }
        .onDisappear { browser.stop() }
        .alert("Pairing code", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            TextField("ABCD-EFGH", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Connect") {
                if let p = pending, PairingSecurity.normalize(code).count == 8 {
                    Keychain.set(PairingSecurity.normalize(code), for: p.name)
                    start(p.name, p.endpoint, PairingSecurity.normalize(code))
                }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("Enter the code shown in the Remote Mac Host menu on \(pending?.name ?? "the Mac").")
        }
    }

    private func openAddress() {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        UserDefaults.standard.set(a, forKey: "lastAddress")
        open(a, .hostPort(host: NWEndpoint.Host(a), port: NWEndpoint.Port(rawValue: Wire.port)!))
    }

    private func open(_ name: String, _ endpoint: NWEndpoint) {
        if let saved = Keychain.code(for: name) {
            start(name, endpoint, saved)
        } else {
            code = ""
            pending = (name, endpoint)
        }
    }

    private func start(_ name: String, _ endpoint: NWEndpoint, _ code: String) {
        connect(RemoteSession(hostName: name, endpoint: endpoint, code: code))
    }
}
