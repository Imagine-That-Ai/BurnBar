import Foundation
import OpenBurnBarKernel

// MARK: - Vector index snapshot writer (Wave 2.1c-ii single-writer cutover)
//
// The daemon owns `vector_index_snapshots` (ADR-005). The app routes its HNSW
// snapshot-lifecycle writes through this seam instead of `INSERT`ing into the
// table directly. Reads stay on the app's local connection until the read
// cutover.

/// The single vector-snapshot write the app performs. The request struct is
/// the shared `BurnBarVectorIndexSnapshotContracts` type, so the test doubles
/// and the shipping writer speak the same shape the daemon validates.
protocol VectorIndexSnapshotWriter: Sendable {
    func upsertSnapshot(_ request: BurnBarVectorIndexSnapshotUpsertRequest) async throws
}

/// Shipping writer: one daemon RPC per call over the control socket, off the
/// calling executor because the socket round trip is a blocking read (the
/// house `daemonRPC` shape). Fails closed when the daemon is unreachable —
/// there is deliberately no local-write fallback (single writer).
struct DaemonVectorIndexSnapshotWriter: VectorIndexSnapshotWriter {
    func upsertSnapshot(_ request: BurnBarVectorIndexSnapshotUpsertRequest) async throws {
        try await Task.detached(priority: .userInitiated) {
            try OpenBurnBarDaemonSocketClient.vectorIndexSnapshotUpsert(
                request,
                at: OpenBurnBarDaemonRuntimePaths.live().socketURL
            )
        }.value
    }
}
