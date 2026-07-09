import SwiftUI
import OpenBurnBarCore

struct CommunityView: View {
    let dashboard: DashboardStore
    @Bindable var communityStore: CommunityStore

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.mobileAuthStore) private var authStore
    @State private var exportURL: URL?
    @State private var showExport = false
    @State private var actionError: String?

    private var modelSummaries: [RollupModelSummary] { dashboard.topModels }

    var body: some View {
        ZStack {
            AuroraBackdrop()
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    if horizontalSizeClass == .regular {
                        iPadLayout
                    } else {
                        phoneLayout
                    }
                }
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
                .padding(.vertical, MobileTheme.Spacing.md)
                .padding(.bottom, MobileTheme.Spacing.xxxl)
            }
            .refreshable {
                await reload()
            }
        }
        .navigationTitle("Community")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: authStore?.currentIdentity?.uid) {
            await reload()
        }
        .onChange(of: communityStore.selectedWindow) { _, _ in
            Task {
                if let uid = authStore?.currentIdentity?.uid {
                    await communityStore.fetchLeaderboards(uid: uid)
                }
            }
        }
        .alert("Community", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .sheet(isPresented: $showExport) {
            if let exportURL {
                SafariLinkSheet(url: exportURL)
            }
        }
    }

    private var phoneLayout: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            personalHero.staggeredEntrance(delay: 0)
            leaderboardSection.staggeredEntrance(delay: 0.05)
            percentileStrip.staggeredEntrance(delay: 0.08)
            timeFilter.staggeredEntrance(delay: 0.10)
            peerChart.staggeredEntrance(delay: 0.12)
            purposeBreakdown.staggeredEntrance(delay: 0.14)
            consentCenter.staggeredEntrance(delay: 0.16)
        }
    }

    private var iPadLayout: some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.lg) {
            VStack(spacing: MobileTheme.Spacing.lg) {
                personalHero
                percentileStrip
                timeFilter
                peerChart
                purposeBreakdown
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: MobileTheme.Spacing.lg) {
                leaderboardSection
                consentCenter
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Personal hero

    private var personalHero: some View {
        AuroraGlassCard(variant: .hero, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                CommunityEditorialTypography.eyebrowText("Personal · \(communityStore.selectedWindow.label)")
                Text(heroHeadline)
                    .font(CommunityEditorialTypography.displayHeadline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                CommunityEditorialTypography.mercuryHairline

                HStack(spacing: 16) {
                    metaChip(label: "Tokens", value: heroTokensText)
                    metaChip(label: "Cost", value: heroCostText)
                    metaChip(label: "Models", value: heroModelMixText)
                }

                if let delta = heroTrendDelta {
                    Text(delta)
                        .font(CommunityEditorialTypography.metaStrip)
                        .foregroundStyle(MobileTheme.ember)
                }
            }
        }
    }

    private var leaderboardSection: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            if !CommunityConsentStore.shared.participatesInRankings {
                inviteEmptyState
            } else if communityStore.leaderboards.isEmpty {
                AuroraGlassCard(variant: .standard, cornerRadius: 16) {
                    Text("Leaderboards refresh hourly after you join.")
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                }
            } else {
                ForEach(leaderboardTierOrder, id: \.rawValue) { tier in
                    if let board = communityStore.leaderboards[tier] {
                        CommunityLeaderboardCard(
                            tier: tier,
                            board: board,
                            pinnedAnonId: communityStore.profile?.anonId
                        )
                    }
                }
            }
        }
    }

    private var inviteEmptyState: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Compare your burn—on your terms")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text("Turn on Community rankings in the consent center below whenever you want anonymized leaderboards.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
    }

    private var percentileStrip: some View {
        let resolved = FirestoreCommunityLeaderboardDoc.resolvedBoard(for: communityStore.leaderboards)
        return AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 10) {
                CommunityEditorialTypography.eyebrowText("Percentile strip")
                if let resolved, !resolved.doc.belowThreshold {
                    HStack(spacing: 0) {
                        percentileCell("p50", resolved.doc.percentiles.p50)
                        percentileCell("p75", resolved.doc.percentiles.p75)
                        percentileCell("p90", resolved.doc.percentiles.p90)
                        percentileCell("p99", resolved.doc.percentiles.p99)
                    }
                    Text(youStandCopy(resolved: resolved))
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                } else {
                    Text("Percentiles appear once a geography tier has enough burners.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
        }
    }

    private var timeFilter: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 8) {
                CommunityEditorialTypography.eyebrowText("Time filter")
                Picker("Window", selection: $communityStore.selectedWindow) {
                    ForEach(CommunityTimeWindow.allCases) { window in
                        Text(window.label).tag(window)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var peerChart: some View {
        let resolved = FirestoreCommunityLeaderboardDoc.resolvedBoard(for: communityStore.leaderboards)
        let userTokens = Double(heroTokenCount)
        return AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 12) {
                CommunityEditorialTypography.eyebrowText("Peer comparison")
                if let resolved, !resolved.doc.belowThreshold, userTokens > 0 {
                    peerBars(
                        user: userTokens,
                        p50: resolved.doc.percentiles.p50,
                        p75: resolved.doc.percentiles.p75,
                        p90: resolved.doc.percentiles.p90
                    )
                } else {
                    Text("Anonymized cohort chart—no individual peers shown below k=10.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
        }
    }

    private var purposeBreakdown: some View {
        let mix = ModelPurposeClassifier.displayPurposeMix(
            snapshot: communityStore.shareSnapshot,
            modelSummaries: modelSummaries
        )
        return AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 10) {
                CommunityEditorialTypography.eyebrowText("Purpose breakdown")
                if mix.isEmpty {
                    Text("Classifier labels appear as sessions accumulate.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                } else {
                    ForEach(Array(mix.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.label.capitalized)
                                .font(MobileTheme.Typography.body)
                            Spacer()
                            Text(String(format: "%.0f%%", item.share * 100))
                                .font(CommunityEditorialTypography.metaStrip)
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(MobileTheme.ember.opacity(0.25))
                                .frame(width: geo.size.width * CGFloat(min(1, item.share)))
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
    }

    private var consentCenter: some View {
        CommunityConsentCenter(
            shareSnapshot: communityStore.shareSnapshot,
            isSyncing: communityStore.isSyncingConsent,
            onJoin: {
                do {
                    await CommunityConsentStore.shared.refreshGeoFromOSIfNeeded()
                    try await communityStore.syncJoin()
                    await reload()
                } catch {
                    actionError = error.localizedDescription
                }
            },
            onRevoke: {
                do {
                    try await communityStore.revokeParticipation()
                    await reload()
                } catch {
                    actionError = error.localizedDescription
                }
            },
            onExportLookingGlass: {
                do {
                    let url = try await CommunityCallableClient.exportLookingGlassBundle()
                    exportURL = url
                    showExport = true
                } catch {
                    actionError = error.localizedDescription
                }
            }
        )
    }

    // MARK: - Derived hero

    private var heroTokenCount: Int64 {
        if let snap = communityStore.shareSnapshot, snap.revoked != true {
            return snap.usage(for: communityStore.selectedWindow).totalTokens
        }
        let key: RollupWindowKey = {
            switch communityStore.selectedWindow {
            case .today: .today
            case .sevenDay: .sevenDays
            case .thirtyDay: .thirtyDays
            case .ninetyDay: .ninetyDays
            case .allTime: .allTime
            }
        }()
        return Int64(dashboard.windowTotals[key]?.tokens ?? 0)
    }

    private var heroHeadline: String {
        let tokens = heroTokenCount
        if tokens == 0 { return "Your story starts here" }
        return "\(tokens.formatAsTokens()) tokens this window"
    }

    private var heroTokensText: String { heroTokenCount.formatAsTokens() }

    private var heroCostText: String {
        if let snap = communityStore.shareSnapshot, snap.revoked != true {
            return String(format: "$%.2f", snap.usage(for: communityStore.selectedWindow).costUSD)
        }
        let key: RollupWindowKey = {
            switch communityStore.selectedWindow {
            case .today: .today
            case .sevenDay: .sevenDays
            case .thirtyDay: .thirtyDays
            case .ninetyDay: .ninetyDays
            case .allTime: .allTime
            }
        }()
        let cost = dashboard.windowTotals[key]?.costUsd ?? 0
        return String(format: "$%.2f", cost)
    }

    private var heroModelMixText: String {
        let top = modelSummaries.prefix(2).map(\.model).joined(separator: ", ")
        return top.isEmpty ? "—" : top
    }

    private var heroTrendDelta: String? {
        guard dashboard.dailyPoints.count >= 2 else { return nil }
        let last = dashboard.dailyPoints.suffix(2)
        let a = Double(last.first?.tokens ?? 0)
        let b = Double(last.last?.tokens ?? 0)
        guard a > 0 else { return nil }
        let pct = ((b - a) / a) * 100
        return String(format: "%+.0f%% vs prior day", pct)
    }

    private let leaderboardTierOrder: [FirestoreGeographyTier] = [.city, .region, .country, .world]

    private func metaChip(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(CommunityEditorialTypography.metaStrip)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text(value)
                .font(CommunityEditorialTypography.instrument)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
        }
    }

    private func percentileCell(_ label: String, _ value: Double) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(CommunityEditorialTypography.metaStrip)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text(formatPercentile(value))
                .font(CommunityEditorialTypography.instrument)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatPercentile(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", value / 1_000) }
        return String(format: "%.0f", value)
    }

    private func youStandCopy(resolved: (tier: FirestoreGeographyTier, doc: FirestoreCommunityLeaderboardDoc)) -> String {
        let tokens = Double(heroTokenCount)
        let p50 = resolved.doc.percentiles.p50
        if tokens >= resolved.doc.percentiles.p99 { return "You're above p99 for \(resolved.tier.rawValue)." }
        if tokens >= resolved.doc.percentiles.p90 { return "You're above p90 for \(resolved.tier.rawValue)." }
        if tokens >= p50 { return "You're above median (p50) for \(resolved.tier.rawValue)." }
        return "You're below median (p50) for \(resolved.tier.rawValue)."
    }

    private func peerBars(user: Double, p50: Double, p75: Double, p90: Double) -> some View {
        let maxVal = max(user, p50, p75, p90, 1)
        return VStack(alignment: .leading, spacing: 8) {
            peerBarRow("You", user / maxVal, MobileTheme.ember)
            peerBarRow("p50", p50 / maxVal, MobileTheme.Colors.textMuted)
            peerBarRow("p75", p75 / maxVal, MobileTheme.Colors.textMuted.opacity(0.8))
            peerBarRow("p90", p90 / maxVal, MobileTheme.Colors.textMuted.opacity(0.6))
        }
    }

    private func peerBarRow(_ label: String, fraction: Double, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(CommunityEditorialTypography.metaStrip)
                .frame(width: 32, alignment: .leading)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color)
                    .frame(width: geo.size.width * CGFloat(fraction))
            }
            .frame(height: 8)
        }
    }

    private func reload() async {
        await communityStore.refresh(uid: authStore?.currentIdentity?.uid)
        if dashboard.windowTotals.isEmpty {
            await dashboard.load()
        }
    }
}

private struct SafariLinkSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Your Looking Glass export is ready.")
                    .font(MobileTheme.Typography.headline)
                Link("Open download link", destination: url)
                    .font(MobileTheme.Typography.body)
                Text(url.absoluteString)
                    .font(CommunityEditorialTypography.metaStrip)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

