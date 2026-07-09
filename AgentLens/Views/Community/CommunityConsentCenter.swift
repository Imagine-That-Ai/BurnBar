import SwiftUI
import OpenBurnBarCore

struct CommunityConsentCenter: View {
    @ObservedObject var consentStore: CommunityConsentStore
    @ObservedObject var service: CommunityService

    @State private var handleDraft: String = ""
    @State private var statusMessage: String?
    @State private var isBusy = false
    @State private var exportURL: URL?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text("Consent center")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)

                ladderRow(
                    title: "L1 — Private analytics",
                    detail: "Local-only personal dashboard. No egress.",
                    value: consentStore.l1Analytics
                ) { consentStore.setL1($0) }

                ladderRow(
                    title: "L2 — Community rankings",
                    detail: "Anonymized leaderboard participation.",
                    value: consentStore.l2Rankings
                ) { consentStore.setL2($0) }

                if consentStore.l2Rankings == .granted {
                    tierToggles
                }

                ladderRow(
                    title: "L3 — Looking Glass",
                    detail: "Richer traces and export bundles. Never feeds leaderboards.",
                    value: consentStore.l3LookingGlass
                ) { consentStore.setL3($0) }

                locationToggle

                dataPreview

                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button {
                        Task { await saveAndJoin() }
                    } label: {
                        Label(isBusy ? "Working…" : "Save & join", systemImage: "person.2.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)

                    if consentStore.l3LookingGlass == .granted {
                        Button("Export bundle") { Task { await exportBundle() } }
                            .buttonStyle(.bordered)
                            .disabled(isBusy)
                    }

                    Button("Revoke", role: .destructive) { Task { await revoke() } }
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                }

                if let exportURL {
                    Link("Download Looking Glass export", destination: exportURL)
                        .font(DesignSystem.Typography.caption)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
        }
        .onAppear {
            handleDraft = service.profile?.handle ?? ""
        }
    }

    private var tierToggles: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Geography tiers")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            ForEach(FirestoreGeographyTier.allCases, id: \.self) { tier in
                triStatePicker(
                    label: tierLabel(tier),
                    value: consentStore.tierConsent(tier)
                ) { consentStore.setTier(tier, $0) }
            }
        }
        .padding(.leading, DesignSystem.Spacing.sm)
    }

    private var locationToggle: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            triStatePicker(
                label: "Coarse location (required for city tier)",
                value: consentStore.locationConsent
            ) { consentStore.setLocation($0) }
            Text(cityConfidenceCopy)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            if let city = consentStore.resolvedCityKey,
               consentStore.l2City == .granted,
               consentStore.locationConsent == .granted {
                Text("Resolved city: \(city)")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
    }

    private var cityConfidenceCopy: String {
        guard consentStore.l2Rankings == .granted, consentStore.l2City == .granted else {
            return "City confidence: no city lookup. Country and region can use locale/timezone; world ranking needs no location."
        }
        guard consentStore.locationConsent == .granted else {
            return "City confidence: city rank is paused until approximate location is granted; broader tiers still use locale/timezone."
        }
        if consentStore.resolvedCityKey != nil {
            return "City confidence: macOS approximate location resolved a city key. BurnBar stores only the key, never raw coordinates."
        }
        return "City confidence: macOS approximate location will resolve on save; raw coordinates never leave this device."
    }

    private var dataPreview: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Data preview")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            TextField("Handle (optional)", text: $handleDraft)
                .textFieldStyle(.roundedBorder)
            if let profile = service.profile {
                Text("Anon ID: \(profile.anonId)")
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            } else {
                Text("Join to receive an anonymous ID and optional handle.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }

    private func ladderRow(
        title: String,
        detail: String,
        value: CommunityConsentLadder,
        onChange: @escaping (CommunityConsentLadder) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            triStatePicker(label: title, value: value, onChange: onChange)
        }
    }

    private func triStatePicker(
        label: String,
        value: CommunityConsentLadder,
        onChange: @escaping (CommunityConsentLadder) -> Void
    ) -> some View {
        Picker(label, selection: Binding(
            get: { value },
            set: { onChange($0) }
        )) {
            Text("Unset").tag(CommunityConsentLadder.unset)
            Text("Granted").tag(CommunityConsentLadder.granted)
            Text("Declined").tag(CommunityConsentLadder.declined)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(label)
    }

    private func tierLabel(_ tier: FirestoreGeographyTier) -> String {
        switch tier {
        case .world: return "World"
        case .country: return "Country"
        case .region: return "Region"
        case .city: return "City"
        }
    }

    private func saveAndJoin() async {
        isBusy = true
        defer { isBusy = false }
        do {
            await consentStore.refreshGeoFromOSIfNeeded()
            let payload = consentStore.joinPayload(
                handle: handleDraft.nilIfBlank(),
                countryCode: service.profile?.countryCode,
                regionKey: service.profile?.regionKey,
                cityKey: service.profile?.cityKey
            )
            _ = try await service.joinCommunity(payload: payload)
            if let handle = handleDraft.nilIfBlank() {
                try await service.updateProfile([
                    "handle": handle,
                    "timezone": TimeZone.current.identifier,
                    "locale": Locale.current.identifier,
                ])
            }
            statusMessage = "Community preferences saved."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func exportBundle() async {
        isBusy = true
        defer { isBusy = false }
        do {
            exportURL = try await service.exportLookingGlassBundle()
            statusMessage = "Export link ready (15 min)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func revoke() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.revokeParticipation()
            consentStore.revokeAllLocally()
            statusMessage = "Participation revoked."
            exportURL = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private extension String {
    func nilIfBlank() -> String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}