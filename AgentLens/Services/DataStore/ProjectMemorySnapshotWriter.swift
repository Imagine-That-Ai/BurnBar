import Foundation
import OpenBurnBarKernel

// MARK: - Project memory snapshot writer (Wave 2.1c single-writer cutover)
//
// The daemon owns `project_memory_snapshots` (ADR-005). The app routes
// snapshot writes through this seam instead of `INSERT`ing into the table
// directly. Reads stay on the app's local connection until the read cutover.

/// The three snapshot writes the app performs. The request structs are the
/// shared `BurnBarProjectMemorySnapshotContracts` types, so the test doubles
/// and the shipping writer speak the same shape the daemon validates.
protocol ProjectMemorySnapshotWriter: Sendable {
    func upsertSnapshot(_ request: BurnBarProjectMemorySnapshotUpsertRequest) async throws
    func deleteSnapshot(projectSlug: String) async throws
    func deleteAllSnapshots() async throws
}

/// Shipping writer: one daemon RPC per call over the control socket, off the
/// calling executor because the socket round trip is a blocking read (the
/// house `daemonRPC` shape). Fails closed when the daemon is unreachable —
/// there is deliberately no local-write fallback (single writer).
struct DaemonProjectMemorySnapshotWriter: ProjectMemorySnapshotWriter {
    func upsertSnapshot(_ request: BurnBarProjectMemorySnapshotUpsertRequest) async throws {
        try await Task.detached(priority: .userInitiated) {
            try OpenBurnBarDaemonSocketClient.projectMemorySnapshotUpsert(
                request,
                at: OpenBurnBarDaemonRuntimePaths.live().socketURL
            )
        }.value
    }

    func deleteSnapshot(projectSlug: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try OpenBurnBarDaemonSocketClient.projectMemorySnapshotDelete(
                BurnBarProjectMemorySnapshotDeleteRequest(projectSlug: projectSlug),
                at: OpenBurnBarDaemonRuntimePaths.live().socketURL
            )
        }.value
    }

    func deleteAllSnapshots() async throws {
        try await Task.detached(priority: .userInitiated) {
            try OpenBurnBarDaemonSocketClient.projectMemorySnapshotDeleteAll(
                at: OpenBurnBarDaemonRuntimePaths.live().socketURL
            )
        }.value
    }
}
