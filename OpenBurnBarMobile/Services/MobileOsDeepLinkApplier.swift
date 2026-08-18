import Foundation
import OpenBurnBarAnalytics
import OpenBurnBarKernel

/// Applies an already-routed BurnBar destination in-process.
/// Never opens an arbitrary payload URL.
@MainActor
enum MobileOsDeepLinkApplier {
    static func apply(_ routed: MobileOsRouteDecision) {
        let threadID = routed.threadId
        switch routed.destination {
        case .pulse:
            MobileAnalytics.shared.track(.widgetTapped, ["target": "dashboard"])
            NotificationCenter.default.post(name: .init("NavigateToDashboard"), object: nil)
        case .burn:
            NotificationCenter.default.post(name: .init("ShowBurnTab"), object: nil)
        case .streams:
            NotificationCenter.default.post(name: .init("ShowStreamsTab"), object: nil)
        case .settings:
            NotificationCenter.default.post(name: .init("ShowSettings"), object: nil)
        case .computerUse:
            NotificationCenter.default.post(name: .init("ShowAgentWatch"), object: nil)
        case .hermes:
            // Order matters: stash before either surface is raised, and raise the
            // dedicated chat surface before the assistants tab.
            AssistantPendingThread.shared.stash(assistant: .hermes, threadID: threadID)
            NotificationCenter.default.post(name: .init("ShowHermesChat"), object: nil)
            postAssistantsTab(runtime: .hermes, threadID: threadID)
        case .pi:
            AssistantPendingThread.shared.stash(assistant: .pi, threadID: threadID)
            postAssistantsTab(runtime: .pi, threadID: threadID)
        case .assistants:
            let runtime = AssistantRuntimeID(rawValue: routed.runtime ?? "") ?? .hermes
            AssistantPendingThread.shared.stash(assistant: runtime, threadID: threadID)
            postAssistantsTab(runtime: runtime, threadID: threadID)
        case .insights:
            NotificationCenter.default.post(
                name: .init("ShowInsightsTab"),
                object: nil,
                userInfo: ["slug": routed.slug ?? ""]
            )
        case .inbox:
            AIInboxDeepLink.open(itemID: routed.itemId)
        case .mercuryCall:
            var userInfo: [AnyHashable: Any] = [:]
            if let connection = routed.connectionId { userInfo["connectionId"] = connection }
            NotificationCenter.default.post(name: .init("ShowMercuryCall"), object: nil, userInfo: userInfo)
        case .mission:
            var userInfo: [AnyHashable: Any] = [:]
            if let mission = routed.missionId { userInfo["missionId"] = mission }
            NotificationCenter.default.post(name: .init("ShowMissionConsole"), object: nil, userInfo: userInfo)
        case .unknown:
            break
        }
    }

    private static func postAssistantsTab(runtime: AssistantRuntimeID, threadID: String?) {
        var userInfo: [AnyHashable: Any] = ["runtime": runtime.rawValue]
        if let threadID { userInfo["threadId"] = threadID }
        NotificationCenter.default.post(name: .init("ShowAssistantsTab"), object: nil, userInfo: userInfo)
    }

    static func applyIfNavigable(
        payload: [String: String],
        activeUid: String?,
        lastConsumedEventId: String?,
        permissionGranted: Bool = true
    ) -> String? {
        let envelope = MobileOsIntegrationPolicy.envelope(from: payload)
        let decision = MobileOsIntegrationPolicy.navigation(
            envelope: envelope,
            activeUid: activeUid,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            lastConsumedEventId: lastConsumedEventId,
            permissionGranted: permissionGranted
        )
        guard decision == .navigate else { return nil }
        let routed = MobileOsIntegrationPolicy.route(envelope: envelope)
        if let link = routed.deepLink, let url = URL(string: link) {
            apply(MobileOsIntegrationPolicy.route(url: url))
        } else {
            apply(routed)
        }
        return envelope.eventId.isEmpty ? nil : envelope.eventId
    }
}
