import OpenBurnBarCore
import Foundation

struct BurnBarTelegramInboundMessage: Sendable {
    let updateID: Int
    let chatID: String
    let text: String
}

struct BurnBarMissionControlTransport: Sendable {
    let deliverLocalNotification: @Sendable (_ title: String, _ body: String) async throws -> Void
    let sendTelegramMessage: @Sendable (_ botToken: String, _ chatID: String, _ text: String) async throws -> Void
    let fetchTelegramUpdates: @Sendable (_ botToken: String, _ offset: Int?) async throws -> [BurnBarTelegramInboundMessage]
    let applyCalendarEntry: @Sendable (
        _ action: BurnBarCalendarAction,
        _ entry: BurnBarCalendarEntrySnapshot,
        _ preferredCalendarName: String?
    ) async throws -> BurnBarCalendarEntrySnapshot

    static func live() -> BurnBarMissionControlTransport {
        BurnBarMissionControlTransport(
            deliverLocalNotification: { title, body in
                try await BurnBarLocalNotificationBridge.shared.deliver(title: title, body: body)
            },
            sendTelegramMessage: { botToken, chatID, text in
                try await BurnBarTelegramBotBridge.shared.send(botToken: botToken, chatID: chatID, text: text)
            },
            fetchTelegramUpdates: { botToken, offset in
                try await BurnBarTelegramBotBridge.shared.fetchUpdates(botToken: botToken, offset: offset)
            },
            applyCalendarEntry: { action, entry, preferredCalendarName in
                try await BurnBarEventKitBridge.shared.apply(
                    action: action,
                    entry: entry,
                    preferredCalendarName: preferredCalendarName
                )
            }
        )
    }
}

public typealias BurnBarMissionControlReviewRunLauncher = @Sendable (
    _ prompt: String,
    _ modelID: String,
    _ metadata: [String: BurnBarJSONValue]
) async throws -> BurnBarRunCreateResponse

public typealias BurnBarMissionControlRunSnapshotLookup = @Sendable (
    _ runID: BurnBarRunID
) async -> BurnBarRunStateSnapshot?

/// Result of an execution readiness check.
/// If the check passes, readiness is nil.
/// If the check fails, readiness contains the reason code and a human-readable detail.
public struct BurnBarExecutionReadiness: Sendable {
    public let code: BurnBarExecutionReadinessCode
    public let detail: String

    public init(code: BurnBarExecutionReadinessCode, detail: String) {
        self.code = code
        self.detail = detail
    }
}

/// Typealias for the execution readiness gate function.
/// Takes mission and packet context and returns nil if ready, or a BurnBarExecutionReadiness describing the failure.
public typealias BurnBarExecutionReadinessGate = @Sendable (
    _ mission: BurnBarMissionSnapshot,
    _ packet: BurnBarMissionPacketSnapshot
) async -> BurnBarExecutionReadiness?
