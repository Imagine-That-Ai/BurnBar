import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Burn View
//
// Fused Quota + Usage stage. Top is the QuotaRingsConstellation, bottom is
// per-provider quota cards (expandable accordion) + a stacked-area daily
// chart of cost by provider for the selected window.

struct BurnView: View {
    var initialFocus: String?

    @State private var quotaStore = QuotaStore()
    @State private var dashboard = DashboardStore()
    @State private var displayMode: UsageDisplayMode = .currency
    @State private var selectedWindow: RollupWindowKey = .today
    @State private var expandedProvider: String?
    @State private var sheetProvider: String?

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            AuroraBackdrop()
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    if quotaStore.snapshots.isEmpty && quotaStore.isLoading {
                        skeleton
                    } else {
                        constellationCard
                        urgentBanner
                        windowSelector
                        providerStack
                        if !dashboard.dailyPoints.isEmpty {
                            chartCard
                        }
                    }
                }
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
                .padding(.bottom, MobileTheme.Spacing.xxl)
                .padding(.top, MobileTheme.Spacing.sm)
            }
            .refreshable {
                HapticBus.refreshStarted()
                await refresh()
                HapticBus.refreshFinished()
            }
        }
        .navigationTitle("Burn")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            if let initialFocus { expandedProvider = initialFocus }
            await initialLoad()
        }
        .onDisappear {
            quotaStore.stopListening()
            dashboard.stopListening()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refresh() }
        }
        .onChange(of: selectedWindow) { _, window in
            HapticBus.chipChange()
            dashboard.setWindow(window)
            Task { await dashboard.refresh() }
        }
        .onChange(of: displayMode) { _, mode in
            HapticBus.toggle()
            dashboard.setDisplayMode(mode)
            Task { await dashboard.refresh() }
        }
        .sheet(isPresented: Binding(
            get: { sheetProvider != nil },
            set: { if !$0 { sheetProvider = nil } }
        )) {
            if let providerKey = sheetProvider {
                NavigationStack {
                    QuotaDetailSheet(
                        provider: providerKey,
                        snapshots: quotaStore.sortedSnapshots(for: providerKey),
                        routingState: quotaStore.routingState(for: ProviderID(rawValue: providerKey))
                    )
                }
                .presentationDetents([.large, .medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Sections

    private var constellationCard: some View {
        AuroraGlassCard(variant: .hero, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                AuroraSection(
                    "Fleet quota",
                    subtitle: quotaStore.snapshots.isEmpty
                        ? "Connect a provider on your Mac to see quota"
                        : "Tap a ring for per-account detail",
                    accent: MobileTheme.amber
                )
                if !quotaItems.isEmpty {
                    QuotaRingsConstellation(items: quotaItems) { item in
                        sheetProvider = item.providerKey
                    }
                    .frame(height: 240)
                } else {
                    AuroraStatePane(
                        kind: .empty,
                        icon: "gauge.with.dots.needle.bottom.50percent",
                        title: "No quota signal yet",
                        message: "Connect a provider on your Mac to start tracking quota in real time."
                    )
                    .frame(height: 240)
                }
            }
        }
    }

    @ViewBuilder
    private var urgentBanner: some View {
        if !quotaStore.urgentProviders.isEmpty {
            AuroraGlassCard(variant: .urgent, cornerRadius: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(MobileTheme.warning)
                        .symbolEffect(.pulse, options: .repeating)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(quotaStore.urgentProviders.count) provider\(quotaStore.urgentProviders.count == 1 ? "" : "s") under pressure")
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text(quotaStore.urgentProviders.prefix(3).joined(separator: " · "))
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private var windowSelector: some View {
        HStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(RollupWindowKey.allCases, id: \.self) { key in
                        windowChip(key)
                    }
                }
                .padding(.horizontal, 4)
            }
            modeToggle
        }
    }

    private func windowChip(_ key: RollupWindowKey) -> some View {
        let isSelected = selectedWindow == key
        let totals = dashboard.windowTotals[key]
        return Button {
            withAnimation(AuroraDesign.Motion.auroraSnap) { selectedWindow = key }
        } label: {
            HStack(spacing: 6) {
                Text(key.displayLabel)
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                if let totals {
                    Text(displayMode == .currency
                         ? totals.costUsd.formatAsCost()
                         : totals.tokens.formatAsTokenVolume())
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? .white : MobileTheme.Colors.textSecondary)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(MobileTheme.primaryGradient)
                        : AnyShapeStyle(MobileTheme.Colors.surface.opacity(0.8))
                )
            )
            .overlay(
                Capsule().stroke(
                    isSelected ? MobileTheme.amber.opacity(0.5) : MobileTheme.Colors.border.opacity(0.4),
                    lineWidth: isSelected ? 1 : 0.5
                )
            )
        }
        .buttonStyle(.plain)
    }

    private var modeToggle: some View {
        Button {
            withAnimation(AuroraDesign.Motion.auroraSnap) {
                displayMode = displayMode == .currency ? .tokens : .currency
            }
            HapticBus.toggle()
        } label: {
            Image(systemName: displayMode == .currency ? "dollarsign.circle.fill" : "number.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(MobileTheme.ember)
                .symbolEffect(.bounce, value: displayMode)
        }
        .buttonStyle(.plain)
    }

    private var providerStack: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            AuroraSection(
                "Per-provider",
                subtitle: "Tap a card to drill into accounts and routing",
                accent: MobileTheme.ember
            )
            ForEach(allProviderKeys, id: \.self) { providerKey in
                BurnProviderRow(
                    providerKey: providerKey,
                    snapshots: quotaStore.snapshotsByProvider[providerKey] ?? [],
                    accountCount: quotaStore.accountCount(for: providerKey),
                    routingState: quotaStore.routingState(for: ProviderID(rawValue: providerKey)),
                    isExpanded: expandedProvider == providerKey,
                    onToggle: {
                        withAnimation(AuroraDesign.Motion.auroraSpring) {
                            expandedProvider = expandedProvider == providerKey ? nil : providerKey
                        }
                        HapticBus.sheetOpen()
                    },
                    onOpenDetail: { sheetProvider = providerKey }
                )
            }
            if allProviderKeys.isEmpty {
                AuroraStatePane(
                    kind: .empty,
                    icon: "externaldrive.connected.to.line.below",
                    title: "No connected providers",
                    message: "Open the Mac app and link a provider to start tracking burn here."
                )
                .frame(minHeight: 180)
            }
        }
    }

    private var chartCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                AuroraSection(
                    "Daily by provider",
                    subtitle: selectedWindow.displayLabel,
                    accent: MobileTheme.amber
                )
                Chart {
                    ForEach(dashboard.dailyPoints) { point in
                        AreaMark(
                            x: .value("Date", point.date, unit: .day),
                            y: .value("Tokens", point.value)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    MobileTheme.ember.opacity(0.45),
                                    MobileTheme.amber.opacity(0.04)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                        LineMark(
                            x: .value("Date", point.date, unit: .day),
                            y: .value("Tokens", point.value)
                        )
                        .foregroundStyle(MobileTheme.primaryGradient)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                    }
                }
                .frame(height: 180)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: max(1, dashboard.dailyPoints.count / 5))) { _ in
                        AxisValueLabel(format: .dateTime.month().day())
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel().foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
            }
        }
    }

    private var skeleton: some View {
        VStack(spacing: 12) {
            AuroraLoadingShimmer(height: 240, cornerRadius: 22)
            AuroraLoadingShimmer(height: 60, cornerRadius: 14)
            AuroraLoadingShimmer(height: 100, cornerRadius: 16)
            AuroraLoadingShimmer(height: 100, cornerRadius: 16)
        }
    }

    // MARK: - Loading

    private func initialLoad() async {
        async let q: Void = quotaStore.load()
        async let d: Void = dashboard.load()
        _ = await (q, d)
        quotaStore.startListening()
    }

    private func refresh() async {
        async let q: Void = quotaStore.refresh()
        async let d: Void = dashboard.refresh()
        _ = await (q, d)
    }

    // MARK: - Derived

    private var quotaItems: [QuotaRingsConstellation.Item] {
        let grouped = quotaStore.snapshotsByProvider
        return grouped.compactMap { (key, snaps) -> QuotaRingsConstellation.Item? in
            guard let provider = AgentProvider.fromProviderID(ProviderID(rawValue: key))
                ?? AgentProvider.fromPersistedToken(key) else { return nil }
            let pressure = snaps
                .flatMap(\.buckets)
                .filter { $0.limit > 0 }
                .map { max(0, $0.remaining) / $0.limit }
                .min() ?? 1.0
            return QuotaRingsConstellation.Item(
                provider: provider,
                providerKey: key,
                pressureRemaining: pressure,
                label: provider.displayName
            )
        }
        .sorted { $0.pressureRemaining < $1.pressureRemaining }
    }

    private var allProviderKeys: [String] {
        var seen = Set<String>()
        var keys: [String] = []
        for k in quotaStore.urgentProviders {
            if seen.insert(k).inserted { keys.append(k) }
        }
        for k in quotaStore.healthyProviders {
            if seen.insert(k).inserted { keys.append(k) }
        }
        return keys
    }
}

// MARK: - Burn Provider Row (Expandable Accordion)

private struct BurnProviderRow: View {
    let providerKey: String
    let snapshots: [ProviderQuotaSnapshot]
    let accountCount: Int
    let routingState: ProviderRoutingStateSnapshot?
    let isExpanded: Bool
    let onToggle: () -> Void
    let onOpenDetail: () -> Void

    private var providerEnum: AgentProvider? {
        AgentProvider.fromProviderID(ProviderID(rawValue: providerKey))
            ?? AgentProvider.fromPersistedToken(providerKey)
    }

    private var hasUrgentBucket: Bool {
        snapshots.flatMap(\.buckets).contains { bucket in
            guard bucket.limit > 0 else { return false }
            return max(0, bucket.remaining) / bucket.limit < 0.25
        }
    }

    private var mostPressuredBucket: ProviderQuotaBucket? {
        snapshots
            .flatMap(\.buckets)
            .filter { $0.limit > 0 }
            .min {
                max(0, $0.remaining) / $0.limit < max(0, $1.remaining) / $1.limit
            } ?? snapshots.first?.buckets.first
    }

    var body: some View {
        AuroraGlassCard(
            variant: hasUrgentBucket ? .urgent : .standard,
            cornerRadius: 16
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: onToggle) {
                    headerRow
                }
                .buttonStyle(.plain)

                if let bucket = mostPressuredBucket, let providerEnum {
                    UnifiedQuotaSignalView(bucket: bucket, provider: providerEnum, compact: true)
                }

                if isExpanded {
                    expandedDetail
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            if let providerEnum {
                ProviderAuroraAvatar(provider: providerEnum, size: 44, animated: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(providerEnum?.displayName ?? providerKey)
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                HStack(spacing: 6) {
                    Text("\(accountCount) account\(accountCount == 1 ? "" : "s")")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    if hasUrgentBucket {
                        Text("· under pressure")
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.warning)
                    }
                }
            }
            Spacer()
            Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .symbolEffect(.bounce, value: isExpanded)
        }
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let providerEnum, let routingState, routingState.hasMeaningfulRoutingDetail {
                ProviderRoutingCockpit(provider: providerEnum, state: routingState, compact: true)
            }
            ForEach(snapshots, id: \.id) { snap in
                if let providerEnum {
                    snapshotRow(snapshot: snap, providerEnum: providerEnum)
                }
            }
            Button(action: onOpenDetail) {
                Label("Open full detail", systemImage: "arrow.up.right.square")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.aurora(.ghost))
        }
    }

    @ViewBuilder
    private func snapshotRow(snapshot: ProviderQuotaSnapshot, providerEnum: AgentProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.accountLabel ?? snapshot.accountID ?? "Account")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            ForEach(snapshot.buckets, id: \.name) { bucket in
                UnifiedQuotaSignalView(bucket: bucket, provider: providerEnum, compact: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.6))
        )
    }
}
