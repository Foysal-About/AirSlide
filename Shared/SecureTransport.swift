import Foundation
import Network
import CryptoKit

/// Length-prefixed, ChaChaPoly-sealed frames over a TCP `NWConnection`.
/// Frame = UInt32 BE length + sealed(kind byte + payload). The key comes from the pairing secret.
// shortcut: no replay protection or forward secrecy, add a per-session nonce exchange if needed.
final class SecureChannel {
    let conn: NWConnection
    private(set) var key: SymmetricKey?
    static let queue = DispatchQueue(label: "com.airslide.connection")

    init(_ conn: NWConnection, secret: Data? = nil) {
        self.conn = conn
        self.key = secret.map(Self.deriveKey)
    }

    static func deriveKey(_ secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                               salt: Data("airslide".utf8), info: Data("v1".utf8), outputByteCount: 32)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var done = false
            conn.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready: done = true; c.resume()
                case .failed(let e): done = true; c.resume(throwing: e)
                case .cancelled: done = true; c.resume(throwing: AirSlideError.closed)
                default: break
                }
            }
            conn.start(queue: Self.queue)
        }
    }

    func close() { conn.cancel() }

    func setSecret(_ secret: Data) { key = Self.deriveKey(secret) }

    /// Unencrypted frame (high bit set in the length). Used only for the pairing key exchange.
    func sendPlain(_ m: Message) async throws {
        let body = try JSONEncoder().encode(m)
        var len = (UInt32(body.count) | 0x8000_0000).bigEndian
        let frame = Data(bytes: &len, count: 4) + body
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            })
        }
    }

    func send(_ m: Message) async throws {
        try await send(kind: Wire.kindMessage, try JSONEncoder().encode(m))
    }

    func send(kind: UInt8, _ payload: Data) async throws {
        guard let key else { throw AirSlideError.closed }
        let sealed = try ChaChaPoly.seal(Data([kind]) + payload, using: key).combined
        var len = UInt32(sealed.count).bigEndian
        let frame = Data(bytes: &len, count: 4) + sealed
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            })
        }
    }

    func receive() async throws -> (kind: UInt8, payload: Data) {
        guard let key else { throw AirSlideError.closed }
        let r = try await receiveFrame(keys: [key])
        return (r.kind, r.payload)
    }

    func receiveMessage() async throws -> Message {
        let (kind, payload) = try await receive()
        guard kind == Wire.kindMessage else { throw AirSlideError.unexpected }
        return try Self.decode(payload)
    }

    /// Tries each candidate key; the first one that opens the frame becomes this channel's key.
    /// A plain pairing frame comes back with index -1, and only when `allowPlain` is set.
    func receiveFrame(keys: [SymmetricKey], allowPlain: Bool = false) async throws -> (index: Int, kind: UInt8, payload: Data) {
        let head = try await read(4)
        let raw = head.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        if raw & 0x8000_0000 != 0 {
            let n = Int(raw & 0x7fff_ffff)
            guard allowPlain, n > 0, n <= 4096 else { throw AirSlideError.malformed }
            return (-1, Wire.kindMessage, try await read(n))
        }
        let len = Int(raw)
        guard len > 28, len <= Wire.chunkSize + 1024 else { throw AirSlideError.malformed }
        let sealed = try await read(len)
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed) else { throw AirSlideError.malformed }
        for (i, k) in keys.enumerated() {
            if let plain = try? ChaChaPoly.open(box, using: k), let kind = plain.first {
                key = k
                return (i, kind, Data(plain.dropFirst()))
            }
        }
        throw AirSlideError.malformed
    }

    static func decode(_ payload: Data) throws -> Message {
        do { return try JSONDecoder().decode(Message.self, from: payload) }
        catch { throw AirSlideError.malformed }
    }

    private func read(_ n: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, err in
                if let err { c.resume(throwing: err) }
                else if let data, data.count == n { c.resume(returning: data) }
                else { c.resume(throwing: AirSlideError.closed) }
            }
        }
    }
}
