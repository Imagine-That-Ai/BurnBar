import Foundation
import OpenBurnBarKernel

/// Async, injectable app-side boundary for the daemon-owned Safari learning
/// profile. The native app never reads or edits the learning store directly;
/// every state transition remains capability-classified, version-bound, and
/// audited by the daemon.
protocol SafariLearningTimelineClient: Sendable {
    func timeline() async throws -> BurnBarSafariLearningTimelineResponse
    func optIn() async throws -> BurnBarSafariLearningStateResponse
    func update(
        _ request: BurnBarSafariLearningUpdateRequest
    ) async throws -> BurnBarSafariLearningProposalResponse
    func approve(
        _ request: BurnBarSafariLearningMutationRequest
    ) async throws -> BurnBarSafariLearningProposalResponse
    func reject(
        _ request: BurnBarSafariLearningMutationRequest
    ) async throws -> BurnBarSafariLearningProposalResponse
    func forget(
        _ request: BurnBarSafariLearningForgetRequest
    ) async throws -> BurnBarSafariLearningStateResponse
    func rollback(
        _ request: BurnBarSafariLearningRollbackRequest
    ) async throws -> BurnBarSafariLearningProposalResponse
    func optOut(
        deleteLearnedProfile: Bool
    ) async throws -> BurnBarSafariLearningStateResponse
}

/// Production client for the local newline-framed Unix socket.
///
/// `OpenBurnBarDaemonSocketClient` is intentionally synchronous because it is
/// also used by process and test harnesses. This adapter keeps every socket
/// connect/read/write off the main actor so opening or refreshing the learning
/// gallery cannot stall typing, scrolling, VoiceOver, or window interaction.
struct DaemonSafariLearningTimelineClient: SafariLearningTimelineClient {
    let socketURL: URL

    func timeline() async throws -> BurnBarSafariLearningTimelineResponse {
        try await request {
            try OpenBurnBarDaemonSocketClient.safariLearningTimeline(at: $0)
        }
    }

    func optIn() async throws -> BurnBarSafariLearningStateResponse {
        try await request {
            try OpenBurnBarDaemonSocketClient.optInToSafariLearning(at: $0)
        }
    }

    func update(
        _ request: BurnBarSafariLearningUpdateRequest
    ) async throws -> BurnBarSafariLearningProposalResponse {
        try await perform(request) { request, socketURL in
            try OpenBurnBarDaemonSocketClient.updateSafariLearning(
                request,
                at: socketURL
            )
        }
    }

    func approve(
        _ request: BurnBarSafariLearningMutationRequest
    ) async throws -> BurnBarSafariLearningProposalResponse {
        try await perform(request) { request, socketURL in
            try OpenBurnBarDaemonSocketClient.approveSafariLearning(
                request,
                at: socketURL
            )
        }
    }

    func reject(
        _ request: BurnBarSafariLearningMutationRequest
    ) async throws -> BurnBarSafariLearningProposalResponse {
        try await perform(request) { request, socketURL in
            try OpenBurnBarDaemonSocketClient.rejectSafariLearning(
                request,
                at: socketURL
            )
        }
    }

    func forget(
        _ request: BurnBarSafariLearningForgetRequest
    ) async throws -> BurnBarSafariLearningStateResponse {
        try await perform(request) { request, socketURL in
            try OpenBurnBarDaemonSocketClient.forgetSafariLearning(
                request,
                at: socketURL
            )
        }
    }

    func rollback(
        _ request: BurnBarSafariLearningRollbackRequest
    ) async throws -> BurnBarSafariLearningProposalResponse {
        try await perform(request) { request, socketURL in
            try OpenBurnBarDaemonSocketClient.rollbackSafariLearning(
                request,
                at: socketURL
            )
        }
    }

    func optOut(
        deleteLearnedProfile: Bool
    ) async throws -> BurnBarSafariLearningStateResponse {
        try await request {
            try OpenBurnBarDaemonSocketClient.optOutOfSafariLearning(
                BurnBarSafariLearningOptOutRequest(
                    deleteLearnedProfile: deleteLearnedProfile
                ),
                at: $0
            )
        }
    }

    private func request<Response: Sendable>(
        _ operation: @escaping @Sendable (URL) throws -> Response
    ) async throws -> Response {
        let socketURL = socketURL
        return try await Task.detached(priority: .userInitiated) {
            try operation(socketURL)
        }.value
    }

    private func perform<Request: Sendable, Response: Sendable>(
        _ value: Request,
        operation: @escaping @Sendable (Request, URL) throws -> Response
    ) async throws -> Response {
        let socketURL = socketURL
        return try await Task.detached(priority: .userInitiated) {
            try operation(value, socketURL)
        }.value
    }
}
