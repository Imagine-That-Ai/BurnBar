import SwiftUI
import OpenBurnBarCore

struct iPadDevicesSettingsView: View {
    @Bindable var store: DevicesStore
    @State private var smartHub = SmartHubStore()
    @State private var appCheckMonitor = MobileAppCheckAttestationMonitor.shared
    @State private var newName = ""
    @State private var showRenameSheet = false
    @State private var showRevokeConfirmation = false
    @State private var showCleanupConfirmation = false
    @State private var deviceToRevoke: DeviceRecord?
    @State private var linuxDeviceToApprove: LinuxAppCheckDeviceRecord?
    @State private var linuxDeviceToRevoke: LinuxAppCheckDeviceRecord?
    @State private var isReprobingHermes = false
    @State private var showSmartHubWizard = false
    /// Stream 6 (flag-OFF default): when the safety-code compare step is enabled,
    /// the "Approve This Device" action first opens a sheet showing this device's
    /// safety code so the operator can confirm it matches the approving device.
    @State private var showSafetyCompareSheet = false

    private var safetyCompareEnabled: Bool {
        EscrowDeviceTrustSafetyCheckFlag.isEnabled()
    }

    /// External `HermesService` so the relay status card reflects the
    /// same connection state the rest of the app uses. Optional — when
    /// nil (e.g. iPad split-view default constructor) we still render
    /// the rest of the screen.
    let hermesService: HermesService?

    init(store: DevicesStore, hermesService: HermesService? = nil) {
        self.store = store
        self.hermesService = hermesService
    }

    var body: some View {
        Form {
            if let warning = appCheckMonitor.lastWarningMessage {
                Section {
                    HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(MobileTheme.Colors.warning)
                        Spacer(minLength: 0)
                        Button("Dismiss") { appCheckMonitor.clearWarning() }
                            .font(.caption)
                    }
                }
            }

            if let error = store.lastError {
                Section {
                    Label(error.label, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(MobileTheme.Colors.error)
                }
            }

            if hermesService != nil {
                hermesRelaySection
            }
            smartHubSection
            thisDeviceSection
            otherDevicesSection
            linuxAppCheckDevicesSection

            if !store.staleDuplicates.isEmpty {
                duplicatesSection
            }
        }
        .navigationTitle("Devices & Sync")
        .accessibilityIdentifier("devicesSync.screen")
        .refreshable { await refreshAll() }
        .task { await refreshAll() }
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        .sheet(isPresented: $showSafetyCompareSheet) {
            DeviceTrustSafetyCompareSheet(
                device: store.currentDevice,
                onConfirm: {
                    showSafetyCompareSheet = false
                    Task { await store.bootstrapApproveSelf() }
                },
                onCancel: { showSafetyCompareSheet = false }
            )
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
        .alert(
            "Approve Linux Device?",
            isPresented: Binding(
                get: { linuxDeviceToApprove != nil },
                set: { if !$0 { linuxDeviceToApprove = nil } }
            ),
            presenting: linuxDeviceToApprove
        ) { device in
            Button("Cancel", role: .cancel) { linuxDeviceToApprove = nil }
            Button("Approve") {
                linuxDeviceToApprove = nil
                Task { await store.approveLinuxAppCheckDevice(device) }
            }
        } message: { device in
            Text("\(device.deviceName)\n\nDevice: \(device.deviceId)\nFingerprint: \(device.safetyFingerprint)\n\nApprove only if both values match the Linux app.")
        }
        .alert(
            "Revoke Linux Device?",
            isPresented: Binding(
                get: { linuxDeviceToRevoke != nil },
                set: { if !$0 { linuxDeviceToRevoke = nil } }
            ),
            presenting: linuxDeviceToRevoke
        ) { device in
            Button("Cancel", role: .cancel) { linuxDeviceToRevoke = nil }
            Button("Revoke", role: .destructive) {
                linuxDeviceToRevoke = nil
                Task { await store.revokeLinuxAppCheckDevice(device) }
            }
        } message: { device in
            Text("\(device.deviceName)\n\nDevice: \(device.deviceId)\nFingerprint: \(device.safetyFingerprint)\n\nThis device will immediately lose access. A revoked key cannot be approved again.")
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            content()
        } header: {
            Text(title)
        } footer: {
            if let footer {
                Text(footer)
            }
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
        settingsSection("This Device") {
            if let current = store.currentDevice {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(current.displayName)
                            .font(.body)
                        Text(current.id.prefix(8))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    trustBadge(for: current.trustState)
                }

                if store.bootstrapEligible {
                    Button("Approve This Device") {
                        // Flag-OFF default: approve immediately (existing behavior).
                        // Flag-ON: gate on the safety-code compare confirmation.
                        if safetyCompareEnabled {
                            showSafetyCompareSheet = true
                        } else {
                            Task { await store.bootstrapApproveSelf() }
                        }
                    }
                    .foregroundStyle(MobileTheme.Colors.accent)
                }

                Button("Rename") {
                    newName = current.displayName
                    showRenameSheet = true
                }
            } else {
                Text("Loading device info…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Other Devices

    private var otherDevicesSection: some View {
        settingsSection("Other Devices") {
            if store.otherDevices.isEmpty {
                Text("No other devices connected.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.otherDevices, id: \.id) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.displayName)
                                .font(.body)
                            Text(device.id.prefix(8))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
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

    // MARK: - Linux App Check Devices

    private var linuxAppCheckDevicesSection: some View {
        settingsSection(
            "Linux Sign-In Devices",
            footer: "Compare the public safety fingerprint shown here with the Linux app before approval. Private keys never leave the Linux device."
        ) {
            if store.isLoadingLinuxAppCheckDevices && store.linuxAppCheckDevices.isEmpty {
                HStack(spacing: MobileTheme.Spacing.sm) {
                    ProgressView()
                    Text("Checking Linux devices…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("devicesSync.linux.loading")
            } else if let error = store.linuxAppCheckError {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(MobileTheme.Colors.error)
                    Button {
                        Task { await store.loadLinuxAppCheckDevices() }
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("devicesSync.linux.retry")
                }
            } else if store.linuxAppCheckDevices.isEmpty {
                Text("No Linux sign-in devices are waiting for approval.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("devicesSync.linux.empty")
            } else {
                ForEach(store.linuxAppCheckDevices) { device in
                    linuxAppCheckDeviceRow(device)
                }
            }
        }
    }

    private func linuxAppCheckDeviceRow(_ device: LinuxAppCheckDeviceRecord) -> some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.deviceName)
                        .font(.body)
                    Text("Linux • \(device.deviceId.prefix(12))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                linuxTrustBadge(device.trustState)
            }

            Text(device.safetyFingerprint)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityLabel("Safety fingerprint \(device.safetyFingerprint)")

            if store.linuxAppCheckActionInFlightFor == device.id {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating \(device.deviceName)")
            } else {
                switch device.trustState {
                case .pending:
                    Button {
                        linuxDeviceToApprove = device
                    } label: {
                        Label("Approve", systemImage: "checkmark.shield")
                    }
                    .accessibilityIdentifier("devicesSync.linux.approve.\(device.id)")
                    .disabled(store.linuxAppCheckActionInFlightFor != nil)
                case .approved:
                    Button(role: .destructive) {
                        linuxDeviceToRevoke = device
                    } label: {
                        Label("Revoke", systemImage: "xmark.shield")
                    }
                    .accessibilityIdentifier("devicesSync.linux.revoke.\(device.id)")
                    .disabled(store.linuxAppCheckActionInFlightFor != nil)
                case .revoked:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("devicesSync.linux.device.\(device.id)")
    }

    private func linuxTrustBadge(_ state: LinuxAppCheckDeviceTrustState) -> some View {
        let color: Color = switch state {
        case .pending: MobileTheme.Colors.warning
        case .approved: MobileTheme.Colors.success
        case .revoked: MobileTheme.Colors.error
        }
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(state.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(color)
        }
    }

    // MARK: - Rename Sheet

    private var renameSheet: some View {
        NavigationStack {
            Form {
                TextField("Device Name", text: $newName)
                    .font(.body)
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
                .font(.caption)
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
        settingsSection("Hermes Relay", footer: hermesRelayFooter) {
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
                .font(.body)
                .foregroundStyle(MobileTheme.hermesAureate)
            }
            .disabled(isReprobingHermes)
        }
    }

    private var hermesRelayFooter: String? {
        // When the relay is offline, give the user the actionable restart
        // path. The Mac is the only safe place to bounce the relay today.
        if let relay = bestRelayConnection, relay.status == .offline {
            return "The relay last reported offline. Open OpenBurnBar on your Mac and toggle Settings -> Hermes -> Remote Relay off and on to restart it."
        }
        if bestRelayConnection == nil {
            return "No remote relay is published. On your Mac, open Settings -> Hermes and turn on Remote Relay."
        }
        return nil
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
                    .font(.body)
                if let model = relay.advertisedModel {
                    Text(model)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(relayLastSeenLabel(relay.lastSeenAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(relayStatusColor(relay.status))
                    .frame(width: 8, height: 8)
                Text(relayStatusLabel(relay.status))
                    .font(.caption)
                    .foregroundStyle(relayStatusColor(relay.status))
            }
        }
    }

    private var relayMissingCard: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No relay published")
                    .font(.body)
                Text("Hermes will fall back to local-only mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        settingsSection(
            "Stale duplicates",
            footer: "Old Firestore copies of this iPhone left over from previous installs. Removing them is safe - the active device stays connected."
        ) {
            let duplicates = store.staleDuplicates
            let preview = Array(duplicates.prefix(8))

            ForEach(preview, id: \.id) { device in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.displayName)
                            .font(.body)
                        Text(device.id.prefix(8))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let seen = device.lastSeen {
                            Text("Last seen \(seen.formatted(.relative(presentation: .numeric)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    trustBadge(for: device.trustState)
                }
            }
            if duplicates.count > preview.count {
                Text("\(duplicates.count - preview.count) more stale copies will be removed by cleanup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                showCleanupConfirmation = true
            } label: {
                Label("Clean up \(duplicates.count) duplicates", systemImage: "sparkles")
                    .font(.body)
            }
        }
    }

    // MARK: - Smart Hub (Cast Now)

    @ViewBuilder
    private var smartHubSection: some View {
        settingsSection("Smart Displays") {
            SmartDisplayReorderableSection(smartHubStore: smartHub) { kind, _ in
                switch kind {
                case .nestHub:
                    nestHubBlock
                case .pixelClock:
                    pixelClockBlock
                }
            }
            setupShortcutBlock
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
                    .font(.caption)
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
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Need a Nest Hub?")
                            .font(.body)
                        Text("Run guided setup, or use the Pixel Clock controls above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                showSmartHubWizard = true
            } label: {
                Label("Set up Smart Display", systemImage: "wand.and.stars")
                    .font(.body.bold())
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
                .font(.caption)
                .foregroundStyle(MobileTheme.whimsy)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Device Trust Safety-Code Compare

/// Stream 6 — the "Compare this code on your other device" confirmation step
/// shown before a device is approved (only when the safety-code compare feature
/// flag is ON). Renders the device's stored fingerprint as a grouped safety code
/// using the shared formatter so this device and the approving device display
/// byte-identical codes. UX only — confirmation calls the same unchanged approve
/// path; server-side fingerprint enforcement is a later PR.
struct DeviceTrustSafetyCompareSheet: View {
    let device: DeviceRecord?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var didCompare = false

    private var safetyCode: String? { device?.safetyCode }
    private var canApprove: Bool { device?.hasVerifiedSafetyCode == true }
    private var deviceName: String { device?.displayName ?? "this device" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Open OpenBurnBar on your other device and confirm the safety code below matches exactly. Approve only if both codes are identical.")
                        .font(.callout)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                }

                Section("Safety code") {
                    if let safetyCode {
                        Text(safetyCode)
                            .font(.system(.title3, design: .monospaced))
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityLabel("Safety code: \(EscrowDeviceSafetyCode.spelledOut(safetyCode))")
                    } else {
                        Text("This device has not published a verifiable escrow public key yet, so a safety code cannot be shown. Make sure it is signed in and on a current app version, then try again.")
                            .font(.caption)
                            .foregroundStyle(MobileTheme.Colors.warning)
                    }
                    if safetyCode != nil && !canApprove {
                        Text("The published key does not match the stored fingerprint. Approval is disabled until this device republishes a matching key.")
                            .font(.caption)
                            .foregroundStyle(MobileTheme.Colors.warning)
                    }
                }

                if canApprove {
                    Section {
                        Toggle("I compared this code on my other device and it matches.", isOn: $didCompare)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Verify \(deviceName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve", action: onConfirm)
                        .disabled(!canApprove || !didCompare)
                }
            }
        }
    }
}
