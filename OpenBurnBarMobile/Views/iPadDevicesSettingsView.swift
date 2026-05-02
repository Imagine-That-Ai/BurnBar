import SwiftUI
import OpenBurnBarCore

struct iPadDevicesSettingsView: View {
    @State private var store = DevicesStore()
    @State private var newName = ""
    @State private var showRenameSheet = false
    @State private var showRevokeConfirmation = false
    @State private var deviceToRevoke: DeviceRecord?

    var body: some View {
        Form {
            thisDeviceSection
            otherDevicesSection
        }
        .formStyle(.grouped)
        .navigationTitle("Devices & Sync")
        .refreshable { await store.load() }
        .task { await store.load() }
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
}
