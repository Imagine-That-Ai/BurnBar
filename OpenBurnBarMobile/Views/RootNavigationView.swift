import SwiftUI
import OpenBurnBarCore

// MARK: - Root Navigation View (iPad)
//
// Aurora-shaped sidebar layout. Five primary destinations match the iPhone
// tabs (Pulse / Burn / Streams / Hermes / You). The sidebar gains a brand
// block, a permanent sync pill, and an inline Hermes shortcut.

struct RootNavigationView: View {
    let authStore: AuthStore
    let syncHealthStore: CloudSyncHealthStore
    let providerSummaryStore: ProviderSummaryStore
    let devicesStore: DevicesStore
    let transferStore: CredentialTransferStore

    @State private var selection: SidebarDestination = .pulse
    @State private var didApplyScreenshotRoute = false
    @State private var router = PulseRouter()
    @State private var hermesService = HermesService()
    @State private var motionStore = MotionStore()
    @State private var insightsDashboardStore = DashboardStore()
    @State private var missionActivityCenter = MobileMissionActivityCenter()
    @State private var showHermesSheet = false

    enum SidebarDestination: Hashable, Identifiable {
        case pulse, burn, insights, streams, hermes, you, settings, devices, providers
        var id: String { String(describing: self) }
        var label: String {
            switch self {
            case .pulse:    return "Pulse"
            case .burn:     return "Burn"
            case .insights: return "Insights"
            case .streams:  return "Streams"
            case .hermes:   return "Hermes"
            case .you:      return "You"
            case .settings: return "Settings"
            case .devices:  return "Devices"
            case .providers: return "Providers"
            }
        }
        var accent: Color {
            switch self {
            case .pulse:    return MobileTheme.ember
            case .burn:     return MobileTheme.amber
            case .insights: return MobileTheme.whimsy
            case .streams:  return MobileTheme.whimsy
            case .hermes:   return MobileTheme.hermesAureate
            case .you:      return MobileTheme.blaze
            case .settings: return MobileTheme.amber
            case .devices:  return MobileTheme.whimsy
            case .providers: return MobileTheme.ember
            }
        }

        var asAuroraDestination: AuroraNavDestination? {
            switch self {
            case .pulse:    return .pulse
            case .burn:     return .burn
            case .insights: return .insights
            case .streams:  return .streams
            case .hermes:   return .hermes
            case .you:      return .you
            default:        return nil
            }
        }

        var fallbackIcon: String {
            switch self {
            case .insights:  return "sparkles.tv.fill"
            case .settings:  return "gearshape.fill"
            case .devices:   return "macbook.and.iphone"
            case .providers: return "externaldrive.connected.to.line.below"
            default:         return "circle.fill"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
            } detail: {
                detail
            }

        }
        .environment(\.motionStore, motionStore)
        .task { missionActivityCenter.start() }
        .onAppear {
            applyScreenshotRouteIfNeeded()
        }
        .onChange(of: router.pendingDestination) { _, destination in
            handleRouter(destination)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)
            List {
                Section {
                    sidebarLogoHeader
                    ForEach([SidebarDestination.pulse, .burn, .insights, .streams, .hermes], id: \.self) { destination in
                        sidebarItem(destination)
                    }
                }
                Section("Account") {
                    ForEach([SidebarDestination.you, .providers, .devices, .settings], id: \.self) { destination in
                        sidebarItem(destination)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
    }

    private var sidebarLogoHeader: some View {
        VStack(spacing: 6) {
            Image("AppLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 40)
            Text("BurnBar")
                .font(.system(size: 13, weight: .medium, design: .default))
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color.clear)
    }

    private func sidebarItem(_ destination: SidebarDestination) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                selection = destination
            }
            HapticBus.tabChange()
        } label: {
            HStack(spacing: 14) {
                if let auroraDest = destination.asAuroraDestination {
                    AuroraNavIcon(
                        destination: auroraDest,
                        size: 28,
                        isSelected: selection == destination,
                        isPressed: false,
                        userPhotoURL: auroraDest == .you
                            ? authStore.currentIdentity?.photoURL
                            : nil,
                        userDisplayName: auroraDest == .you
                            ? (authStore.currentIdentity?.displayName
                               ?? authStore.currentIdentity?.email)
                            : nil
                    )
                    .frame(width: 32, height: 32)
                } else {
                    // Fallback SF Symbol for secondary items
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(destination.accent)
                            .frame(width: 26, height: 26)
                        Image(systemName: destination.fallbackIcon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                Text(destination.label)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(selection == destination ? .semibold : .regular)
                    .foregroundStyle(
                        selection == destination
                            ? destination.accent
                            : MobileTheme.Colors.textPrimary
                    )

                Spacer()

                if selection == destination {
                    Circle()
                        .fill(destination.accent)
                        .frame(width: 7, height: 7)
                        .transition(.scale(scale: 0.1).combined(with: .opacity))
                }
            }
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            Group {
                if selection == destination {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(destination.accent.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(destination.accent.opacity(0.18), lineWidth: 0.5)
                        )
                } else {
                    Color.clear
                }
            }
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
        .animation(.spring(response: 0.30, dampingFraction: 0.78), value: selection)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(syncDotColor)
                    .frame(width: 8, height: 8)
                Text(syncStatusText)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .lineLimit(1)
                if let lastSync = syncHealthStore.lastPublishedAt {
                    Text("· \(lastSync, style: .relative)")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .auroraGlass(.compact, cornerRadius: 12)
            .padding(.horizontal, 12)

            Button {
                showHermesSheet = true
            } label: {
                HStack(spacing: 6) {
                    HermesLiveGlyph(size: 16, isLive: false)
                    Text("Quick ask Hermes")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.aurora(.hermes, fullWidth: true))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showHermesSheet) {
            NavigationStack {
                HermesChatView(service: hermesService, route: .new)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showHermesSheet = false }
                        }
                    }
            }
            .presentationDetents([.large])
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        NavigationStack {
            Group {
                switch selection {
                case .pulse:    PulseView(router: router)
                case .burn:     BurnView()
                case .insights: AgentInsightsTabScreen(dashboardStore: insightsDashboardStore, hermesService: hermesService)
                case .streams:  StreamsView()
                case .hermes:   HermesConversationListView(service: hermesService)
                case .you:      YouView(authStore: authStore, syncStore: syncHealthStore, devicesStore: devicesStore)
                case .settings: SettingsHubView(authStore: authStore)
                case .devices:  iPadDevicesSettingsView()
                case .providers: ProviderConnectionsView(showsDoneButton: false)
                }
            }
            .navigationDestination(for: YouRoute.self) { route in
                switch route {
                case .sync:     CloudSyncDetailsView(syncStore: syncHealthStore)
                case .settings: SettingsHubView(authStore: authStore)
                case .devices:  iPadDevicesSettingsView()
                case .providers: ProviderConnectionsView(showsDoneButton: false)
                }
            }
            .navigationDestination(for: TokenUsage.self) { usage in
                SessionDetailView(usage: usage)
            }
        }
    }

    // MARK: - Router

    private func handleRouter(_ destination: PulseRouter.Destination?) {
        guard let destination else { return }
        switch destination {
        case .burn:     selection = .burn
        case .streams:  selection = .streams
        case .hermes:   selection = .hermes
        case .session:  selection = .streams
        case .project:  selection = .streams
        case .provider: selection = .burn
        }
        router.clear()
    }

    private func applyScreenshotRouteIfNeeded() {
        guard AppStoreScreenshotMode.isEnabled, !didApplyScreenshotRoute else { return }
        didApplyScreenshotRoute = true
        switch AppStoreScreenshotMode.route {
        case "burn", "quota":
            selection = .burn
        case "streams", "activity":
            selection = .streams
        case "hermes", "chat":
            selection = .hermes
        case "you", "account":
            selection = .you
        case "settings":
            selection = .settings
        case "devices":
            selection = .devices
        case "providers", "connections":
            selection = .providers
        default:
            selection = .pulse
        }
    }

    // MARK: - Sync Helpers

    private var syncStatusText: String {
        switch syncHealthStore.health {
        case .healthy: return "Synced"
        case .syncing: return "Syncing…"
        case .offline: return "Offline"
        case .firebaseUnavailable: return "Firebase unavailable"
        case .appCheckBlocked: return "App Check blocked"
        case .permissionDenied: return "Permission denied"
        case .degraded(_): return "Degraded"
        case .unknown: return "Checking…"
        }
    }

    private var syncDotColor: Color {
        switch syncHealthStore.health {
        case .healthy: return MobileTheme.success
        case .syncing: return MobileTheme.amber
        case .offline, .degraded(_): return MobileTheme.warning
        case .firebaseUnavailable, .appCheckBlocked, .permissionDenied: return MobileTheme.error
        case .unknown: return MobileTheme.Colors.textMuted
        }
    }
}

#Preview {
    RootNavigationView(
        authStore: AuthStore(),
        syncHealthStore: CloudSyncHealthStore(),
        providerSummaryStore: ProviderSummaryStore(),
        devicesStore: DevicesStore(),
        transferStore: CredentialTransferStore()
    )
}
