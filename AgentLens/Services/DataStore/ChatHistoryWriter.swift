import Foundation
import OpenBurnBarKernel

// MARK: - Chat history writer (Wave 2.1 single-writer cutover)
//
// The daemon owns `chat_threads` and `chat_messages` (ADR-005). The app routes
// chat writes through this seam instead of `INSERT`ing into those tables
// directly. Reads stay on the app's local connection until the read cutover.

/// The two chat writes the app performs. The request structs are the shared
/// `BurnBarChatThreadContracts` types, so the test double and the shipping
/// writer speak the same shape the daemon validates.
protocol ChatHistoryWriter: Sendable {
    func appendMessage(_ request: BurnBarChatMessageAppendRequest) async throws
    func createThread(_ request: BurnBarChatThreadCreateRequest) async throws
}

/// Shipping writer: one daemon RPC per call over the control socket, off the
/// calling executor because the socket round trip is a blocking read (the
/// house `daemonRPC` shape). Fails closed when the daemon is unreachable —
/// there is deliberately no local-write fallback (single writer).
struct DaemonChatHistoryWriter: ChatHistoryWriter {
    func appendMessage(_ request: BurnBarChatMessageAppendRequest) async throws {
        try await Task.detached(priority: .userInitiated) {
            try OpenBurnBarDaemonSocketClient.chatMessageAppend(
                request,
                at: OpenBurnBarDaemonRuntimePaths.live().socketURL
            )
        }.value
    }

    func createThread(_ request: BurnBarChatThreadCreateRequest) async throws {
        try await Task.detached(priority: .userInitiated) {
            try OpenBurnBarDaemonSocketClient.chatThreadCreate(
                request,
                at: OpenBurnBarDaemonRuntimePaths.live().socketURL
            )
        }.value
    }
}
