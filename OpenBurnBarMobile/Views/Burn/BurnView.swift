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
                        fleetHeroCard
                        if !quotaStore.urgentProviders.isEmpty {
                            urgentBanner
                        }
                        periodSelector
                        providerStack
                        if !dashboard.dailyPoints.isEmpty {
                            chartCard
                        }
                    }
                }
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
                .padding(.bottom, 100) // clear the tab tray
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
                        routingState: quotaStore.routingState(for: ProviderID(rawValue: providerKey)),
                        onRefresh: {
                            await quotaStore.refreshAllAccounts(for: ProviderID(rawValue: providerKey))
                        }
                    )
                }
                .presentationDetents([.large, .medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Hero

    /// New Burn hero: a single readable card with the fleet score on the
    /// left, top-3 provider rings on the right, and a clear "tap a chip
    /// to drill in" affordance. Replaces the old overlapping constellation.
    @ViewBuilder
    private var fleetHeroCard: some View {
        AuroraGlassCard(variant: heroVariant, cornerRadius: AuroraDesign.Shape.heroCorner, padding: AuroraDesign.Layout.heroPadding) {
            if quotaItems.isEmpty {
                AuroraStatePane(
                    kind: quotaStore.error == nil ? .empty : .error,
                    icon: quotaStore.error == nil ? "gauge.with.dots.needle.bottom.50percent" : "exclamationmark.icloud.fill",
                    title: quotaStore.error == nil ? "No quota signal yet" : "Quota sync error",
                    message: quotaEmptyMessage
                )
                .frame(height: 220)
            } else {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    fleetHeroTopRow
                    Divider()
                        .background(MobileTheme.Colors.borderSubtle.opacity(0.5))
                    providerRingStrip
                }
            }
        }
    }

    private var fleetHeroTopRow: some View {
        let avg = fleetHealthRatio
        let pct = Int((avg * 100).rounded())
        let pressureCount = quotaStore.urgentProviders.count
        let healthLabel: String = {
            if avg >= 0.6 { return "Healthy" }
            if avg >= 0.3 { return "Pressured" }
            return "Critical"
        }()
        return HStack(alignment: .center, spacing: MobileTheme.Spacing.lg) {
            // Left: large readable fleet ring
            FleetHealthRing(progress: avg, accent: fleetAccent)
                .frame(width: 96, height: 96)

            // Right: title block
            VStack(alignment: .leading, spacing: 6) {
                Text("FLEET QUOTA")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(1.6)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(pct)%")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(MobileTheme.primaryGradient)
                        .contentTransition(.numericText())
                    Text(healthLabel)
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(fleetAccent)
                }
                Text(pressureCount == 0
                     ? "All providers in the green"
                     : "\(pressureCount) under pressure")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var providerRingStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PER-PROVIDER")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(1.6)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Spacer()
                Text("Tap a ring")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(quotaItems.prefix(8)) { item in
                        Button {
                            sheetProvider = item.providerKey
                            HapticBus.sheetOpen()
                        } label: {
                            ProviderQuotaChip(item: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.label), \(Int(item.pressureRemaining * 100)) percent remaining")
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var urgentBanner: some View {
        let providers = quotaStore.urgentProviders
        AuroraGlassCard(variant: .urgent, cornerRadius: 14, padding: MobileTheme.Spacing.md) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(MobileTheme.warning.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(MobileTheme.warning)
                        .symbolEffect(.pulse, options: .repeating)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(providers.count) provider\(providers.count == 1 ? "" : "s") under pressure")
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text(providers.prefix(3).joined(separator: " · "))
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let firstUrgent = providers.first {
                    Button {
                        sheetProvider = firstUrgent
                        HapticBus.sheetOpen()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Review")
                                .font(MobileTheme.Typography.caption)
                                .fontWeight(.semibold)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(MobileTheme.warning)
                        .background(Capsule().fill(MobileTheme.warning.opacity(0.16)))
                        .overlay(Capsule().stroke(MobileTheme.warning.opacity(0.4), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var periodSelector: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RollupWindowKey.allCases, id: \.self) { key in
                        PeriodCard(
                            window: key,
                            total: dashboard.windowTotals[key],
                            displayMode: displayMode,
                            isSelected: selectedWindow == key,
                            onTap: {
                                withAnimation(AuroraDesign.Motion.auroraSnap) {
                                    selectedWindow = key
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 2)
            }
            modeToggle
        }
    }

    private var modeToggle: some View {
        Button {
            withAnimation(AuroraDesign.Motion.auroraSnap) {
                displayMode = displayMode == .currency ? .tokens : .currency
            }
            HapticBus.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(MobileTheme.ember.opacity(0.18))
                Circle()
                    .stroke(MobileTheme.ember.opacity(0.45), lineWidth: 0.5)
                Image(systemName: displayMode == .currency ? "dollarsign" : "number")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(MobileTheme.ember)
                    .symbolEffect(.bounce, value: displayMode)
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Toggle currency or tokens")
    }

    // MARK: - Hero derivations

    private var fleetHealthRatio: Double {
        guard !quotaItems.isEmpty else { return 1.0 }
        return quotaItems.map(\.pressureRemaining).reduce(0, +) / Double(quotaItems.count)
    }

    private var fleetAccent: Color {
        let avg = fleetHealthRatio
        if avg >= 0.6 { return MobileTheme.success }
        if avg >= 0.3 { return MobileTheme.warning }
        return MobileTheme.error
    }

    private var heroVariant: AuroraGlassVariant {
        let avg = fleetHealthRatio
        if avg >= 0.6 { return .success }
        if avg >= 0.3 { return .standard }
        return .urgent
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
                    kind: quotaStore.error == nil ? .empty : .error,
                    icon: quotaStore.error == nil ? "externaldrive.connected.to.line.below" : "exclamationmark.icloud.fill",
                    title: quotaStore.error == nil ? "No connected providers" : "Quota sync error",
                    message: quotaEmptyMessage
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
                                    MobileTheme.ember.opacity(0.50),
                                    MobileTheme.amber.opacity(0.18),
                                    MobileTheme.blaze.opacity(0.02)
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
                        .foregroundStyle(MobileTheme.ember)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                        .shadow(color: MobileTheme.ember.opacity(0.25), radius: 5, x: 0, y: 2)
                    }
                }
                .frame(height: 180)
                .chartBackground { chartProxy in
                    GeometryReader { geometry in
                        let frame = geometry.frame(in: .local)
                        LinearGradient(
                            colors: [
                                MobileTheme.ember.opacity(0.04),
                                MobileTheme.amber.opacity(0.02),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: max(1, dashboard.dailyPoints.count / 5))) { _ in
                        AxisValueLabel(format: .dateTime.month().day())
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(v.humanReadableNumber())
                                    .foregroundStyle(MobileTheme.Colors.textMuted)
                            }
                        }
                    }
                }
                .chartEntrance()
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
        .sorted {
            if $0.pressureRemaining != $1.pressureRemaining {
                return $0.pressureRemaining < $1.pressureRemaining
            }
            return $0.providerKey < $1.providerKey
        }
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
        // Surface providers that the user has connected as cloud accounts but
        // for which the upstream returned no usable quota signal yet (e.g.
        // MiniMax Token Plan unlimited rows, Z.ai endpoints that return zero
        // buckets). The dashboard still needs a tile for these so users can
        // confirm their key is wired up — `BurnProviderRow` already renders a
        // graceful "no signal" state when its `snapshots` list is empty.
        let connectedProviderKeys = Set(
            quotaStore.accounts
                .filter { $0.status != .deleted }
                .map(\.providerID.rawValue)
        )
        for k in connectedProviderKeys.sorted() {
            if seen.insert(k).inserted { keys.append(k) }
        }
        return keys
    }

    private var quotaEmptyMessage: String {
        let accountHint: String
        if let account = quotaStore.currentUserDisplayID, account.isEmpty == false {
            accountHint = "Signed into account \(account)."
        } else {
            accountHint = "Not signed in."
        }
        if let error = quotaStore.error {
            return "\(error)\n\(accountHint)"
        }
        return "Open the Mac app and link a provider to start tracking burn here. Make sure this iPhone is signed into the same OpenBurnBar account as your Mac.\n\(accountHint)"
    }
}

// MARK: - Fleet Health Ring

/// A single readable progress ring used in the new Burn hero. Replaces the
/// stacked constellation rings that visually collided with provider logos.
private struct FleetHealthRing: View {
    let progress: Double
    let accent: Color

    var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(MobileTheme.Colors.border.opacity(0.4), lineWidth: 9)

            // Progress arc — angular gradient from accent through warm fade
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, progress))))
                .stroke(
                    AngularGradient(
                        colors: [
                            accent,
                            accent.opacity(0.85),
                            MobileTheme.amber,
                            accent
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: accent.opacity(0.45), radius: 10)

            // Center glyph
            Image(systemName: "flame.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [accent, accent.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }
}

// MARK: - Provider Quota Chip

/// A clean, readable provider tile used in the horizontal strip on the
/// Burn hero. Logo above, percent below, tinted ring around the logo.
private struct ProviderQuotaChip: View {
    let item: QuotaRingsConstellation.Item

    private var primary: Color {
        MobileTheme.Colors.primary(for: item.provider)
    }

    private var statusColor: Color {
        let p = item.pressureRemaining
        if p < 0.25 { return MobileTheme.error }
        if p < 0.5 { return MobileTheme.warning }
        return MobileTheme.success
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Soft halo tinted by provider color
                Circle()
                    .fill(primary.opacity(0.16))
                    .frame(width: 56, height: 56)
                    .blur(radius: 4)

                // Track ring
                Circle()
                    .stroke(primary.opacity(0.18), lineWidth: 3)
                    .frame(width: 52, height: 52)

                // Progress
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(1, item.pressureRemaining))))
                    .stroke(primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 52, height: 52)
                    .shadow(color: primary.opacity(0.5), radius: 6)

                // Logo glass disc
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle().stroke(primary.opacity(0.35), lineWidth: 0.5)
                    )

                UnifiedProviderLogoView(provider: item.provider, size: 22, useFallbackColor: false)
            }

            Text("\(Int((item.pressureRemaining * 100).rounded()))%")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(statusColor)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(width: 64)
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
