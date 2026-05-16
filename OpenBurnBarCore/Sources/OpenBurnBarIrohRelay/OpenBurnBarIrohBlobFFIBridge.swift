// Bridge for the iroh-blobs side of the Mercury media rollout. Wraps the
// UniFFI-generated `IrohBlobNode` from `OpenBurnBarIrohFFI` and surfaces
// it as `IrohBlobBackend`. Conditional on `canImport(OpenBurnBarIrohFFI)`
// so the SwiftPM package keeps compiling before the xcframework reships.
//
// See `crates/openburnbar-iroh/src/blobs.rs` for the Rust side and
// `docs/HERMES_MEDIA_TRANSPORT.md` § Phase 1 for the architecture.

import Foundation

#if canImport(OpenBurnBarIrohFFI)
@preconcurrency import OpenBurnBarIrohFFI

public final class OpenBurnBarIrohBlobFFIBackend: IrohBlobBackend, @unchecked Sendable {
    private let node: IrohBlobNode
    private let queue: DispatchQueue

    public init() {
        self.node = IrohBlobNode()
        self.queue = DispatchQueue(label: "ai.openburnbar.iroh.blob.ffi", qos: .userInitiated)
    }

    public func bootstrap(
        secret: Data,
        storeDirectoryPath: String,
        relayURL: String?
    ) async throws -> IrohEndpointIdentity {
        try await withFFI { [node] in
            let identity = try node.bootstrap(
                secret: OpenBurnBarIrohFFI.IrohSecretKeyMaterial(raw: secret),
                storeDir: storeDirectoryPath,
                relayUrl: relayURL ?? ""
            )
            return IrohEndpointIdentity(
                nodeId: identity.nodeId,
                rawPublicKey: Data(identity.rawPublicKey)
            )
        }
    }

    public func publishBlob(localPath: String) async throws -> String {
        try await withFFI { [node] in
            let ticket = try node.publishBlob(localPath: localPath)
            return ticket.text
        }
    }

    public func fetchBlob(ticketText: String, destination: String) async throws -> BlobTransferStats {
        try await withFFI { [node] in
            let stats = try node.fetchBlob(ticketText: ticketText, destination: destination)
            return BlobTransferStats(
                bytesTotal: stats.bytesTotal,
                blake3Hash: stats.blake3Hash,
                durationMillis: stats.durationMillis,
                didResume: stats.didResume
            )
        }
    }

    public func identity() async throws -> IrohEndpointIdentity {
        try await withFFI { [node] in
            let identity = try node.identity()
            return IrohEndpointIdentity(
                nodeId: identity.nodeId,
                rawPublicKey: Data(identity.rawPublicKey)
            )
        }
    }

    public func shutdown() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [node] in
                _ = try? node.shutdown()
                continuation.resume()
            }
        }
    }

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

    static func translate(_ error: IrohFfiError) -> IrohBlobBackendError {
        switch error {
        case .InvalidSecretKey: return .invalidSecretKey
        case .EndpointNotInitialized: return .notInitialized
        case .StreamFailed(let message): return .invalidTicket(message)
        case .RuntimeFailed(let message): return .runtimeFailed(message)
        case .ConnectFailed(let message): return .fetchFailed(message)
        case .AcceptFailed(let message): return .runtimeFailed(message)
        case .ShutdownFailed(let message): return .runtimeFailed(message)
        case .InvalidNodeId: return .invalidTicket("invalid node id")
        }
    }
}
#endif

/// Factory the consuming app uses to construct a production blob backend.
/// Returns `nil` when the xcframework binary has not been linked — callers
/// should disable Mercury file transfer in that build.
public enum OpenBurnBarIrohBlobFFIBackendFactory {
    public static func make() -> IrohBlobBackend? {
        #if canImport(OpenBurnBarIrohFFI)
        return OpenBurnBarIrohBlobFFIBackend()
        #else
        return nil
        #endif
    }
}
