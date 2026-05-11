import SwiftUI
import OpenBurnBarCore

struct iPadDevicesSettingsView: View {
    @State private var store = DevicesStore()
    @State private var smartHub = SmartHubStore()
    @State private var newName = ""
    @State private var showRenameSheet = false
    @State private var showRevokeConfirmation = false
    @State private var showCleanupConfirmation = false
    @State private var deviceToRevoke: DeviceRecord?
    @State private var isReprobingHermes = false
    @State private var showSmartHubWizard = false

    /// External `HermesService` so the relay status card reflects the
    /// same connection state the rest of the app uses. Optional — when
    /// nil (e.g. iPad split-view default constructor) we still render
    /// the rest of the screen.
    let hermesService: HermesService?

    init(hermesService: HermesService? = nil) {
        self.hermesService = hermesService
    }

    var body: some View {
        Form {
            if let error = store.lastError {
                Section {
                    Label(error.label, systemImage: "exclamationmark.triangle.fill")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.error)
                }
            }
            if hermesService != nil {
                hermesRelaySection
            }
            smartHubSection
            thisDeviceSection
            otherDevicesSection
            if !store.staleDuplicates.isEmpty {
                duplicatesSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Devices & Sync")
        .refreshable { await refreshAll() }
        .task { await refreshAll() }
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        .alert("Revoke Device?", isPresented: $showRevokeConfirmation) {
            Button("Cancel", role: .cancel) { deviceToRevoke = nil }
            Button("Revoke", role: .destructive) {
                if let device = deviceToRevoke {
                    Task { await store.revoke(device) }
                }
            }
        } message: {
            Text("This device will lose access to your OpenBurnBar data.")
        }
        .alert("Remove duplicate copies?", isPresented: $showCleanupConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove \(store.staleDuplicates.count)", role: .destructive) {
                Task { await store.revokeStaleDuplicates() }
            }
        } message: {
            Text("Older Firestore copies of devices that share the same name will be revoked. Active devices stay connected.")
        }
    }

    // MARK: - Refresh

    private func refreshAll() async {
        async let devices: Void = store.load()
        async let hermes: Void = refreshHermes()
        async let hub: Void = smartHub.load()
        _ = await (devices, hermes, hub)
    }

    private func refreshHermes() async {
        guard let hermesService else { return }
        isReprobingHermes = true
        defer { isReprobingHermes = false }
        await hermesService.refreshConnections()
        await hermesService.refreshRuntime()
    }

    // MARK: - This Device

    private var thisDeviceSection: some View {
        Section("This Device") {
            if let current = store.currentDevice {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(current.displayName)
                            .font(MobileTheme.Typography.body)
                        Text(current.id.prefix(8))
                            .font(MobileTheme.Typography.monoSmall)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    Spacer()
                    trustBadge(for: current.trustState)
                }

                if store.bootstrapEligible {
                    Button("Approve This Device") {
                        Task { await store.bootstrapApproveSelf() }
                    }
                    .foregroundStyle(MobileTheme.Colors.accent)
                }

                Button("Rename") {
                    newName = current.displayName
                    showRenameSheet = true
                }
            } else {
                Text("Loading device info…")
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
    }

    // MARK: - Other Devices

    private var otherDevicesSection: some View {
        Section("Other Devices") {
            if store.otherDevices.isEmpty {
                Text("No other devices connected.")
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            } else {
                ForEach(store.otherDevices, id: \.id) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.displayName)
                                .font(MobileTheme.Typography.body)
                            Text(device.id.prefix(8))
                                .font(MobileTheme.Typography.monoSmall)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                        }
                        Spacer()
                        trustBadge(for: device.trustState)
                        Button {
                            deviceToRevoke = device
                            showRevokeConfirmation = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(MobileTheme.Colors.error)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Rename Sheet

    private var renameSheet: some View {
        NavigationStack {
            Form {
                TextField("Device Name", text: $newName)
                    .font(MobileTheme.Typography.body)
            }
            .navigationTitle("Rename Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showRenameSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await store.renameSelf(newName)
                            showRenameSheet = false
                        }
                    }
                    .disabled(newName.isEmpty)
                }
            }
        }
    }

    // MARK: - Trust Badge

    private func trustBadge(for state: DeviceTrustState) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(trustColor(for: state))
                .frame(width: 8, height: 8)
            Text(state.rawValue.capitalized)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(trustColor(for: state))
        }
    }

    private func trustColor(for state: DeviceTrustState) -> Color {
        switch state {
        case .trusted: return MobileTheme.Colors.success
        case .pending: return MobileTheme.Colors.warning
        case .current: return MobileTheme.Colors.success
        case .revoked: return MobileTheme.Colors.error
        }
    }

    // MARK: - Hermes Relay

    @ViewBuilder
    private var hermesRelaySection: some View {
        Section {
            if let relay = bestRelayConnection {
                relayCard(for: relay)
            } else {
                relayMissingCard
            }
            Button {
                Task { await refreshHermes() }
            } label: {
                HStack {
                    if isReprobingHermes {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(isReprobingHermes ? "Re-checking…" : "Re-check now")
                }
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.hermesAureate)
            }
            .disabled(isReprobingHermes)
        } header: {
            Text("Hermes Relay")
        } footer: {
            // When the relay is offline, give the user the actionable
            // restart path. We don't ship a remote restart switch yet —
            // the Mac is the only safe place to bounce the relay.
            if let relay = bestRelayConnection, relay.status == .offline {
                Text("The relay last reported offline. Open OpenBurnBar on your Mac and toggle Settings → Hermes → Remote Relay off and on to restart it.")
            } else if bestRelayConnection == nil {
                Text("No remote relay is published. On your Mac, open Settings → Hermes and turn on Remote Relay.")
            }
        }
    }

    private var bestRelayConnection: HermesConnectionRecord? {
        guard let hermesService else { return nil }
        return hermesService.relayConnections.first
    }

    private func relayCard(for relay: HermesConnectionRecord) -> some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
            ZStack {
                Circle().fill(relayStatusColor(relay.status).opacity(0.18))
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(relayStatusColor(relay.status))
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(relay.displayName)
                    .font(MobileTheme.Typography.body)
                if let model = relay.advertisedModel {
                    Text(model)
                        .font(MobileTheme.Typography.monoSmall)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Text(relayLastSeenLabel(relay.lastSeenAt))
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }

            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(relayStatusColor(relay.status))
                    .frame(width: 8, height: 8)
                Text(relayStatusLabel(relay.status))
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(relayStatusColor(relay.status))
            }
        }
    }

    private var relayMissingCard: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(MobileTheme.Colors.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text("No relay published")
                    .font(MobileTheme.Typography.body)
                Text("Hermes will fall back to local-only mode")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
    }

    private func relayStatusColor(_ status: HermesConnectionStatus) -> Color {
        switch status {
        case .online:        return MobileTheme.Colors.success
        case .degraded:      return MobileTheme.Colors.warning
        case .offline,
             .pending:       return MobileTheme.Colors.warning
        case .unauthorized,
             .revoked:       return MobileTheme.Colors.error
        }
    }

    private func relayStatusLabel(_ status: HermesConnectionStatus) -> String {
        switch status {
        case .online:        return "Online"
        case .offline:       return "Offline"
        case .pending:       return "Pending"
        case .degraded:      return "Degraded"
        case .unauthorized:  return "Unauthorized"
        case .revoked:       return "Revoked"
        }
    }

    private func relayLastSeenLabel(_ date: Date?) -> String {
        guard let date else { return "Never seen" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Last seen \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    // MARK: - Duplicate Cleanup

    private var duplicatesSection: some View {
        Section {
            ForEach(store.staleDuplicates, id: \.id) { device in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.displayName)
                            .font(MobileTheme.Typography.body)
                        Text(device.id.prefix(8))
                            .font(MobileTheme.Typography.monoSmall)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        if let seen = device.lastSeen {
                            Text("Last seen \(seen.formatted(.relative(presentation: .numeric)))")
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                        }
                    }
                    Spacer()
                    trustBadge(for: device.trustState)
                }
            }
            Button(role: .destructive) {
                showCleanupConfirmation = true
            } label: {
                Label("Clean up \(store.staleDuplicates.count) duplicates", systemImage: "sparkles")
                    .font(MobileTheme.Typography.body)
            }
        } header: {
            Text("Stale duplicates")
        } footer: {
            Text("Old Firestore copies of this iPhone left over from previous installs. Removing them is safe — the active device stays connected.")
        }
    }

    // MARK: - Smart Hub (Cast Now)

    @ViewBuilder
    private var smartHubSection: some View {
        Section {
            SmartDisplayReorderableSection(smartHubStore: smartHub) { kind, _ in
                switch kind {
                case .nestHub:
                    nestHubBlock
                case .pixelClock:
                    pixelClockBlock
                }
            }
            setupShortcutBlock
        } header: {
            Text("Smart Displays")
        }
        .sheet(isPresented: $showSmartHubWizard) {
            SmartHubSetupWizardView(store: smartHub)
        }
    }

    @ViewBuilder
    private var pixelClockBlock: some View {
        PixelClockSettingsCard(smartHubStore: smartHub)
            .listRowInsets(EdgeInsets(
                top: MobileTheme.Spacing.xs,
                leading: 0,
                bottom: MobileTheme.Spacing.xs,
                trailing: 0
            ))
            .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var nestHubBlock: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            NestHubSettingsCard(smartHubStore: smartHub)

            // Cast Now action — kept above-the-fold even with the new
            // settings card so users can hit it without scrolling.
            HStack(spacing: MobileTheme.Spacing.md) {
                SmartHubCastButton(store: smartHub, compact: false)
                Spacer(minLength: 0)
            }

            if case .failure(let message) = smartHub.castState {
                Text(message)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.error)
            }
        }
        .listRowInsets(EdgeInsets(
            top: MobileTheme.Spacing.xs,
            leading: 0,
            bottom: MobileTheme.Spacing.xs,
            trailing: 0
        ))
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var setupShortcutBlock: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            if smartHub.canCast {
                wizardFooter
            } else {
                HStack(spacing: MobileTheme.Spacing.md) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Need a Nest Hub?")
                            .font(MobileTheme.Typography.body)
                        Text("Run guided setup, or use the Pixel Clock controls above.")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
            }
            Button {
                showSmartHubWizard = true
            } label: {
                Label("Set up Smart Display", systemImage: "wand.and.stars")
                    .font(MobileTheme.Typography.body.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(MobileTheme.whimsy, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var wizardFooter: some View {
        Button {
            showSmartHubWizard = true
        } label: {
            Text("Re-run setup wizard")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.whimsy)
        }
        .buttonStyle(.plain)
    }
}
