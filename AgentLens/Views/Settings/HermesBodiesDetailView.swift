import SwiftUI

// MARK: - Hermes Bodies Detail

/// Devices & Sync → Hermes Bodies. The account's machine roster: every Mac
/// that has published a HermesBody, with name, hardware, and heartbeat-derived
/// presence. Renames here are what the swap control and the Command Board
/// display everywhere — a Hermes is a name bound to a machine.
struct HermesBodiesDetailView: View {
    @State private var directory = HermesBodyDirectory()
    @State private var renameTarget: HermesBodyRecord?
    @State private var renameText = ""
    @State private var removalTarget: HermesBodyRecord?

    var body: some View {
        SettingsDetailContainer(
            title: "Hermes Bodies",
            subtitle: "Each Mac running OpenBurnBar publishes one Hermes identity — its name, hardware, and presence. Rename a machine here and every surface follows."
        ) {
            if !directory.hasLoaded {
                loadingCard
            } else if directory.bodies.isEmpty {
                emptyCard
            } else {
                ForEach(directory.bodies) { body in
                    bodyCard(body)
                }
            }
        }
        .task { directory.start() }
        .onDisappear { directory.stop() }
        .alert(
            "Rename Hermes",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let target = renameTarget {
                    let name = renameText
                    Task { await directory.rename(bodyID: target.id, to: name) }
                }
                renameTarget = nil
            }
        } message: {
            Text("The name is bound to the machine, not to any bot running on it.")
        }
        .confirmationDialog(
            "Remove \(removalTarget?.displayName ?? "this Hermes")?",
            isPresented: Binding(
                get: { removalTarget != nil },
                set: { if !$0 { removalTarget = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let target = removalTarget {
                    Task { await directory.remove(bodyID: target.id) }
                }
                removalTarget = nil
            }
            Button("Cancel", role: .cancel) { removalTarget = nil }
        } message: {
            Text("Removes the record for a decommissioned machine. A Mac that is still running republishes itself on its next heartbeat.")
        }
    }

    private var loadingCard: some View {
        GlassCard {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading Hermes bodies…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private var emptyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("No Hermes bodies yet")
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("This Mac publishes its body automatically while Cloud sync is on and you are signed in.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
        }
    }

    private func bodyCard(_ body: HermesBodyRecord) -> some View {
        let presence = body.presence()
        let isLocal = directory.isLocal(body)
        return GlassCard {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                Image(systemName: DeviceHardwareIcon.sfSymbol(for: body.hardwareModel))
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(body.displayName)
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        if isLocal {
                            Text("This Mac")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                                .padding(.horizontal, DesignSystem.Spacing.xs)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().stroke(DesignSystem.Colors.hermesAureate.opacity(0.6), lineWidth: 1)
                                )
                        }
                    }

                    Text("\(body.machineName) · \(body.hardwareSummary)")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                    Text(hermesStatusLabel(body))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xxs) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Circle()
                            .fill(presence == .online ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
                            .frame(width: 7, height: 7)
                        Text(presence == .online ? "Online" : "Offline")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(presence == .online ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
                    }
                    if let lastHeartbeatAt = body.lastHeartbeatAt {
                        Text(lastHeartbeatAt.formatted(.relative(presentation: .named)))
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
        .contextMenu {
            Button("Rename…") {
                renameText = body.displayName
                renameTarget = body
            }
            if !isLocal {
                Button("Remove…", role: .destructive) {
                    removalTarget = body
                }
            }
        }
    }

    private func hermesStatusLabel(_ body: HermesBodyRecord) -> String {
        if body.hermesGatewayReachable { return "Hermes gateway reachable" }
        if body.hermesInstalled { return "Hermes installed · gateway off" }
        return "Hermes not detected"
    }
}
