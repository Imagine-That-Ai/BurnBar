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
    @State private var router = PulseRouter()
    @State private var hermesService = HermesService()
    @State private var motionStore = MotionStore()
    @State private var showHermesSheet = false

    enum SidebarDestination: Hashable, Identifiable {
        case pulse, burn, streams, hermes, you, settings, devices, providers
        var id: String { String(describing: self) }
        var label: String {
            switch self {
            case .pulse:    return "Pulse"
            case .burn:     return "Burn"
            case .streams:  return "Streams"
            case .hermes:   return "Hermes"
            case .you:      return "You"
            case .settings: return "Settings"
            case .devices:  return "Devices"
            case .providers: return "Providers"
            }
        }
        var icon: String {
            switch self {
            case .pulse:    return "waveform.path.ecg.rectangle.fill"
            case .burn:     return "flame.fill"
            case .streams:  return "rectangle.stack.fill"
            case .hermes:   return "wand.and.stars"
            case .you:      return "person.crop.circle.fill"
            case .settings: return "gearshape.fill"
            case .devices:  return "macbook.and.iphone"
            case .providers: return "externaldrive.connected.to.line.below"
            }
        }
        var accent: Color {
            switch self {
            case .pulse:    return MobileTheme.ember
            case .burn:     return MobileTheme.amber
            case .streams:  return MobileTheme.whimsy
            case .hermes:   return MobileTheme.hermesAureate
            case .you:      return MobileTheme.blaze
            case .settings: return MobileTheme.amber
            case .devices:  return MobileTheme.whimsy
            case .providers: return MobileTheme.ember
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            detail
        }
        .environment(\.motionStore, motionStore)
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
                    ForEach([SidebarDestination.pulse, .burn, .streams, .hermes], id: \.self) { destination in
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
            .navigationTitle("OpenBurnBar")
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
    }

    private func sidebarItem(_ destination: SidebarDestination) -> some View {
        Button {
            selection = destination
        } label: {
            HStack {
                Label {
                    Text(destination.label)
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                } icon: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(destination.accent)
                            .frame(width: 26, height: 26)
                        Image(systemName: destination.icon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                Spacer()
                if selection == destination {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(destination.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            selection == destination
                ? destination.accent.opacity(0.14)
                : Color.clear
        )
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
                    Text("☿")
                        .font(.system(size: 14, weight: .bold))
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
                HermesTabView(service: hermesService)
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
            switch selection {
            case .pulse:    PulseView(router: router)
            case .burn:     BurnView()
            case .streams:  StreamsView()
            case .hermes:   HermesTabView(service: hermesService)
            case .you:      YouView(authStore: authStore, syncStore: syncHealthStore, devicesStore: devicesStore)
            case .settings: SettingsHubView()
            case .devices:  iPadDevicesSettingsView()
            case .providers: ProviderConnectionsView(showsDoneButton: false)
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
