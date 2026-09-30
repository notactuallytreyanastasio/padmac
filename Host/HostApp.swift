import ApplicationServices
import ServiceManagement
import SwiftUI

@main
struct RemoteMacHostApp: App {
    @StateObject private var model = HostModel()

    var body: some Scene {
        MenuBarExtra {
            HostMenu(model: model)
        } label: {
            Image(systemName: model.connected ? "display.and.arrow.down" : "display")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class HostModel: ObservableObject {
    @Published var status = "Starting…"
    @Published var code: String
    @Published var screenRecording = CGPreflightScreenCaptureAccess()
    @Published var accessibility = AXIsProcessTrusted()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    var connected: Bool { status.hasPrefix("Connected") }

    private let server = HostServer()
    private var poll: Timer?

    init() {
        let key = "pairingCode"
        if let saved = UserDefaults.standard.string(forKey: key) {
            code = saved
        } else {
            code = PairingSecurity.newCode()
            UserDefaults.standard.set(code, forKey: key)
        }
        server.onStatus = { [weak self] s in Task { @MainActor in self?.status = s } }
        restart()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.screenRecording = CGPreflightScreenCaptureAccess()
                self?.accessibility = AXIsProcessTrusted()
            }
        }
    }

    func restart() {
        do {
            try server.start(code: code, name: Host.current().localizedName ?? "Mac")
        } catch {
            status = "Could not listen: \(error.localizedDescription)"
        }
    }

    func regenerateCode() {
        code = PairingSecurity.newCode()
        UserDefaults.standard.set(code, forKey: "pairingCode")
        restart()
    }

    func disconnect() { server.disconnect() }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            status = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestScreenRecording() { CGRequestScreenCaptureAccess() }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }
}

struct HostMenu: View {
    @ObservedObject var model: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remote Mac").font(.headline)
            HStack(alignment: .top) {
                Text(model.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.connected {
                    Spacer()
                    Button("Disconnect") { model.disconnect() }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Pairing code").font(.caption).foregroundStyle(.secondary)
                Text(PairingSecurity.display(model.code))
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            }

            Divider()
            permission("Screen Recording", granted: model.screenRecording, action: model.requestScreenRecording)
            permission("Accessibility (input)", granted: model.accessibility, action: model.requestAccessibility)
            if !model.screenRecording {
                Text("After granting Screen Recording, quit and reopen this app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))

            HStack {
                Button("New Code") { model.regenerateCode() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func permission(_ name: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(name)
            Spacer()
            if !granted { Button("Grant", action: action) }
        }
    }
}
