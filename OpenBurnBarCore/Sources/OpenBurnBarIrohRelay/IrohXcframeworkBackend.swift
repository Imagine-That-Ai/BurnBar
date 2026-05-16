import Foundation

/// Backend contract that the xcframework-backed transport calls into. The
/// real UniFFI-generated module (`OpenBurnBarIrohFFI`) provides the
/// production implementation, but tests can supply a deterministic backend
/// without booting the iroh runtime.
///
/// The contract mirrors the Rust crate's eight-function surface
/// (`crates/openburnbar-iroh/src/lib.rs`). Keeping it as a Swift protocol
/// lets us:
///
/// * Compile and unit-test the Swift wrapper against a fake backend before
///   the xcframework binary is published.
/// * Run the production code path under fault-injection in `XCTest` (e.g.,
///   confirm connect timeouts surface as `IrohRelayTransportError.timedOut`).
/// * Swap in alternative transports for experiments without rewriting
///   `HermesRelayHostService` / `HermesService`.
public protocol IrohEndpointBackend: AnyObject, Sendable {
    /// Spawn the iroh endpoint with a 32-byte secret. Returns the identity
    /// (raw public key + base32 NodeId surface). Phase 6+ callers can pin a
    /// hosted relay by passing a non-empty `relayURL`; pass `nil` to use
    /// n0's public relay mesh (phases 1-5 default).
    func bootstrap(secret: Data, relayURL: String?) async throws -> IrohEndpointIdentity

    /// Returns the cached identity. Throws if `bootstrap` has not been
    /// called.
    func identity() async throws -> IrohEndpointIdentity

    /// Dial a remote NodeAddr and return a stream handle.
    func connect(to target: IrohDialTarget, timeout: TimeInterval) async throws -> IrohBackendStream

    /// Wait for one inbound bi-stream after a successful ALPN handshake.
    func acceptOne(timeout: TimeInterval) async throws -> IrohBackendStream

    /// Cleanly close the endpoint. After shutdown the backend is unusable
    /// and a fresh instance must be bootstrapped.
    func shutdown() async
}

public extension IrohEndpointBackend {
    func connect(to nodeId: String, timeout: TimeInterval) async throws -> IrohBackendStream {
        try await connect(to: IrohDialTarget(nodeId: nodeId), timeout: timeout)
    }
}

/// Backend stream handle. Length-prefixed JSON envelopes are pushed through
/// `send` and `recv` exactly as the Rust crate would write to QUIC.
public protocol IrohBackendStream: AnyObject, Sendable {
    func sendFrame(_ envelope: Data) async throws
    func recvFrame() async throws -> Data?
    func close() async
}

/// 32-byte secret material we hand the backend on `bootstrap`. The Swift
/// caller is responsible for persisting this in the Keychain alongside the
/// existing `HermesRelayPrivateKey` material.
public struct IrohSecretKeyMaterial: Sendable, Equatable, Hashable {
    public let raw: Data

    public init(raw: Data) {
        precondition(raw.count == 32, "iroh secret key must be 32 bytes; got \(raw.count)")
        self.raw = raw
    }

    /// Generate a new random secret using the system CSPRNG.
    public static func generate() -> IrohSecretKeyMaterial {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 {
            bytes[i] = UInt8(rng.next() & 0xff)
        }
        return IrohSecretKeyMaterial(raw: Data(bytes))
    }
}

/// Errors specific to the xcframework bridge. Cast through to the public
/// `IrohRelayTransportError` shape at the transport boundary.
public enum IrohBackendError: Error, Equatable, Sendable {
    case notInitialized
    case invalidSecretKey
    case invalidNodeId
    case connectFailed(String)
    case streamFailed(String)
    case acceptFailed(String)
    case shutdownFailed(String)
    case runtimeFailed(String)
}
