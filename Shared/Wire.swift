import Foundation
import CryptoKit
import Network

enum Wire {
    static let service = "_airslide._tcp"
    static let version = 4
    static let chunkSize = 256 * 1024
    static let kindMessage: UInt8 = 0
    static let kindData: UInt8 = 1

    /// TCP that can also run over peer-to-peer Wi-Fi (AWDL), so nearby devices connect even on different networks.
    static var params: NWParameters {
        let p = NWParameters.tcp
        p.includePeerToPeer = true
        return p
    }
}

/// JSON control messages. File bytes travel as separate `kindData` frames.
enum Message: Codable {
    case hello(deviceID: String, name: String, version: Int)
    case helloAck(accepted: Bool, macName: String, reason: String?)
    /// Live drag position so the other device can animate the file arriving.
    /// phase: begin | move | drop | cancel. `edge` is the SENDER's edge being crossed; the receiver shows
    /// the file entering from the opposite edge. `pos` (0...1) is along that edge, `depth` (0...1) how far across.
    case drag(phase: String, token: String, name: String, kind: String, pos: Double, depth: Double, edge: AirEdge, preview: Data?)
    case fileOffer(id: String, name: String, size: Int64, preview: Data?)
    case fileAccept(id: String, accepted: Bool, reason: String?)
    case fileEnd(id: String, sha256: String)
    case fileResult(id: String, ok: Bool, reason: String?)
    // Pairing by code: public keys travel in the clear, the 4-digit code (derived from both keys) is compared by the user.
    case pairRequest(deviceID: String, name: String, pub: Data)
    case pairOffer(macID: String, macName: String, pub: Data)
    case pairResult(accepted: Bool)
}

enum AirEdge: String, Codable, CaseIterable {
    case left, right, top, bottom
    var opposite: AirEdge {
        switch self { case .left: .right; case .right: .left; case .top: .bottom; case .bottom: .top }
    }
}

struct Peer: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var pairedAt: Date
}

enum AirSlideError: LocalizedError {
    case closed, timeout, malformed, unexpected, versionMismatch, incomplete, busy
    case declined(String?), saveFailed, noSpace, noTempFile, noFreeName, randomFailed, notPaired

    var errorDescription: String? {
        switch self {
        case .closed: "The connection was closed."
        case .timeout: "The connection timed out."
        case .malformed: "Received malformed data."
        case .unexpected: "Received an unexpected message."
        case .versionMismatch: "The apps are running incompatible versions."
        case .incomplete: "The file arrived incomplete."
        case .busy: "Still receiving another file."
        case .declined(let r): r ?? "The other device declined the file."
        case .saveFailed: "The file could not be saved."
        case .noSpace: "Not enough free space."
        case .noTempFile: "Could not create a temporary file."
        case .noFreeName: "Could not find a free file name."
        case .randomFailed: "Secure random generation failed"
        case .notPaired: "This Mac doesn't know this iPhone. Pair again."
        }
    }
}

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
