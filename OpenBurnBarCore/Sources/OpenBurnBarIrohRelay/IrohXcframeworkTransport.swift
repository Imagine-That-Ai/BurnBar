import Foundation
import OpenBurnBarCore

/// Production `IrohRelayTransport` implementation. Owns the secret-key
/// lifecycle, drives an `IrohEndpointBackend` (the UniFFI-generated handle
/// at runtime, a fake during tests), and wraps each backend stream in an
/// `IrohRelayStream` that re-uses the same `IrohRelayFrameCodec` the
/// loopback transport ships.
public final class IrohXcframeworkTransport: IrohRelayTransport, @unchecked Sendable {
    private let backend: IrohEndpointBackend
    private let codec: IrohRelayFrameCodec
    private let secretProvider: @Sendable () throws -> IrohSecretKeyMaterial
    private let relayURLProvider: @Sendable () -> String?
    private let state = LoopbackStartedFlag()
    private actor IdentityCache {
        var value: IrohEndpointIdentity?
        func set(_ identity: IrohEndpointIdentity) { value = identity }
        func get() -> IrohEndpointIdentity? { value }
        func clear() { value = nil }
    }
    private let identityCache = IdentityCache()

    public init(
        backend: IrohEndpointBackend,
        codec: IrohRelayFrameCodec = IrohRelayFrameCodec(),
        secretProvider: @escaping @Sendable () throws -> IrohSecretKeyMaterial,
        relayURLProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.backend = backend
        self.codec = codec
        self.secretProvider = secretProvider
        self.relayURLProvider = relayURLProvider
    }

    public func start() async throws -> IrohEndpointIdentity {
        let wasFirst = await state.start()
        if wasFirst {
            do {
                let secret = try secretProvider()
                let identity = try await backend.bootstrap(
                    secret: secret.raw,
                    relayURL: relayURLProvider()
                )
                await identityCache.set(identity)
                return identity
            } catch let backendError as IrohBackendError {
                _ = await state.shutdown()
                throw IrohXcframeworkTransport.surface(backendError)
            } catch {
                _ = await state.shutdown()
                throw error
            }
        }
        if let cached = await identityCache.get() {
            return cached
        }
        return try await backend.identity()
    }

    public func connect(to peer: String, timeout: TimeInterval) async throws -> any IrohRelayStream {
        guard await state.isStarted() else { throw IrohRelayTransportError.endpointNotReady }
        do {
            let stream = try await backend.connect(to: peer, timeout: timeout)
            return IrohBackendStreamAdapter(stream: stream, codec: codec)
        } catch let backendError as IrohBackendError {
            throw IrohXcframeworkTransport.surface(backendError)
        }
    }

    public func accept(timeout: TimeInterval) async throws -> any IrohRelayStream {
        guard await state.isStarted() else { throw IrohRelayTransportError.endpointNotReady }
        do {
            let stream = try await backend.acceptOne(timeout: timeout)
            return IrohBackendStreamAdapter(stream: stream, codec: codec)
        } catch let backendError as IrohBackendError {
            throw IrohXcframeworkTransport.surface(backendError)
        }
    }

    public func shutdown() async {
        let wasStarted = await state.shutdown()
        guard wasStarted else { return }
        await backend.shutdown()
        await identityCache.clear()
    }

    /// Bridges backend error semantics into the public transport surface.
    /// Connect timeouts collapse to `.timedOut` so the WSS fallback path in
    /// `HermesCompositeRelayTransport` triggers the same way as on the
    /// loopback transport.
    static func surface(_ error: IrohBackendError) -> IrohRelayTransportError {
        switch error {
        case .notInitialized:
            return .endpointNotReady
        case .invalidSecretKey, .invalidNodeId, .runtimeFailed:
            return .streamRejected("iroh backend rejected request: \(error)")
        case .connectFailed(let message):
            if message.lowercased().contains("timed out") {
                return .timedOut
            }
            return .streamRejected("iroh connect failed: \(message)")
        case .streamFailed(let message):
            // Transport-layer stream errors (write_all / read_exact / quic
            // connection drops) are NOT decode errors — the bytes never
            // made it past the wire. Misclassifying them as `.decodeFailed`
            // confuses the cascade because higher layers treat decode
            // errors as "the peer sent garbage" instead of "the stream is
            // dead, fall back".
            if message.lowercased().contains("timed out") {
                return .timedOut
            }
            return .streamRejected("iroh stream failed: \(message)")
        case .acceptFailed(let message):
            if message.lowercased().contains("timed out") {
                return .timedOut
            }
            return .streamRejected("iroh accept failed: \(message)")
        case .shutdownFailed(let message):
            return .streamRejected("iroh shutdown failed: \(message)")
        }
    }
}

/// Wraps an `IrohBackendStream` (Rust handle) in the `IrohRelayStream`
/// contract by feeding raw envelopes through `IrohRelayFrameCodec`. The
/// length prefix is decoded by the backend itself, so on this side we
/// already have one whole envelope per `recvFrame` call.
public final class IrohBackendStreamAdapter: IrohRelayStream, @unchecked Sendable {
    private let stream: IrohBackendStream
    private let codec: IrohRelayFrameCodec

    public init(stream: IrohBackendStream, codec: IrohRelayFrameCodec) {
        self.stream = stream
        self.codec = codec
    }

    public func send(_ frame: HermesRealtimeRelayFrame) async throws {
        let envelope: Data
        do {
            envelope = try codec.encode(frame)
        } catch {
            throw error
        }
        do {
            try await stream.sendFrame(envelope)
        } catch let backendError as IrohBackendError {
            throw IrohXcframeworkTransport.surface(backendError)
        }
    }

    public func receive() async throws -> HermesRealtimeRelayFrame? {
        let envelope: Data?
        do {
            envelope = try await stream.recvFrame()
        } catch let backendError as IrohBackendError {
            throw IrohXcframeworkTransport.surface(backendError)
        }
        guard let envelope else { return nil }
        let (frame, _) = try codec.decode(from: envelope)
        return frame
    }

    public func close() async {
        await stream.close()
    }
}
