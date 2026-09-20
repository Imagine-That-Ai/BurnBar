import SwiftUI

/// Stage Manager extra window for Watch. Same singleton as the inspector.
/// Closing this scene does not halt the Mac session.
struct IPadAgentWatchWindowRoot: View {
    @Environment(\.appServices) private var appServices
    @Environment(\.mobileAuthStore) private var authStore
    @ObservedObject private var singleton = AgentWatchOverlaySingleton.shared
    @ObservedObject private var hostReachability = HostReachabilityClient.shared

    var body: some View {
        IPadWatchInspectorColumn(
            authUID: authStore?.currentIdentity?.uid,
            hermesService: appServices.hermes,
            singleton: singleton,
            hostReachability: hostReachability
        )
        .accessibilityIdentifier("ipad.watch.window")
        .background {
            IPadDeskSceneProbe(role: .watch)
        }
        .handlesExternalEvents(
            preferring: [IPadAwayDeskNavigation.watchWindowID],
            allowing: [IPadAwayDeskNavigation.watchWindowID]
        )
    }
}
