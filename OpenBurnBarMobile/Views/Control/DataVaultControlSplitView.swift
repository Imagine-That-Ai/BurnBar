import SwiftUI
import OpenBurnBarCore

struct DataVaultAdaptiveControlView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            DataVaultControlSplitView()
        } else {
            DataVaultControlView()
        }
    }
}

// MARK: - Data & Privacy Control Center (iPad — 3-column cinematic basin)
//
// Column 1: sections (Inventory / Pensieve / Keys & safety / Audit).
// Column 2: the list within the selected section (domains, recovery methods…).
// Column 3: the cinematic detail — the wide basin canvas for the selection.
//
// Reuses `DataVaultStore` and the same row/detail components as iPhone so the
// two surfaces never diverge. Falls back to the single-column compact view on
// narrow widths automatically via NavigationSplitView.

struct DataVaultControlSplitView: View {
    @State private var store = DataVaultStore()
    @State private var section: DataVaultSection? = .inventory
    @State private var selectedDomainID: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sectionSidebar
        } content: {
            contentColumn
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        .task { await store.load() }
    }

    // MARK: Column 1 — sections

    private var sectionSidebar: some View {
        List(DataVaultSection.allCases, selection: $section) { item in
            Label(item.title, systemImage: item.icon)
                .tag(item)
        }
        .navigationTitle("Data & Privacy")
        .listStyle(.sidebar)
        .overlay(alignment: .bottom) {
            DataTierBadge(tier: store.tier)
                .padding(.bottom, MobileTheme.Spacing.lg)
        }
    }

    // MARK: Column 2 — list within section

    @ViewBuilder
    private var contentColumn: some View {
        switch section ?? .inventory {
        case .inventory:
            List(store.domains, selection: $selectedDomainID) { domain in
                DataDomainInventoryRow(
                    domain: domain,
                    usage: store.usage(for: domain.id),
                    isLoading: store.isLoading
                )
                .tag(domain.id)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .background(AuroraBackdrop(density: .subtle))
            .navigationTitle("Inventory")
        case .pensieve:
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    DataVaultBasinHero(tier: store.tier, domains: store.domains, usageByDomain: store.usageByDomain)
                    PensieveSyncPanel(store: store)
                }
                .padding(AuroraDesign.Layout.cardInset)
            }
            .background(AuroraBackdrop(density: .subtle))
            .navigationTitle("Pensieve")
        case .safety:
            DataVaultSafetyPanel(store: store)
                .navigationTitle("Keys & safety")
        case .audit:
            DataVaultAuditView(store: store)
        }
    }

    // MARK: Column 3 — cinematic detail

    @ViewBuilder
    private var detailColumn: some View {
        switch section ?? .inventory {
        case .inventory:
            if let id = selectedDomainID, let domain = DataDomains.domain(id) {
                DataDomainDetailView(domain: domain, store: store)
            } else {
                DataVaultCinematicPlaceholder(
                    icon: "lock.shield.fill",
                    title: "Pick a data kind",
                    message: "Choose any row to see exactly what the server can read and how to remove it."
                )
            }
        case .pensieve, .safety, .audit:
            DataVaultBasinCanvas(tier: store.tier, domains: store.domains, usageByDomain: store.usageByDomain)
        }
    }
}

// MARK: - Sections

enum DataVaultSection: String, CaseIterable, Identifiable {
    case inventory, pensieve, safety, audit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inventory: return "Transparency inventory"
        case .pensieve: return "Pensieve knowledge"
        case .safety: return "Keys & safety"
        case .audit: return "Access audit"
        }
    }
    var icon: String {
        switch self {
        case .inventory: return "square.grid.2x2.fill"
        case .pensieve: return "brain.head.profile"
        case .safety: return "key.horizontal.fill"
        case .audit: return "list.bullet.rectangle.portrait.fill"
        }
    }
}

// MARK: - Pensieve sync panel (shared content-column body)

struct PensieveSyncPanel: View {
    @Bindable var store: DataVaultStore

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 18) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                Text("Pensieve knowledge")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text("Repo docs, notes, and chat memories — embedded, cloaked, and sealed on this device before they sync.")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                if let limits = store.pensieveLimits, let usage = store.usage(for: "pensieve") {
                    PensieveCapMeters(limits: limits, usage: usage, tier: store.tier)
                }
                Button {
                    Task { await store.syncKnowledgeNow() }
                } label: {
                    Label(store.isSyncingKnowledge ? "Sealing & syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aurora(.secondary, fullWidth: true))
                .disabled(store.isSyncingKnowledge || !store.isPensieveTier)
                if let written = store.lastKnowledgeSyncWritten {
                    Text(written == 0 ? "Nothing new to sync." : "Sealed and committed \(written) new chunk\(written == 1 ? "" : "s").")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                if let error = store.error { DataVaultInlineError(message: error) }
            }
        }
    }
}

// MARK: - Safety panel

struct DataVaultSafetyPanel: View {
    @Bindable var store: DataVaultStore
    @State private var showRecovery = false
    @State private var showPanicConfirm = false

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.sm) {
                    DataVaultActionRow(
                        title: "Recovery",
                        subtitle: store.recoveryMethods.isEmpty
                            ? "Set up a recovery key or contact before zero-knowledge mode."
                            : "\(store.recoveryMethods.filter(\.confirmed).count) of \(store.recoveryMethods.count) confirmed.",
                        icon: "key.horizontal.fill",
                        tint: EncryptionTier.endToEnd.tierColor
                    ) { showRecovery = true }

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

                    if let error = store.error { DataVaultInlineError(message: error) }
                }
                .padding(AuroraDesign.Layout.cardInset)
            }
        }
        .sheet(isPresented: $showRecovery) {
            NavigationStack { DataVaultRecoveryView(store: store) }
        }
        .confirmationDialog("Revoke all access?", isPresented: $showPanicConfirm, titleVisibility: .visible) {
            Button("Revoke sync & relays", role: .destructive) {
                Task { _ = await store.revokeAllAccess(scope: "sync") }
            }
            Button("Revoke EVERYTHING", role: .destructive) {
                HapticBus.destructive()
                Task { _ = await store.revokeAllAccess(scope: "all") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs out every connected agent, device, and provider. Your sealed data stays encrypted.")
        }
        .task { await store.loadRecovery() }
    }
}

// MARK: - Cinematic basin canvas (detail column)

struct DataVaultBasinCanvas: View {
    let tier: String
    let domains: [DataDomain]
    let usageByDomain: [String: DataDomainUsageRow]

    var body: some View {
        ZStack {
            AuroraBackdrop()
            VStack(spacing: MobileTheme.Spacing.lg) {
                DataVaultBasinHero(tier: tier, domains: domains, usageByDomain: usageByDomain)
                    .frame(maxWidth: 560)
                tierLegend
                    .frame(maxWidth: 560)
            }
            .padding(MobileTheme.Spacing.xl)
        }
    }

    private var tierLegend: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 18) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                Text("How your data is protected")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                legendRow(.endToEnd)
                legendRow(.zeroAccess)
                legendRow(.serverReadable)
            }
        }
    }

    private func legendRow(_ tier: EncryptionTier) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tier.lockSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tier.tierColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(tier.shortLabel)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(tier.tierColor)
                Text(tier.promise)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
    }
}

struct DataVaultCinematicPlaceholder: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)
            AuroraStatePane(kind: .empty, icon: icon, title: title, message: message)
        }
    }
}
