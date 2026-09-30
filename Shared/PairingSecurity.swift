import CryptoKit
import Foundation
import Network

/// TLS with a pre-shared key derived from the pairing code shown on the Mac.
///
/// There are no certificates: a client that does not know the code cannot
/// complete the handshake, and the traffic is encrypted with AES-GCM.
/// The code is 8 characters from a 32-letter alphabet, so 40 bits. That is
/// fine against someone on your Wi-Fi guessing online, but a recorded
/// handshake can be brute-forced offline. Do not expose the port to the internet.
enum PairingSecurity {
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    static let identity = "remotemac-v1"

    static func newCode() -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<8).map { _ in alphabet.randomElement(using: &rng)! })
    }

    /// Accepts "abcd-efgh", "ABCD EFGH" etc.
    static func normalize(_ code: String) -> String {
        code.uppercased().filter { alphabet.contains($0) }
    }

    static func display(_ code: String) -> String {
        let c = normalize(code)
        guard c.count == 8 else { return c }
        return "\(c.prefix(4))-\(c.suffix(4))"
    }

    static func parameters(code: String) -> NWParameters {
        let salt = SymmetricKey(data: Data("remotemac-psk-v1".utf8))
        let key = Data(HMAC<SHA256>.authenticationCode(for: Data(normalize(code).utf8), using: salt))

        let tls = NWProtocolTLS.Options()
        let opts = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(opts, key.dispatchData as __DispatchData,
                                                Data(identity.utf8).dispatchData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(opts, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        // PSK cipher suites exist only up to TLS 1.2 in Network.framework.
        sec_protocol_options_set_max_tls_protocol_version(opts, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.connectionTimeout = 8

        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }
}

private extension Data {
    var dispatchData: DispatchData { withUnsafeBytes { DispatchData(bytes: $0) } }
}
