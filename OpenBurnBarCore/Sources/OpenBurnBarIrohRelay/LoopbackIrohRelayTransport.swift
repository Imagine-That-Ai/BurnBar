import Foundation
import OpenBurnBarCore

/// In-process iroh transport for tests + the spine demo. Pairs Mac-side and
/// iOS-side endpoints through a shared rendezvous. Frames are encoded with
/// the same `IrohRelayFrameCodec` the production transport uses, so this
/// covers the on-wire envelope byte-for-byte.
///
/// Why in-process and not loopback UDP: we want a deterministic, hermetic
/// fixture for unit tests (no `bind(0.0.0.0)`, no kernel-level scheduling,
/// no Sim/Mac sandbox differences). The xcframework-backed transport runs
/// against real iroh in CI's `iroh-xcframework.yml` workflow and in the
/// device test plan.
public final class LoopbackIrohRelayRendezvous: @unchecked Sendable {
    private let lock = NSLock()
    private var registeredHosts: [String: LoopbackIrohRelayTransport] = [:]
    private var pendingByPeer: [String: [PendingConnect]] = [:]

    public init() {}

    /// Used by `LoopbackIrohRelayTransport.start()` to publish itself.
    func register(transport: LoopbackIrohRelayTransport, nodeId: String) {
        lock.lock()
        registeredHosts[nodeId] = transport
        let waiters = pendingByPeer.removeValue(forKey: nodeId) ?? []
        lock.unlock()
        for waiter in waiters {
            transport._fulfillDial(connectId: waiter.id, continuation: waiter.continuation)
        }
    }

    func deregister(nodeId: String) {
        lock.lock(); defer { lock.unlock() }
        registeredHosts.removeValue(forKey: nodeId)
    }

    /// Used by `connect(to:)`. Resolves immediately if the peer is already
    /// registered; otherwise parks the continuation until the peer registers.
    func dial(
        toPeer peer: String,
        timeout: TimeInterval
    ) async throws -> any IrohRelayStream {
        let connectId = UUID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<any IrohRelayStream, Error>) in
                lock.lock()
                if let host = registeredHosts[peer] {
                    lock.unlock()
                    host._fulfillDial(connectId: connectId, continuation: continuation)
                } else {
                    pendingByPeer[peer, default: []].append(
                        PendingConnect(id: connectId, continuation: continuation)
                    )
                    lock.unlock()
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        self.cancelPending(connectId: connectId, peer: peer, with: .timedOut)
                    }
                }
            }
        } onCancel: {
            self.cancelPending(connectId: connectId, peer: peer, with: .shutdown)
        }
    }

    private func cancelPending(connectId: UUID, peer: String, with error: IrohRelayTransportError) {
        lock.lock()
        guard var queue = pendingByPeer[peer] else { lock.unlock(); return }
        guard let idx = queue.firstIndex(where: { $0.id == connectId }) else { lock.unlock(); return }
        let entry = queue.remove(at: idx)
        if queue.isEmpty { pendingByPeer.removeValue(forKey: peer) } else { pendingByPeer[peer] = queue }
        lock.unlock()
        entry.continuation.resume(throwing: error)
    }

    private struct PendingConnect {
        let id: UUID
        let continuation: CheckedContinuation<any IrohRelayStream, Error>
    }
}

/// Tiny FIFO of `Data` blocks shared between the two halves of a paired
/// stream. Backed by an actor for serialized push/pop.
actor LoopbackQueue {
    private var buffer: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var closed = false

    func push(_ data: Data) {
        if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(returning: data)
            return
        }
        buffer.append(data)
    }

    func pop() async -> Data? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            self.waiter = continuation
        }
    }

    func close() {
        closed = true
        if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }
}

/// A pair of queues, used to express "client → host" and "host → client"
/// directions. Two `LoopbackIrohRelayStream` instances share one
/// `LoopbackStreamPair` but flip their (read, write) assignment.
struct LoopbackStreamPair: Sendable {
    let clientToHost: LoopbackQueue
    let hostToClient: LoopbackQueue

    static func make() -> LoopbackStreamPair {
        LoopbackStreamPair(clientToHost: LoopbackQueue(), hostToClient: LoopbackQueue())
    }
}

/// Stream half of the loopback transport. Encodes/decodes via the same
/// `IrohRelayFrameCodec` the xcframework-backed transport uses. Each stream
/// is single-reader / single-writer by contract — the recv side accumulates
/// into a private buffer protected by an actor.
public final class LoopbackIrohRelayStream: IrohRelayStream, @unchecked Sendable {
    private let readQueue: LoopbackQueue
    private let writeQueue: LoopbackQueue
    private let codec: IrohRelayFrameCodec
    private let receiveBuffer = LoopbackStreamReceiveBuffer()

    init(readQueue: LoopbackQueue, writeQueue: LoopbackQueue, codec: IrohRelayFrameCodec) {
        self.readQueue = readQueue
        self.writeQueue = writeQueue
        self.codec = codec
    }

    public func send(_ frame: HermesRealtimeRelayFrame) async throws {
        let envelope = try codec.encode(frame)
        await writeQueue.push(envelope)
    }

    public func receive() async throws -> HermesRealtimeRelayFrame? {
        while true {
            if let working = await receiveBuffer.snapshotIfReady() {
                do {
                    let (frame, consumed) = try codec.decode(from: working)
                    await receiveBuffer.drain(prefix: consumed)
                    return frame
                } catch IrohRelayTransportError.decodeFailed {
                    // Need more bytes; fall through.
                } catch {
                    throw error
                }
            }
            guard let chunk = await readQueue.pop() else {
                let leftover = await receiveBuffer.byteCount()
                if leftover > 0 {
                    throw IrohRelayTransportError.decodeFailed("stream closed mid-frame with \(leftover) bytes buffered")
                }
                return nil
            }
            await receiveBuffer.append(chunk)
        }
    }

    public func close() async {
        await writeQueue.close()
    }
}

actor LoopbackStreamReceiveBuffer {
    private var bytes = Data()

    func append(_ chunk: Data) { bytes.append(chunk) }
    func byteCount() -> Int { bytes.count }
    func snapshotIfReady() -> Data? {
        bytes.count >= IrohRelayProtocol.WireFormat.lengthPrefixBytes ? bytes : nil
    }
    /// Drain the leading `prefix` bytes and re-base the storage so the
    /// remaining bytes start at index 0. `Data.removeFirst(_:)` mutates the
    /// view in place but does NOT normalize indices, and the JSON decoder
    /// downstream uses raw pointer arithmetic that assumes a zero-based
    /// origin; copying the survivors through `Data(...)` resets the start
    /// index without measurable cost for relay-sized payloads.
    func drain(prefix: Int) {
        bytes.removeFirst(prefix)
        bytes = Data(bytes)
    }
}

/// Public loopback transport. `start()` registers in the rendezvous;
/// `connect(to:)` dials; `accept()` returns the next inbound stream.
public final class LoopbackIrohRelayTransport: IrohRelayTransport, @unchecked Sendable {
    private let rendezvous: LoopbackIrohRelayRendezvous
    private let identity: IrohEndpointIdentity
    private let codec: IrohRelayFrameCodec
    private let acceptQueue = LoopbackAcceptQueue()
    private let state = LoopbackStartedFlag()

    public init(
        nodeId: String? = nil,
        rendezvous: LoopbackIrohRelayRendezvous,
        codec: IrohRelayFrameCodec = IrohRelayFrameCodec()
    ) {
        let resolved = nodeId ?? Self.randomLoopbackNodeId()
        self.identity = IrohEndpointIdentity(
            nodeId: resolved,
            rawPublicKey: Data(repeating: 0, count: 32)
        )
        self.rendezvous = rendezvous
        self.codec = codec
    }

    public func start() async throws -> IrohEndpointIdentity {
        let wasFirst = await state.start()
        if wasFirst {
            rendezvous.register(transport: self, nodeId: identity.nodeId)
        }
        return identity
    }

    public func connect(to peer: String, timeout: TimeInterval) async throws -> any IrohRelayStream {
        guard await state.isStarted() else { throw IrohRelayTransportError.endpointNotReady }
        return try await rendezvous.dial(toPeer: peer, timeout: timeout)
    }

    public func accept(timeout: TimeInterval) async throws -> any IrohRelayStream {
        guard await state.isStarted() else { throw IrohRelayTransportError.endpointNotReady }
        return try await acceptQueue.pop(timeout: timeout)
    }

    public func shutdown() async {
        let wasStarted = await state.shutdown()
        guard wasStarted else { return }
        rendezvous.deregister(nodeId: identity.nodeId)
        await acceptQueue.shutdown()
    }

    // MARK: - Rendezvous bridge

    /// Builds one shared `LoopbackStreamPair`, resolves the dialer's
    /// continuation with the client-side stream, and enqueues the host-side
    /// stream for the next `accept(timeout:)` call.
    func _fulfillDial(
        connectId: UUID,
        continuation: CheckedContinuation<any IrohRelayStream, Error>
    ) {
        let pair = LoopbackStreamPair.make()
        let clientStream = LoopbackIrohRelayStream(
            readQueue: pair.hostToClient,
            writeQueue: pair.clientToHost,
            codec: codec
        )
        let hostStream = LoopbackIrohRelayStream(
            readQueue: pair.clientToHost,
            writeQueue: pair.hostToClient,
            codec: codec
        )
        continuation.resume(returning: clientStream)
        Task { [acceptQueue, hostStream] in
            await acceptQueue.push(stream: hostStream)
        }
    }

    private static func randomLoopbackNodeId() -> String {
        // Length-52 alphanumeric, mimics the iroh NodeId surface form so any
        // string-validation downstream of this transport receives a realistic
        // value. The cryptographic NodeId is owned by the xcframework
        // transport; loopback callers must not trust this value for identity.
        let alphabet = "abcdefghijklmnopqrstuvwxyz234567"
        return String((0..<52).map { _ in alphabet.randomElement()! })
    }
}

actor LoopbackStartedFlag {
    private var started = false

    func start() -> Bool {
        if started { return false }
        started = true
        return true
    }

    func isStarted() -> Bool { started }

    func shutdown() -> Bool {
        if !started { return false }
        started = false
        return true
    }
}

actor LoopbackAcceptQueue {
    private var queue: [any IrohRelayStream] = []
    private var waiter: CheckedContinuation<any IrohRelayStream, Error>?
    private var closed = false

    func push(stream: any IrohRelayStream) {
        if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(returning: stream)
            return
        }
        queue.append(stream)
    }

    func pop(timeout: TimeInterval) async throws -> any IrohRelayStream {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { throw IrohRelayTransportError.shutdown }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<any IrohRelayStream, Error>) in
            self.waiter = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeOutWaiter()
            }
        }
    }

    func shutdown() {
        closed = true
        if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(throwing: IrohRelayTransportError.shutdown)
        }
        queue.removeAll()
    }

    private func timeOutWaiter() {
        guard let waiter = self.waiter else { return }
        self.waiter = nil
        waiter.resume(throwing: IrohRelayTransportError.timedOut)
    }
}
