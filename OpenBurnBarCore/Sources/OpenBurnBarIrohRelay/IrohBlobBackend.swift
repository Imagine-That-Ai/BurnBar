import Foundation

/// Backend contract for the iroh-blobs side of the Mercury media rollout
/// (`plans/2026-05-15-mercury-media-master-plan.md` § B.2 +
/// `docs/HERMES_MEDIA_TRANSPORT.md`). Parallel to `IrohEndpointBackend` but
/// drives a separate iroh `Endpoint` pinned to `iroh_blobs::ALPN`. Two
/// endpoints per device — chat keeps its single-ALPN router; blobs get
/// their own — so Phase 1 ships without touching the existing accept-loop.
///
/// Tests can supply a deterministic backend for unit tests; the production
/// implementation is `OpenBurnBarIrohBlobFFIBackend` (xcframework-gated).
public protocol IrohBlobBackend: AnyObject, Sendable {
    /// Spin up the blob endpoint with a 32-byte secret + on-disk store
    /// directory. Returns the iroh node identity. `relayURL` `nil` → n0
    /// public relays; non-nil → pin the relay (Phase 6+).
    func bootstrap(
        secret: Data,
        storeDirectoryPath: String,
        relayURL: String?
    ) async throws -> IrohEndpointIdentity

    /// Hash + ingest a local file into the blob store. Returns the base32
    /// `BlobTicket` text the receiver dials with.
    func publishBlob(localPath: String) async throws -> String

    /// Dial the ticket's source node, download the blob, write it to
    /// `destination`. Resume across reconnects is handled internally.
    func fetchBlob(ticketText: String, destination: String) async throws -> BlobTransferStats

    /// Dial the ticket's source node, download the blob, and fail closed when
    /// the received bytes exceed the manifest-advertised size.
    func fetchBlob(
        ticketText: String,
        destination: String,
        expectedSizeBytes: UInt64
    ) async throws -> BlobTransferStats

    /// Returns the cached identity. Throws if `bootstrap` has not been
    /// called.
    func identity() async throws -> IrohEndpointIdentity

    /// Tear down the router + endpoint + store + runtime. Idempotent.
    func shutdown() async
}

/// Per-transfer statistics returned from `fetchBlob`. Surfaced to telemetry
/// via bucketed enums in `MediaTelemetryBucket` so payload counts never
/// flow through Firebase Analytics in plaintext.
public struct BlobTransferStats: Sendable, Equatable, Hashable {
    public let bytesTotal: UInt64
    public let blake3Hash: String
    public let durationMillis: UInt64
    public let didResume: Bool

    public init(
        bytesTotal: UInt64,
        blake3Hash: String,
        durationMillis: UInt64,
        didResume: Bool
    ) {
        self.bytesTotal = bytesTotal
        self.blake3Hash = blake3Hash
        self.durationMillis = durationMillis
        self.didResume = didResume
    }
}

/// Errors raised by the blob backend boundary. Surfaced to callers as
/// `MediaFileTransferError` after translation in `MediaFileTransferService`.
public enum IrohBlobBackendError: Error, Equatable, Sendable {
    case notInitialized
    case invalidSecretKey
    case invalidTicket(String)
    case publishFailed(String)
    case fetchFailed(String)
    case storeUnavailable(String)
    case runtimeFailed(String)
}

public enum IrohBlobTransferLimits {
    public static let maxExpectedFetchBytes: UInt64 = 2 * 1024 * 1024 * 1024
}

public extension IrohBlobBackend {
    func fetchBlob(
        ticketText: String,
        destination: String,
        expectedSizeBytes: UInt64
    ) async throws -> BlobTransferStats {
        try IrohBlobTransferLimits.validateExpectedFetchSize(expectedSizeBytes)

        let stats = try await fetchBlob(ticketText: ticketText, destination: destination)
        let actualBytes = max(stats.bytesTotal, Self.fileSize(atPath: destination))
        guard actualBytes <= expectedSizeBytes else {
            try? FileManager.default.removeItem(atPath: destination)
            throw IrohBlobBackendError.fetchFailed(
                "blob exceeded expected size: \(actualBytes) bytes > \(expectedSizeBytes) bytes"
            )
        }
        return stats
    }
}

public extension IrohBlobTransferLimits {
    static func validateExpectedFetchSize(_ expectedSizeBytes: UInt64) throws {
        guard expectedSizeBytes <= maxExpectedFetchBytes else {
            throw IrohBlobBackendError.fetchFailed(
                "expected blob size \(expectedSizeBytes) bytes exceeds maximum \(maxExpectedFetchBytes) bytes"
            )
        }
    }
}

private extension IrohBlobBackend {
    static func fileSize(atPath path: String) -> UInt64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.uint64Value
    }
}
