#if canImport(UIKit)
import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Phase 14 — Phone-side composer that converts a SwiftUI grant-sheet
/// tap into a signed `controlSystemPermissionRequest` frame on the
/// already-open Computer Use control stream. The actual signing /
/// stream-write is delegated to a `PhoneControlSender` instance so the
/// sender keeps responsibility for keys, counters, and frame sinks.
@MainActor
public final class SystemPermissionGrantSender {
    public typealias SenderFactory = @MainActor () -> PhoneControlSender?

    private let senderFactory: SenderFactory

    public init(senderFactory: @escaping SenderFactory) {
        self.senderFactory = senderFactory
    }

    public enum SendError: Error, Sendable, Equatable {
        case noActiveSender
        case underlying(String)
    }

    @discardableResult
    public func sendGrant(
        item: SystemPermissionItem,
        action: HermesRealtimeRelaySystemPermissionAction? = nil
    ) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        guard let sender = senderFactory() else { throw SendError.noActiveSender }
        let placeholderAuthority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        let request = HermesRealtimeRelaySystemPermissionRequest(
            requestId: UUID().uuidString,
            clientIntentId: UUID().uuidString,
            kind: item.kind.wire,
            bundleId: item.bundleId,
            originatingToolCallId: item.originatingToolCallId,
            originatingToolName: item.originatingToolName,
            action: action ?? item.kind.defaultAction,
            requestedAt: Date(),
            authority: placeholderAuthority
        )
        do {
            return try await sender.send(systemPermissionRequest: request)
        } catch {
            throw SendError.underlying(error.localizedDescription)
        }
    }

    @discardableResult
    public func sendRetryFailedTool(item: SystemPermissionItem) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        try await sendGrant(item: item, action: .retryFailedTool)
    }
}
#endif
