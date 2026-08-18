import SwiftUI
import OpenBurnBarKernel

// MARK: - Hermes Room (Face B)

/// Devices & Sync → Hermes Room. The face that answers one question: which of
/// my Macs is serving Hermes right now, and can I move it? (§ The three faces
/// of `plans/2026-08-17-war-room-master-plan.md`.)
///
/// Every "can I move it there" verdict comes from `HermesRoom`, which delegates
/// to `WarWireGate` — the same evaluation the Wire itself runs. A machine the
/// Wire would refuse is shown here as unavailable, with the same reason and no
/// second opinion, so the room can never promise a swap the Wire will deny.
struct HermesRoomDetailView: View {
    /// Both come from the runtime context so this face reads exactly the fleet
    /// and the grants the Wire is acting on. A private listener could show a
    /// lane as open after the Wire had already closed it.
    let directory: HermesBodyDirectory
    let grants: WarWireGrantStore
    let settingsManager: SettingsManager
    @StateObject private var entitlements = MacCloudEntitlementStore.shared
    @State private var linkTarget: HermesRoomRow?

    private var room: HermesRoomState {
        HermesRoom.state(
            fleet: directory.fleetSnapshot(),
            localBodyID: directory.localBody?.id ?? "",
            activeBodyID: settingsManager.activeHermesBodyID,
            tier: entitlements.cloudTier,
            killSwitchEngaged: settingsManager.warRoomKillSwitch,
            grants: grants.grantsByPairID
        )
    }

    var body: some View {
        SettingsDetailContainer(
            title: "Hermes Room",
            subtitle: "One Hermes, many machines. Pick which Mac serves it — the others stay linked and ready."
        ) {
            let room = room
            if !directory.hasLoaded {
                SettingsLoadingCard(message: "Reading the room…")
            } else if room.isEmpty {
                SettingsEmptyCard(
                    title: "No machines yet",
                    message: "Each Mac running OpenBurnBar joins the room automatically while Cloud sync is on and you are signed in."
                )
            } else {
                if settingsManager.warRoomKillSwitch {
                    wireOffCard
                }
                ForEach(room.rows) { row in
                    roomCard(row)
                }
            }
        }
        // Both are owned by the runtime context and started at boot; `start()`
        // is idempotent and only matters if this face is opened first. Closing
        // it must not stop them — the Wire is still using both.
        .task {
            directory.start()
            grants.start()
        }
        .confirmationDialog(
            "Link \(linkTarget?.body.displayName ?? "this Mac")?",
            isPresented: Binding(
                get: { linkTarget != nil },
                set: { if !$0 { linkTarget = nil } }
            )
        ) {
            Button("Link") {
                if let target = linkTarget, let local = directory.localBody?.id {
                    let remote = target.body.bodyID
                    Task { await grants.grantWire(between: local, and: remote) }
                }
                linkTarget = nil
            }
            Button("Cancel", role: .cancel) { linkTarget = nil }
        } message: {
            Text("Linking opens the Wire between these two Macs so work can move directly. Either machine can revoke it.")
        }
    }

    // MARK: - Cards

    private var wireOffCard: some View {
        GlassCard {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "bolt.slash.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.warning)
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                    Text("The Wire is off")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Hermes stays on this Mac. Everything else keeps working exactly as it does today.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private func roomCard(_ row: HermesRoomRow) -> some View {
        GlassCard {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                Image(systemName: row.body.isLocal ? "desktopcomputer" : "macmini")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(
                        row.isActive
                            ? DesignSystem.Colors.hermesAureate
                            : DesignSystem.Colors.textMuted
                    )
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(row.body.displayName)
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        if row.isActive {
                            HermesPill(text: "Serving")
                        }
                        if row.body.isLocal {
                            HermesPill(text: "This Mac")
                        }
                    }

                    Text(row.statusLine)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(
                            row.blockedReason == nil
                                ? DesignSystem.Colors.textSecondary
                                : DesignSystem.Colors.warning
                        )

                    if !row.body.isOnline {
                        Text("Offline")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }

                Spacer(minLength: 0)

                action(for: row)
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    @ViewBuilder
    private func action(for row: HermesRoomRow) -> some View {
        if row.isActive {
            EmptyView()
        } else if row.isSelectable {
            Button("Serve here") { serve(row) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!row.body.isOnline && !row.body.isLocal)
        } else if row.blockedReason == .noGrant {
            // The one denial the person at this Mac can resolve from this
            // screen. Every other reason is answered somewhere else, so the
            // room states it rather than offering a button that cannot help.
            Button("Link…") { linkTarget = row }
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else {
            EmptyView()
        }
    }

    /// Selecting the local machine clears the stored id rather than writing it,
    /// so a machine that is re-identified still reads as "serving here".
    private func serve(_ row: HermesRoomRow) {
        settingsManager.activeHermesBodyID = row.body.isLocal ? nil : row.body.bodyID
    }
}
