import SwiftUI
import OpenBurnBarCore

// MARK: - Data & Privacy Control Center (iPhone)
//
// The compact basin: a hero summarizing what BurnBar can and cannot see, the
// Transparency Inventory (every data domain from the generated registry with its
// encryption tier + live usage), the documented "Sync now" Pensieve action, and
// entry points to recovery + the panic switch. Bound entirely to the callable
// contract via `DataVaultStore`; no direct client writes.

struct DataVaultControlView: View {
    @State private var store = DataVaultStore()
    @Environment(\.cloudSubscriptionStore) private var cloudStore

    @State private var domainToInspect: DataDomain?
    @State private var showRecovery = false
    @State private var showAudit = false
    @State private var showPanicConfirm = false

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    DataVaultBasinHero(
                        tier: store.tier,
                        domains: store.domains,
                        usageByDomain: store.usageByDomain
                    )
                    .staggeredEntrance(delay: 0.0)

                    pensieveSyncCard
                        .staggeredEntrance(delay: 0.04)

                    inventorySection
                        .staggeredEntrance(delay: 0.08)

                    safetySection
                        .staggeredEntrance(delay: 0.14)

                    if let error = store.error {
                        DataVaultInlineError(message: error)
                    }
                }
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
                .padding(.vertical, MobileTheme.Spacing.md)
                .padding(.bottom, MobileTheme.Spacing.xxxl)
            }
            .refreshable {
                HapticBus.refreshStarted()
                await store.load()
            }
        }
        .navigationTitle("Data & Privacy")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await store.load() }
        .sheet(item: $domainToInspect) { domain in
            NavigationStack {
                DataDomainDetailView(domain: domain, store: store)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showRecovery) {
            NavigationStack { DataVaultRecoveryView(store: store) }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAudit) {
            NavigationStack { DataVaultAuditView(store: store) }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Revoke all access?",
            isPresented: $showPanicConfirm,
            titleVisibility: .visible
        ) {
            Button("Revoke sync & relays", role: .destructive) {
                Task { _ = await store.revokeAllAccess(scope: "sync") }
            }
            Button("Revoke EVERYTHING", role: .destructive) {
                HapticBus.destructive()
                Task { _ = await store.revokeAllAccess(scope: "all") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs out every connected agent, device, and provider. Your sealed data stays encrypted; nothing can reach it until you re-trust a device.")
        }
    }

    // MARK: - Pensieve Sync card (the documented "Sync now" gap)

    @ViewBuilder
    private var pensieveSyncCard: some View {
        let pensieve = DataDomains.domain("pensieve")
        AuroraGlassCard(variant: .standard, cornerRadius: 18) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack(spacing: 12) {
                    Image(systemName: pensieve?.icon ?? "brain.head.profile")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(EncryptionTier.endToEnd.tierColor)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(EncryptionTier.endToEnd.tierColor.opacity(0.16))
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pensieve knowledge")
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text(pensieveSubtitle)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }

                if let limits = store.pensieveLimits, let usage = store.usage(for: "pensieve") {
                    PensieveCapMeters(limits: limits, usage: usage, tier: store.tier)
                }

                Button {
                    Task {
                        HapticBus.primaryAction()
                        await store.syncKnowledgeNow()
                    }
                } label: {
                    HStack {
                        if store.isSyncingKnowledge {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(store.isSyncingKnowledge ? "Sealing & syncing…" : "Sync now")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aurora(.secondary, fullWidth: true))
                .disabled(store.isSyncingKnowledge || !store.isPensieveTier)

                if let written = store.lastKnowledgeSyncWritten {
                    Text(written == 0 ? "Nothing new to sync — you're up to date." : "Sealed and committed \(written) new chunk\(written == 1 ? "" : "s").")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }

                if !store.isPensieveTier {
                    Text("Pensieve needs BurnBar Cloud Pro. Upgrade to seal repo docs, notes, and chat memories.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(EncryptionTier.serverReadable.tierColor)
                }
            }
        }
    }

    private var pensieveSubtitle: String {
        "Repo docs, notes, and chat memories — embedded, cloaked, and sealed on this device before they sync."
    }

    // MARK: - Transparency Inventory

    private var inventorySection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            DataVaultSectionHeader(
                title: "Transparency inventory",
                subtitle: "Every kind of data, what the server can see, and how to remove it."
            )
            ForEach(store.domains) { domain in
                Button {
                    HapticBus.chipChange()
                    domainToInspect = domain
                } label: {
                    DataDomainInventoryRow(
                        domain: domain,
                        usage: store.usage(for: domain.id),
                        isLoading: store.isLoading
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Safety (recovery + audit + panic)

    private var safetySection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            DataVaultSectionHeader(
                title: "Keys & safety",
                subtitle: "Recovery, the tamper-evident access log, and the panic switch."
            )

            DataVaultActionRow(
                title: "Recovery",
                subtitle: recoverySubtitle,
                icon: "key.horizontal.fill",
                tint: EncryptionTier.endToEnd.tierColor
            ) { showRecovery = true }

            DataVaultActionRow(
                title: "Access audit log",
                subtitle: "Who and what touched your data — a verifiable hash chain.",
                icon: "list.bullet.rectangle.portrait.fill",
                tint: EncryptionTier.serverReadable.tierColor
            ) { showAudit = true }

            Button {
                HapticBus.threshold()
                showPanicConfirm = true
            } label: {
                DataVaultActionRowChrome(
                    title: "Revoke all access",
                    subtitle: "Panic switch — cut off every agent, device, and provider at once.",
                    icon: "exclamationmark.shield.fill",
                    tint: Color(hex: PensieveTokens.colorSealCrimson),
                    isDestructive: true,
                    showsBusy: store.isRevoking
                )
            }
            .buttonStyle(.plain)
            .disabled(store.isRevoking)
        }
    }

    private var recoverySubtitle: String {
        if store.recoveryMethods.isEmpty {
            return "Set up a recovery key or contact before zero-knowledge mode."
        }
        let confirmed = store.recoveryMethods.filter(\.confirmed).count
        return "\(confirmed) of \(store.recoveryMethods.count) recovery method\(store.recoveryMethods.count == 1 ? "" : "s") confirmed."
    }
}

// MARK: - Section header

struct DataVaultSectionHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, MobileTheme.Spacing.sm)
    }
}

// MARK: - Inline error

struct DataVaultInlineError: View {
    let message: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(MobileTheme.warning)
            Text(message)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MobileTheme.warning.opacity(0.12))
        )
    }
}
