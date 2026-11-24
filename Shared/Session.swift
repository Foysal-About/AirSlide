import Foundation
import CryptoKit

enum SessionEvent {
    case drag(phase: String, token: String, name: String, kind: String, pos: Double, depth: Double, edge: AirEdge, preview: Data?)
    case incomingStarted(id: String, name: String, size: Int64, preview: Data?)
    case incomingProgress(id: String, fraction: Double)
    case incomingFinished(id: String, url: URL)
    case incomingFailed(id: String, reason: String)
    case outgoingStarted(id: String, name: String, size: Int64)
    case outgoingProgress(id: String, fraction: Double)
    case outgoingFinished(id: String)
    case outgoingFailed(id: String, reason: String)
}

/// One paired, authenticated connection. Both sides can send and receive files at the same time
/// (one file per direction). A single reader task dispatches everything that arrives.
actor Session {
    nonisolated let peerName: String
    nonisolated let events: AsyncStream<SessionEvent>

    private let cont: AsyncStream<SessionEvent>.Continuation
    private nonisolated let dragCont: AsyncStream<Message>.Continuation
    private let dragStream: AsyncStream<Message>
    private nonisolated let ch: SecureChannel
    private let sink: FileSink

    private final class Incoming {
        let id: String, name: String, size: Int64, writer: FileWriter
        var hasher = SHA256()
        var got: Int64 = 0
        init(id: String, name: String, size: Int64, writer: FileWriter) {
            self.id = id; self.name = name; self.size = size; self.writer = writer
        }
    }

    private var incoming: Incoming?
    private var mailbox: [String: Message] = [:]
    private var waiters: [String: CheckedContinuation<Message, Error>] = [:]
    private var sendTail: Task<Void, Never>?

    init(channel: SecureChannel, peerName: String, sink: FileSink) {
        self.ch = channel
        self.peerName = peerName
        self.sink = sink
        (events, cont) = AsyncStream<SessionEvent>.makeStream()
        (dragStream, dragCont) = AsyncStream<Message>.makeStream()
    }

    func start() {
        Task { await self.run() }
        // Drag updates go through one ordered queue so "move" can never overtake "drop".
        Task { [dragStream, ch] in for await m in dragStream { try? await ch.send(m) } }
    }

    nonisolated func close() { ch.close() }

    nonisolated func drag(_ m: Message) { dragCont.yield(m) }

    // MARK: Sending

    func send(url: URL, id: String, preview: Data?) async {
        let prev = sendTail
        let t = Task { await prev?.value; await self.transmit(url, id, preview) }
        sendTail = t
        await t.value
    }

    private func transmit(_ url: URL, _ id: String, _ preview: Data?) async {
        do {
            let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            cont.yield(.outgoingStarted(id: id, name: url.lastPathComponent, size: size))
            try await ch.send(.fileOffer(id: id, name: url.lastPathComponent, size: size, preview: preview))
            guard case .fileAccept(_, let ok, let reason) = try await next("accept:\(id)") else { throw AirSlideError.unexpected }
            guard ok else { throw AirSlideError.declined(reason) }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var sent: Int64 = 0
            while let chunk = try handle.read(upToCount: Wire.chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
                try await ch.send(kind: Wire.kindData, chunk)
                sent += Int64(chunk.count)
                cont.yield(.outgoingProgress(id: id, fraction: size > 0 ? Double(sent) / Double(size) : 1))
            }
            try await ch.send(.fileEnd(id: id, sha256: hasher.finalize().hex))
            guard case .fileResult(_, let good, let why) = try await next("result:\(id)") else { throw AirSlideError.unexpected }
            guard good else { throw AirSlideError.declined(why) }
            cont.yield(.outgoingFinished(id: id))
        } catch {
            cont.yield(.outgoingFailed(id: id, reason: error.localizedDescription))
        }
    }

    private func next(_ key: String) async throws -> Message {
        if let m = mailbox.removeValue(forKey: key) { return m }
        return try await withCheckedThrowingContinuation { waiters[key] = $0 }
    }

    private func deliver(_ key: String, _ m: Message) {
        if let w = waiters.removeValue(forKey: key) { w.resume(returning: m) } else { mailbox[key] = m }
    }

    // MARK: Receiving

    private func run() async {
        do {
            while true {
                let (kind, payload) = try await ch.receive()
                if kind == Wire.kindData { try onData(payload) }
                else { try await onMessage(SecureChannel.decode(payload)) }
            }
        } catch {}
        if let inc = incoming {
            inc.writer.discard()
            cont.yield(.incomingFailed(id: inc.id, reason: AirSlideError.closed.localizedDescription))
            incoming = nil
        }
        for (_, w) in waiters { w.resume(throwing: AirSlideError.closed) }
        waiters = [:]
        dragCont.finish()
        cont.finish()
    }

    private func onData(_ payload: Data) throws {
        guard let inc = incoming else { throw AirSlideError.unexpected }
        inc.got += Int64(payload.count)
        guard inc.got <= inc.size else { throw AirSlideError.malformed }
        try inc.writer.write(payload)
        inc.hasher.update(data: payload)
        cont.yield(.incomingProgress(id: inc.id, fraction: inc.size > 0 ? Double(inc.got) / Double(inc.size) : 1))
    }

    private func onMessage(_ m: Message) async throws {
        switch m {
        case .drag(let phase, let token, let name, let kind, let pos, let depth, let edge, let preview):
            cont.yield(.drag(phase: phase, token: token, name: name, kind: kind, pos: pos, depth: depth, edge: edge, preview: preview))

        case .fileOffer(let id, let name, let size, let preview):
            guard incoming == nil else {
                try await ch.send(.fileAccept(id: id, accepted: false, reason: AirSlideError.busy.localizedDescription))
                return
            }
            do {
                let w = try sink.begin(requiredBytes: size)
                incoming = Incoming(id: id, name: name, size: size, writer: w)
                cont.yield(.incomingStarted(id: id, name: name, size: size, preview: preview))
                try await ch.send(.fileAccept(id: id, accepted: true, reason: nil))
            } catch {
                try await ch.send(.fileAccept(id: id, accepted: false, reason: error.localizedDescription))
            }

        case .fileEnd(let id, let sha):
            guard let inc = incoming, inc.id == id else { throw AirSlideError.unexpected }
            incoming = nil
            do {
                guard inc.got == inc.size, inc.hasher.finalize().hex == sha else { throw AirSlideError.incomplete }
                let url = try inc.writer.finish(as: inc.name)
                try await ch.send(.fileResult(id: id, ok: true, reason: nil))
                cont.yield(.incomingFinished(id: id, url: url))
            } catch {
                inc.writer.discard()
                try? await ch.send(.fileResult(id: id, ok: false, reason: error.localizedDescription))
                cont.yield(.incomingFailed(id: id, reason: error.localizedDescription))
            }

        case .fileAccept(let id, _, _): deliver("accept:\(id)", m)
        case .fileResult(let id, _, _): deliver("result:\(id)", m)
        case .hello, .helloAck, .pairRequest, .pairOffer, .pairResult: throw AirSlideError.unexpected
        }
    }
}
