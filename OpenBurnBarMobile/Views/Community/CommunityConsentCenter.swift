import SwiftUI
import OpenBurnBarCore
import OpenBurnBarFirestoreModels

struct CommunityConsentCenter: View {
    @ObservedObject private var consent = CommunityConsentStore.shared
    let shareSnapshot: FirestoreCommunityShareSnapshotDoc?
    let isSyncing: Bool
    let onJoin: () async -> Void
    let onRevoke: () async -> Void
    let onExportLookingGlass: () async -> Void

    @State private var showRevokeConfirm = false

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                CommunityEditorialTypography.eyebrowText("Consent center")

                consentRow(
                    title: "Private analytics (L1)",
                    detail: "Local-only dashboard. No egress.",
                    binding: triBinding(
                        get: { consent.l1Analytics },
                        set: { consent.setL1($0) }
                    )
                )

                consentRow(
                    title: "Community rankings (L2)",
                    detail: "Anonymized leaderboards by geography.",
                    binding: triBinding(
                        get: { consent.l2Rankings },
                        set: { consent.setL2Rankings($0) }
                    )
                )

                if consent.l2Rankings == .granted {
                    tierLadder
                }

                consentRow(
                    title: "Coarse location",
                    detail: "Required for city-tier boards. Never precise GPS.",
                    binding: triBinding(
                        get: { consent.locationConsent },
                        set: { consent.setLocation($0) }
                    )
                )
                Text(cityConfidenceCopy)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                if let city = consent.resolvedCityKey,
                   consent.tierState(.city) == .granted,
                   consent.locationConsent == .granted {
                    Text("Resolved city: \(city)")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                }

                consentRow(
                    title: "Looking glass (L3)",
                    detail: "Richer traces + export bundles. Never feeds leaderboards.",
                    binding: triBinding(
                        get: { consent.l3LookingGlass },
                        set: { consent.setL3($0) }
                    )
                )

                dataPreview

                HStack(spacing: 12) {
                    Button {
                        Task { await onJoin() }
                    } label: {
                        Label(isSyncing ? "Saving…" : "Save & join", systemImage: "checkmark.seal")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MobileTheme.ember)
                    .disabled(isSyncing)

                    if consent.l3LookingGlass == .granted {
                        Button {
                            Task { await onExportLookingGlass() }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Export looking glass bundle")
                    }
                }

                Button(role: .destructive) {
                    showRevokeConfirm = true
                } label: {
                    Text("Revoke community participation")
                        .font(MobileTheme.Typography.caption)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .confirmationDialog(
            "Revoke community participation?",
            isPresented: $showRevokeConfirm,
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                Task { await onRevoke() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your profile and rankings are tombstoned. You can opt in again later.")
        }
    }

    private var cityConfidenceCopy: String {
        guard consent.l2Rankings == .granted, consent.tierState(.city) == .granted else {
            return "City confidence: no city lookup. Country and region can use locale/timezone; world ranking needs no location."
        }
        guard consent.locationConsent == .granted else {
            return "City confidence: city rank is paused until approximate location is granted; broader tiers still use locale/timezone."
        }
        if consent.resolvedCityKey != nil {
            return "City confidence: approximate iOS location resolved a city key. BurnBar stores only the key, never raw coordinates."
        }
        return "City confidence: approximate iOS location resolves on save; raw coordinates never leave this device."
    }

    private var tierLadder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Geography tiers")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            ForEach([FirestoreGeographyTier.world, .country, .region, .city], id: \.rawValue) { tier in
                Toggle(isOn: tierGrantedBinding(tier)) {
                    Text(tier.displayName)
                        .font(MobileTheme.Typography.body)
                }
                .toggleStyle(.switch)
                .tint(MobileTheme.ember)
            }
        }
        .padding(.leading, 4)
    }

    private var dataPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Data preview")
                .font(CommunityEditorialTypography.sectionTitle)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            if let shareSnapshot, shareSnapshot.revoked != true {
                Text("Last shared \(shareSnapshot.updatedAt)")
                    .font(CommunityEditorialTypography.metaStrip)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Text("Models: \(shareSnapshot.modelMix.keys.sorted().prefix(4).joined(separator: ", "))")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
            } else {
                Text("Nothing shared yet — rankings stay dark until you join and snapshots upload.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
    }

    private func consentRow(
        title: String,
        detail: String,
        binding: Binding<Bool>
    ) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(detail)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .toggleStyle(.switch)
        .tint(MobileTheme.ember)
    }

    private func triBinding(
        get: @escaping () -> FirestoreConsentTriState,
        set: @escaping (FirestoreConsentTriState) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { get() == .granted },
            set: { set($0 ? .granted : .declined) }
        )
    }

    private func tierGrantedBinding(_ tier: FirestoreGeographyTier) -> Binding<Bool> {
        Binding(
            get: { consent.tierState(tier) == .granted },
            set: { consent.setTier(tier, state: $0 ? .granted : .declined) }
        )
    }
}

private extension FirestoreGeographyTier {
    var displayName: String {
        switch self {
        case .world: "World"
        case .country: "Country"
        case .region: "Region"
        case .city: "City"
        }
    }
}