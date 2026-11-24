import Foundation
import Security

enum KeychainError: LocalizedError {
    case status(OSStatus)
    var errorDescription: String? {
        if case .status(let s) = self { return "Keychain error \(s)" }
        return nil
    }
}

enum KeychainStore {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.airslide",
         kSecAttrAccount as String: account]
    }

    static func set(_ data: Data, account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = data
        let s = SecItemAdd(q as CFDictionary, nil)
        guard s == errSecSuccess else { throw KeychainError.status(s) }
    }

    static func get(account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func delete(account: String) { SecItemDelete(query(account) as CFDictionary) }
}

/// Paired peers: list in UserDefaults, shared secrets in the Keychain.
struct PeerStore {
    let defaultsKey: String

    var peers: [Peer] {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([Peer].self, from: d)) ?? []
    }

    func secret(for id: String) -> Data? { KeychainStore.get(account: "secret.\(id)") }

    func save(_ peer: Peer, secret: Data) throws {
        try KeychainStore.set(secret, account: "secret.\(peer.id)")
        var all = peers.filter { $0.id != peer.id }
        all.append(peer)
        UserDefaults.standard.set(try JSONEncoder().encode(all), forKey: defaultsKey)
    }

    func removeAll() {
        peers.forEach { KeychainStore.delete(account: "secret.\($0.id)") }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
