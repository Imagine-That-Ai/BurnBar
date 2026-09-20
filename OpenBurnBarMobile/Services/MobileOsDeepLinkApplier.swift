import Foundation
import OpenBurnBarAnalytics
import OpenBurnBarKernel

/// Process-local stash for mission / Mercury-call routes that fire before the
/// signed-in root has mounted. Same shape as `AssistantPendingThread` and
/// Android `OsPendingNavigation`: stash first, then post. The root claims the
/// leftover on appear if `NotificationCenter` had no observer.
enum MobilePendingOsRoute: Equatable {
    case mercuryCall(connectionId: String?)
    case mission(missionId: String?)
}

@MainActor
final class MobilePendingOsRouteStore {
    static let shared = MobilePendingOsRouteStore()

    private var pending: MobilePendingOsRoute?
    /// See `AIInboxDeepLink` isolated stash: XCTest shares the live host, so
    /// `apply` parks here while isolation is active and production `consume()`
    /// keeps reading `pending` only.
    private var isolatedPending: MobilePendingOsRoute?
    private var isolationDepth = 0

    private init() {}

    func stash(_ route: MobilePendingOsRoute) {
        if isolationDepth > 0 {
            isolatedPending = route
        } else {
            pending = route
        }
    }

    /// Read and clear so one tap opens one surface once.
    func consume() -> MobilePendingOsRoute? {
        let value = pending
        pending = nil
        return value
    }

    func clear() {
        pending = nil
        isolatedPending = nil
    }

    func withIsolatedPendingRouteForTests<T>(_ body: () throws -> T) rethrows -> T {
        isolationDepth += 1
        defer {
            isolationDepth -= 1
            isolatedPending = nil
        }
        return try body()
    }

    func consumeIsolatedPendingRouteForTests() -> MobilePendingOsRoute? {
        let value = isolatedPending
        isolatedPending = nil
        return value
    }
}

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
            InsightsDeepLink.open(slug: routed.slug)
        case .inbox:
            AIInboxDeepLink.open(itemID: routed.itemId)
        case .mercuryCall:
            MobilePendingOsRouteStore.shared.stash(.mercuryCall(connectionId: routed.connectionId))
            var userInfo: [AnyHashable: Any] = [:]
            if let connection = routed.connectionId { userInfo["connectionId"] = connection }
            NotificationCenter.default.post(name: .init("ShowMercuryCall"), object: nil, userInfo: userInfo)
        case .mission:
            MobilePendingOsRouteStore.shared.stash(.mission(missionId: routed.missionId))
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

/// Insights is no longer a compact-tray tab. Deep links and Settings must
/// still select a reachable destination (Insights itself), so the request is
/// stashed the same way as `AIInboxDeepLink`: post + claim.
@MainActor
enum InsightsDeepLink {
    static let notificationName = Notification.Name("ShowInsightsTab")
    static let slugKey = "slug"
    static let sectionKey = "section"

    private static var pending: (slug: String?, section: String?)?

    static var hasPending: Bool { pending != nil }

    static func open(slug: String? = nil, section: String? = nil) {
        pending = (slug, section)
        var userInfo: [AnyHashable: Any] = [:]
        if let slug { userInfo[slugKey] = slug }
        if let section { userInfo[sectionKey] = section }
        NotificationCenter.default.post(name: notificationName, object: nil, userInfo: userInfo)
    }

    static func consume() -> (slug: String?, section: String?)? {
        let value = pending
        pending = nil
        return value
    }

    static func reset() {
        pending = nil
    }
}
