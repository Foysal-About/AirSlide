import Foundation
import Security
import CryptoKit

/// What the Mac's QR code / pairing link carries: which Mac, and the shared secret.
struct PairingPayload {
    let macID: String
    let macName: String
    let secret: Data

    var url: URL {
        var c = URLComponents()
        c.scheme = "airslide"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "id", value: macID),
            URLQueryItem(name: "name", value: macName),
            URLQueryItem(name: "key", value: secret.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")),
        ]
        return c.url!
    }

    init(macID: String, macName: String, secret: Data) {
        self.macID = macID; self.macName = macName; self.secret = secret
    }

    init?(string: String) {
        guard let u = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              u.scheme == "airslide", u.host == "pair",
              let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems,
              let id = items.first(where: { $0.name == "id" })?.value,
              let name = items.first(where: { $0.name == "name" })?.value,
              let key = items.first(where: { $0.name == "key" })?.value
        else { return nil }
        var b64 = key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let secret = Data(base64Encoded: b64), secret.count == 32 else { return nil }
        self.init(macID: id, macName: name, secret: secret)
    }

    static func randomSecret() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { throw AirSlideError.randomFailed }
        return Data(bytes)
    }
}

enum Pairing {
    /// Both sides call this with the same public keys and get the same secret and code.
    /// A man in the middle would end up with different secrets, so the two screens would show different codes.
    static func derive(priv: Curve25519.KeyAgreement.PrivateKey, peerPub: Data, phonePub: Data, macPub: Data) throws -> (secret: Data, code: String) {
        let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPub)
        let shared = try priv.sharedSecretFromKeyAgreement(with: theirs)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("airslide-pair".utf8),
                                                 sharedInfo: phonePub + macPub, outputByteCount: 32)
        let secret = key.withUnsafeBytes { Data($0) }
        let h = SHA256.hash(data: secret + Data("sas".utf8))
        let n = h.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 10000
        return (secret, String(format: "%04d", n))
    }
}
