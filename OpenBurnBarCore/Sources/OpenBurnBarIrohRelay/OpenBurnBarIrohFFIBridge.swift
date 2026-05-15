// Bridge between the UniFFI-generated `OpenBurnBarIrohFFI` module and the
// transport-level `IrohEndpointBackend` protocol.
//
// `OpenBurnBarIrohFFI` is the Swift package emitted by
// `scripts/build-iroh-xcframework.sh` from `crates/openburnbar-iroh`. It is
// not vendored into this repository — the xcframework binary lives in the
// release artifacts published by `.github/workflows/iroh-xcframework.yml`,
// and consumers add it through the OpenBurnBarMobile / AgentLens xcconfig.
//
// This file is conditional on `canImport(OpenBurnBarIrohFFI)` so the
// SwiftPM package still compiles before the xcframework has been published.
// Once a consuming app links the framework, this bridge becomes available
// and `OpenBurnBarIrohFFIBackendFactory.make()` returns a production
// backend; otherwise it returns `nil` and callers must fall back to the
// loopback transport or the WSS relay.

import Foundation

#if canImport(OpenBurnBarIrohFFI)
import OpenBurnBarIrohFFI

/// Adapts the UniFFI-generated `IrohEndpointHandle` + `IrohStream` to our
/// transport-level protocols. Every Rust call is wrapped in
/// `withCheckedThrowingContinuation` on a dedicated dispatch queue so we
/// never hop the iroh runtime on the main thread.
public final class OpenBurnBarIrohFFIBackend: IrohEndpointBackend, @unchecked Sendable {
    private let handle: IrohEndpointHandle
    private let queue: DispatchQueue

    public init() {
        self.handle = IrohEndpointHandle()
        self.queue = DispatchQueue(label: "ai.openburnbar.iroh.ffi", qos: .userInitiated)
    }

    public func bootstrap(secret: Data, relayURL: String?) async throws -> IrohEndpointIdentity {
        try await withFFI { [handle] in
            let identity = try handle.bootstrap(
                secret: IrohSecretKeyMaterial(raw: Array(secret)),
                relayUrl: relayURL ?? ""
            )
            return IrohEndpointIdentity(
                nodeId: identity.nodeId,
                rawPublicKey: Data(identity.rawPublicKey)
            )
        }
    }

    public func identity() async throws -> IrohEndpointIdentity {
        try await withFFI { [handle] in
            let identity = try handle.identity()
            return IrohEndpointIdentity(
                nodeId: identity.nodeId,
                rawPublicKey: Data(identity.rawPublicKey)
            )
        }
    }

    public func connect(to nodeId: String, timeout: TimeInterval) async throws -> IrohBackendStream {
        try await withFFI { [handle] in
            let stream = try handle.connect(
                nodeId: nodeId,
                timeoutSeconds: UInt32(max(1, Int(timeout.rounded(.up))))
            )
            return OpenBurnBarIrohFFIStream(stream: stream, queue: self.queue)
        }
    }

    public func acceptOne(timeout: TimeInterval) async throws -> IrohBackendStream {
        try await withFFI { [handle] in
            let stream = try handle.acceptOne(
                timeoutSeconds: UInt32(max(1, Int(timeout.rounded(.up))))
            )
            return OpenBurnBarIrohFFIStream(stream: stream, queue: self.queue)
        }
    }

    public func shutdown() async {
        await withCheckedContinuation { continuation in
            queue.async { [handle] in
                _ = try? handle.shutdown()
                continuation.resume()
            }
        }
    }

    /// Runs the Rust call on the FFI queue and surfaces UniFFI errors as
    /// `IrohBackendError`. We translate at the boundary so callers never
    /// import the FFI-generated error types.
    private func withFFI<T>(_ block: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                do {
                    let value = try block()
                    continuation.resume(returning: value)
                } catch let ffiError as IrohFfiError {
                    continuation.resume(throwing: Self.translate(ffiError))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func translate(_ error: IrohFfiError) -> IrohBackendError {
        switch error {
        case .InvalidSecretKey: return .invalidSecretKey
        case .InvalidNodeId: return .invalidNodeId
        case .EndpointNotInitialized: return .notInitialized
        case .ConnectFailed(let message): return .connectFailed(message)
        case .StreamFailed(let message): return .streamFailed(message)
        case .AcceptFailed(let message): return .acceptFailed(message)
        case .ShutdownFailed(let message): return .shutdownFailed(message)
        case .RuntimeFailed(let message): return .runtimeFailed(message)
        }
    }
}

public final class OpenBurnBarIrohFFIStream: IrohBackendStream, @unchecked Sendable {
    private let stream: IrohStream
    private let queue: DispatchQueue

    init(stream: IrohStream, queue: DispatchQueue) {
        self.stream = stream
        self.queue = queue
    }

    public func sendFrame(_ envelope: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [stream] in
                do {
                    try stream.sendFrame(frame: Array(envelope))
                    continuation.resume()
                } catch let ffiError as IrohFfiError {
                    continuation.resume(throwing: OpenBurnBarIrohFFIBackend.translate(ffiError))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func recvFrame() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            queue.async { [stream] in
                do {
                    if let bytes = try stream.recvFrame() {
                        continuation.resume(returning: Data(bytes))
                    } else {
                        continuation.resume(returning: nil)
                    }
                } catch let ffiError as IrohFfiError {
                    continuation.resume(throwing: OpenBurnBarIrohFFIBackend.translate(ffiError))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [stream] in
                _ = try? stream.close()
                continuation.resume()
            }
        }
    }
}
#endif

/// Factory the consuming app uses to construct a production backend. Returns
/// `nil` when the xcframework binary has not been linked — callers should
/// fall back to the loopback transport or the WSS relay.
public enum OpenBurnBarIrohFFIBackendFactory {
    public static func make() -> IrohEndpointBackend? {
        #if canImport(OpenBurnBarIrohFFI)
        return OpenBurnBarIrohFFIBackend()
        #else
        return nil
        #endif
    }
}
