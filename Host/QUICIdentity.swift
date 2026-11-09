import CryptoKit
import Foundation
import Security

/// Per-launch identity. The paired TLS control channel authenticates its fingerprint.
enum QUICIdentity {
    struct Value {
        let identity: SecIdentity
        let fingerprint: Data
    }
    static let shared: Value? = {
        guard #available(macOS 15, *) else { return nil }
        do { return try make() }
        catch { NSLog("RemoteMac: QUIC identity unavailable: %@", error.localizedDescription); return nil }
    }()

    @available(macOS 15, *)
    static func make() throws -> Value {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("padmac-quic-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let password = UUID().uuidString
        let passwordFile = directory.appendingPathComponent("password")
        try Data(password.utf8).write(to: passwordFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordFile.path)
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.currentDirectoryURL = directory
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
        }
        try run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "key.pem"])
        try run(["req", "-new", "-x509", "-key", "key.pem", "-out", "cert.pem", "-days", "2", "-subj", "/CN=PadMac Local Media"])
        try run(["pkcs12", "-export", "-inkey", "key.pem", "-in", "cert.pem", "-out", "identity.p12", "-passout", "file:password"])
        let p12 = try Data(contentsOf: directory.appendingPathComponent("identity.p12"))
        var items: CFArray?
        let result = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase: password, kSecImportToMemoryOnly: true] as CFDictionary, &items)
        guard result == errSecSuccess, let item = (items as? [[String: Any]])?.first,
              let value = item[kSecImportItemIdentity as String] else { throw CocoaError(.fileReadCorruptFile) }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw CocoaError(.fileReadCorruptFile) }
        return Value(identity: identity, fingerprint: Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data)))
    }
}
