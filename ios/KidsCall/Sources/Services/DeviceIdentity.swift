import CryptoKit
import Foundation

/// The device's Ed25519 identity. The private key is generated on first launch,
/// stored only in this device's Keychain, and is the sole credential the server
/// accepts. There are no passwords and no accounts.
final class DeviceIdentity {
    static let shared = DeviceIdentity()

    private static let keychainKey = "device.ed25519.private"
    private let privateKey: Curve25519.Signing.PrivateKey

    private init() {
        if let raw = Keychain.read(Self.keychainKey),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            privateKey = key
        } else {
            let key = Curve25519.Signing.PrivateKey()
            Keychain.write(Self.keychainKey, key.rawRepresentation)
            privateKey = key
        }
    }

    var publicKeyBase64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Same derivation as the server: first 32 hex chars of SHA-256(publicKey).
    var deviceId: String {
        let digest = SHA256.hash(data: privateKey.publicKey.rawRepresentation)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    func sign(_ message: String) -> String {
        // Ed25519 signing only fails on internal errors; treat that as fatal.
        let signature = try! privateKey.signature(for: Data(message.utf8))
        return signature.base64EncodedString()
    }

    func registerSignature(nonce: String) -> String {
        sign("kidscall-register|\(nonce)|\(publicKeyBase64)")
    }

    func authSignature(nonce: String) -> String {
        sign("kidscall-auth|\(nonce)|\(publicKeyBase64)")
    }
}
