import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Dashboard Root (layout switch)

/// Chooses the dashboard surface from `SettingsManager.dashboardLayout`. The main window hosts this
/// instead of `DashboardView` directly, so switching the Settings picker re-renders into the chosen
/// surface. New alternates add a `DashboardLayout` case and a branch here.
struct DashboardRootView: View {
    @Bindable var dataStore: DataStore
    var aggregator: UsageAggregator?
    var accountManager: AccountManager
    var cloudSyncService: CloudSyncService?
    var iCloudSessionMirrorService: ICloudSessionMirrorService?

    @Bindable private var settings = SettingsManager.shared

    var body: some View {
        switch settings.dashboardLayout {
        case .classic:
            DashboardView(
                dataStore: dataStore,
                aggregator: aggregator,
                accountManager: accountManager,
                cloudSyncService: cloudSyncService,
                iCloudSessionMirrorService: iCloudSessionMirrorService
            )
        case .alternate3:
            Alternate3DashboardView(
                dataStore: dataStore,
                aggregator: aggregator,
                accountManager: accountManager,
                cloudSyncService: cloudSyncService,
                iCloudSessionMirrorService: iCloudSessionMirrorService
            )
            .transition(.opacity)
        }
    }
}

// MARK: - Alternate 3 · Liquid Glass

/// A single-canvas alternate dashboard rendered on Apple's Liquid Glass material (macOS 26+, with a
/// material fallback below that). Reads the same daemon-backed data as the classic surface — totals,
/// the 7-day trail, provider spend, and live quota with its honest confidence labels intact.
struct Alternate3DashboardView: View {
    @Bindable var dataStore: DataStore
    var aggregator: UsageAggregator?
    var accountManager: AccountManager
    var cloudSyncService: CloudSyncService?
    var iCloudSessionMirrorService: ICloudSessionMirrorService?

    @Bindable private var settings = SettingsManager.shared
    @State private var quotaService = ProviderQuotaService.shared
    @State private var range: TimeRange = .today

    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        dataStore: DataStore,
        aggregator: UsageAggregator?,
        accountManager: AccountManager = .shared,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil
    ) {
        self._dataStore = Bindable(dataStore)
        self.aggregator = aggregator
        self.accountManager = accountManager
        self.cloudSyncService = cloudSyncService
        self.iCloudSessionMirrorService = iCloudSessionMirrorService
        _range = State(initialValue: SettingsManager.shared.defaultTimeRange)
    }

    private var metric: UsageDisplayMode { settings.usageDisplayMode }

    private var windowUsages: [TokenUsage] {
        dataStore.usages(in: range.dateRange())
    }

    private var windowCost: Double {
        windowUsages.reduce(0) { $0 + $1.cost }
    }

    private var windowTokens: Int {
        windowUsages.reduce(0) { $0 + $1.totalTokens }
    }

    private var providerSummaries: [ProviderSummary] {
        dataStore.providerSummaries(in: range.dateRange())
    }

    private var isScanning: Bool { aggregator?.isRefreshing ?? false }

    var body: some View {
        ZStack {
            Alt3AmbientBackdrop(moodBand: dataStore.moodBand, animated: !reduceMotion)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    Alt3HeroPanel(
                        dataStore: dataStore,
                        range: $range,
                        metric: metric,
                        windowCost: windowCost,
                        windowTokens: windowTokens,
                        isScanning: isScanning,
                        reduceTransparency: reduceTransparency,
                        namespace: glassNamespace,
                        onToggleMetric: toggleMetric,
                        onRefresh: refresh
                    )

                    Alt3QuotaRail(
                        quotaService: quotaService,
                        reduceTransparency: reduceTransparency,
                        namespace: glassNamespace
                    )

                    Alt3SpendSection(
                        summaries: providerSummaries,
                        metric: metric,
                        reduceTransparency: reduceTransparency,
                        namespace: glassNamespace
                    )

                    Alt3FooterNote()
                        .padding(.top, DesignSystem.Spacing.sm)
                }
                .padding(.horizontal, DesignSystem.Spacing.xl)
                .padding(.vertical, DesignSystem.Spacing.xxl)
                .frame(maxWidth: 1080, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
        }
        .background(DesignSystem.Colors.background)
        .animation(DesignSystem.Animation.gentle, value: range)
        .task {
            await quotaService.refreshIfNeeded(dataStore: dataStore)
        }
    }

    private func toggleMetric() {
        withAnimation(DesignSystem.Animation.standard) {
            settings.usageDisplayMode = (metric == .currency) ? .tokens : .currency
        }
    }

    private func refresh() {
        guard let aggregator else { return }
        Task { await aggregator.refreshAll() }
    }
}

// MARK: - Hero Panel

private struct Alt3HeroPanel: View {
    let dataStore: DataStore
    @Binding var range: TimeRange
    let metric: UsageDisplayMode
    let windowCost: Double
    let windowTokens: Int
    let isScanning: Bool
    let reduceTransparency: Bool
    let namespace: Namespace.ID
    let onToggleMetric: () -> Void
    let onRefresh: () -> Void

    private var bigValue: String {
        metric == .currency ? windowCost.formatAsCost() : windowTokens.formatAsTokenVolume()
    }

    private var unitCaption: String {
        let metricWord = metric == .currency ? "USD" : "TOKENS"
        return "\(metricWord) · \(range.shortLabel)"
    }

    private var trail: [Double] {
        metric == .currency ? dataStore.last7DayCosts : dataStore.last7DayTokenTotals.map(Double.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.primaryGradient)
                        Text("BurnBar")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Liquid Glass")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .padding(.horizontal, DesignSystem.Spacing.sm)
                            .padding(.vertical, 3)
                            .alt3Glass(cornerRadius: DesignSystem.Radius.full, reduceTransparency: reduceTransparency)
                    }
                    Alt3MoodPill(label: dataStore.moodLabel, color: dataStore.moodColor, isScanning: isScanning)
                }

                Spacer()

                HStack(spacing: DesignSystem.Spacing.sm) {
                    Alt3MetricToggle(metric: metric, reduceTransparency: reduceTransparency, action: onToggleMetric)
                    Alt3IconControl(
                        symbol: "arrow.clockwise",
                        spinning: isScanning,
                        reduceTransparency: reduceTransparency,
                        accessibilityLabel: "Refresh usage",
                        action: onRefresh
                    )
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.xl) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text(unitCaption)
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .tracking(1.5)

                    Text(bigValue)
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.primaryGradient)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .animation(DesignSystem.Animation.standard, value: bigValue)
                        .accessibilityLabel("\(range.displayName) burn: \(bigValue)")
                }

                Spacer(minLength: DesignSystem.Spacing.lg)

                Alt3Sparkline(values: trail)
                    .frame(width: 200, height: 64)
                    .accessibilityHidden(true)
            }

            Alt3RangeSelector(range: $range, reduceTransparency: reduceTransparency, namespace: namespace)
        }
        .padding(DesignSystem.Spacing.xl)
        .alt3Glass(
            cornerRadius: DesignSystem.Radius.xl,
            tint: DesignSystem.Colors.ember.opacity(0.10),
            reduceTransparency: reduceTransparency
        )
        .alt3MorphID("hero", in: namespace, enabled: !reduceTransparency)
    }
}

private struct Alt3MoodPill: View {
    let label: String
    let color: Color
    let isScanning: Bool

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .opacity(isScanning ? (pulse ? 0.35 : 1) : 1)
                .onAppear {
                    guard isScanning else { return }
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
                }
            Text(isScanning ? "Reading the fire…" : label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isScanning ? "Refreshing usage" : "Today is \(label)")
    }
}

// MARK: - Range selector

private struct Alt3RangeSelector: View {
    @Binding var range: TimeRange
    let reduceTransparency: Bool
    let namespace: Namespace.ID

    var body: some View {
        Alt3GlassCluster(spacing: 4, reduceTransparency: reduceTransparency) {
            HStack(spacing: 4) {
                ForEach(TimeRange.allCases) { option in
                    let selected = option == range
                    Button {
                        withAnimation(DesignSystem.Animation.standard) { range = option }
                    } label: {
                        Text(option.shortLabel)
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(selected ? .semibold : .regular)
                            .foregroundStyle(selected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                            .padding(.horizontal, DesignSystem.Spacing.md)
                            .padding(.vertical, DesignSystem.Spacing.sm)
                            .alt3Glass(
                                cornerRadius: DesignSystem.Radius.full,
                                tint: selected ? DesignSystem.Colors.ember.opacity(0.22) : nil,
                                interactive: true,
                                reduceTransparency: reduceTransparency,
                                fallbackFilled: selected
                            )
                            .alt3MorphID(selected ? "range-selected" : "range-\(option.rawValue)", in: namespace, enabled: !reduceTransparency)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.displayName)
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                }
            }
        }
    }
}

// MARK: - Metric toggle + icon control

private struct Alt3MetricToggle: View {
    let metric: UsageDisplayMode
    let reduceTransparency: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: metric == .currency ? "dollarsign.circle.fill" : "number.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(metric == .currency ? "USD" : "Tokens")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .alt3Glass(cornerRadius: DesignSystem.Radius.full, interactive: true, reduceTransparency: reduceTransparency)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Display mode: \(metric == .currency ? "US dollars" : "tokens"). Toggle.")
    }
}

private struct Alt3IconControl: View {
    let symbol: String
    var spinning: Bool = false
    let reduceTransparency: Bool
    let accessibilityLabel: String
    let action: () -> Void

    @State private var angle: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .rotationEffect(.degrees(angle))
                .frame(width: 32, height: 32)
                .alt3Glass(cornerRadius: DesignSystem.Radius.full, interactive: true, reduceTransparency: reduceTransparency)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .onChange(of: spinning) { _, isSpinning in
            if isSpinning {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { angle = 360 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { angle = 0 }
            }
        }
    }
}

// MARK: - Sparkline

private struct Alt3Sparkline: View {
    let values: [Double]

    private var normalized: [Double] {
        guard let maxV = values.max(), maxV > 0 else { return Array(repeating: 0, count: max(values.count, 1)) }
        return values.map { $0 / maxV }
    }

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if pts.count > 1 {
                    fillPath(pts, height: geo.size.height)
                        .fill(
                            LinearGradient(
                                colors: [DesignSystem.Colors.ember.opacity(0.28), DesignSystem.Colors.ember.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    linePath(pts)
                        .stroke(DesignSystem.Colors.primaryGradient, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    if let last = pts.last {
                        Circle()
                            .fill(DesignSystem.Colors.ember)
                            .frame(width: 6, height: 6)
                            .position(last)
                            .shadow(color: DesignSystem.Colors.ember.opacity(0.6), radius: 5)
                    }
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let norm = normalized
        guard norm.count > 1 else { return [] }
        let stepX = size.width / CGFloat(norm.count - 1)
        let topInset: CGFloat = 6
        let usable = size.height - topInset
        return norm.enumerated().map { idx, value in
            CGPoint(x: CGFloat(idx) * stepX, y: topInset + usable * (1 - CGFloat(value)))
        }
    }

    private func linePath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.addLine(to: p) }
        return path
    }

    private func fillPath(_ pts: [CGPoint], height: CGFloat) -> Path {
        var path = linePath(pts)
        if let last = pts.last, let first = pts.first {
            path.addLine(to: CGPoint(x: last.x, y: height))
            path.addLine(to: CGPoint(x: first.x, y: height))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Quota rail

private struct Alt3QuotaRail: View {
    @Bindable var quotaService: ProviderQuotaService
    let reduceTransparency: Bool
    let namespace: Namespace.ID

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: DesignSystem.Spacing.lg)]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Alt3SectionTitle(title: "Quota", subtitle: "What's left, and how sure we are.", symbol: "gauge.with.needle")

            Alt3GlassCluster(spacing: DesignSystem.Spacing.lg, reduceTransparency: reduceTransparency) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    ForEach(ProviderQuotaService.supportedProviders, id: \.self) { provider in
                        Alt3QuotaCard(
                            provider: provider,
                            snapshot: quotaService.snapshot(for: provider),
                            isRefreshing: quotaService.isRefreshing(provider),
                            reduceTransparency: reduceTransparency
                        )
                        .alt3MorphID("quota-\(provider.rawValue)", in: namespace, enabled: !reduceTransparency)
                    }
                }
            }
        }
    }
}

private struct Alt3QuotaCard: View {
    let provider: AgentProvider
    let snapshot: ProviderQuotaSnapshot?
    let isRefreshing: Bool
    let reduceTransparency: Bool

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }
    private var bucket: ProviderQuotaBucket? { snapshot?.primaryBucket }

    private var providerTitle: String {
        switch provider {
        case .factory: return "Factory / Droid"
        case .zai: return "Z.ai"
        default: return provider.displayName
        }
    }

    private var remainingFraction: Double? {
        guard let bucket else { return nil }
        if let pct = bucket.remainingPercent { return min(max(pct / 100, 0), 1) }
        return min(max(1 - bucket.progressFraction, 0), 1)
    }

    private var ringColor: Color {
        guard let f = remainingFraction else { return DesignSystem.Colors.textMuted }
        switch f {
        case 0.6...: return DesignSystem.Colors.success
        case 0.3..<0.6: return DesignSystem.Colors.amber
        default: return DesignSystem.Colors.ember
        }
    }

    private var cardTint: Color? {
        guard let f = remainingFraction else { return nil }
        return ringColor.opacity(f < 0.3 ? 0.16 : 0.08)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ProviderLogoView(provider: provider, size: 22, useFallbackColor: false)
                Text(providerTitle)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                if let snapshot {
                    Alt3ConfidenceBadge(source: snapshot.source, confidence: snapshot.confidence)
                }
            }

            HStack(alignment: .center, spacing: DesignSystem.Spacing.lg) {
                Alt3QuotaRing(fraction: remainingFraction, color: ringColor, isRefreshing: isRefreshing)
                    .frame(width: 78, height: 78)

                VStack(alignment: .leading, spacing: 4) {
                    if let bucket {
                        Text(bucket.label)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                        Text(bucket.remainingText)
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(ringColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(bucket.usageText)
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(isRefreshing ? "Reading…" : "No signal yet")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Text(snapshot?.summaryText ?? snapshot?.statusMessage ?? "Quota not reported.")
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            if let resetsAt = bucket?.resetsAt {
                Label("Resets \(resetsAt.formatted(.relative(presentation: .named)))", systemImage: "clock.arrow.circlepath")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alt3Glass(cornerRadius: DesignSystem.Radius.lg, tint: cardTint, reduceTransparency: reduceTransparency)
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .stroke(theme.primaryColor.opacity(0.12), lineWidth: 1)
        )
        .animation(DesignSystem.Animation.gentle, value: remainingFraction)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let bucket {
            let conf = snapshot.map { " (\($0.confidence.accessibilityWord) confidence)" } ?? ""
            return "\(providerTitle) quota: \(bucket.remainingText) remaining\(conf)."
        }
        return "\(providerTitle): \(isRefreshing ? "refreshing quota" : "no quota signal yet")."
    }
}

private struct Alt3QuotaRing: View {
    let fraction: Double?
    let color: Color
    let isRefreshing: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 8)

            if let fraction {
                Circle()
                    .trim(from: 0, to: max(fraction, 0.001))
                    .stroke(
                        AngularGradient(
                            colors: [color.opacity(0.65), color],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.45), radius: 6)

                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
            } else {
                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(
                        DesignSystem.Colors.textMuted.opacity(0.5),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round, dash: [2, 6])
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: isRefreshing ? "hourglass" : "questionmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }
}

private struct Alt3ConfidenceBadge: View {
    let source: ProviderQuotaSourceKind
    let confidence: ProviderQuotaConfidence

    private var color: Color {
        switch confidence {
        case .exact: return DesignSystem.Colors.success
        case .estimated: return DesignSystem.Colors.warning
        case .unavailable: return DesignSystem.Colors.textMuted
        }
    }

    var body: some View {
        Text(confidence.shortLabel)
            .font(DesignSystem.Typography.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.22), lineWidth: 1))
            .help("\(source.label) · \(confidence.shortLabel)")
    }
}

// MARK: - Spend section

private struct Alt3SpendSection: View {
    let summaries: [ProviderSummary]
    let metric: UsageDisplayMode
    let reduceTransparency: Bool
    let namespace: Namespace.ID

    private var maxValue: Double {
        let values = summaries.map { metric == .currency ? $0.totalCost : Double($0.totalTokens) }
        return values.max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Alt3SectionTitle(title: "Where it burns", subtitle: "Spend by provider for the selected window.", symbol: "chart.bar.fill")

            if summaries.isEmpty {
                Text("No sessions in this window yet.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.xl)
                    .alt3Glass(cornerRadius: DesignSystem.Radius.lg, reduceTransparency: reduceTransparency)
            } else {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(summaries, id: \.provider) { summary in
                        Alt3SpendRow(summary: summary, metric: metric, maxValue: maxValue)
                    }
                }
                .padding(DesignSystem.Spacing.lg)
                .alt3Glass(cornerRadius: DesignSystem.Radius.lg, reduceTransparency: reduceTransparency)
                .alt3MorphID("spend", in: namespace, enabled: !reduceTransparency)
            }
        }
    }
}

private struct Alt3SpendRow: View {
    let summary: ProviderSummary
    let metric: UsageDisplayMode
    let maxValue: Double

    private var theme: ProviderTheme { ProviderTheme.theme(for: summary.provider) }
    private var value: Double { metric == .currency ? summary.totalCost : Double(summary.totalTokens) }
    private var valueText: String {
        metric == .currency ? summary.totalCost.formatAsCost() : summary.totalTokens.formatAsTokenVolume()
    }
    private var fraction: Double {
        guard maxValue > 0 else { return 0 }
        return min(max(value / maxValue, 0), 1)
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ProviderLogoView(provider: summary.provider, size: 20, useFallbackColor: false)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(summary.provider.displayName)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(valueText)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(DesignSystem.Colors.border.opacity(0.4))
                            .frame(height: 6)
                        Capsule()
                            .fill(theme.gradient)
                            .frame(width: max(geo.size.width * fraction, fraction > 0 ? 6 : 0), height: 6)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.provider.displayName): \(valueText), \(summary.sessionCount) sessions")
    }
}

// MARK: - Section title + footer

private struct Alt3SectionTitle: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.ember)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct Alt3FooterNote: View {
    var body: some View {
        Text("Local-first · reads logs, not your keys · quota confidence shown per provider")
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Ambient backdrop

private struct Alt3AmbientBackdrop: View {
    let moodBand: MoodBand
    let animated: Bool

    @State private var drift = false

    private var blobColors: [Color] {
        switch moodBand {
        case .heavy: return [DesignSystem.Colors.ember, DesignSystem.Colors.blaze, DesignSystem.Colors.amber]
        case .light, .quiet: return [DesignSystem.Colors.whimsy, DesignSystem.Colors.ember, DesignSystem.Colors.amber]
        default: return [DesignSystem.Colors.ember, DesignSystem.Colors.amber, DesignSystem.Colors.whimsy]
        }
    }

    var body: some View {
        ZStack {
            DesignSystem.Colors.background

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    blob(blobColors[0], size: w * 0.7)
                        .offset(x: drift ? -w * 0.18 : -w * 0.28, y: drift ? -h * 0.22 : -h * 0.12)
                    blob(blobColors[1], size: w * 0.6)
                        .offset(x: drift ? w * 0.30 : w * 0.20, y: drift ? -h * 0.05 : h * 0.05)
                    blob(blobColors[2], size: w * 0.55)
                        .offset(x: drift ? w * 0.05 : w * 0.15, y: drift ? h * 0.30 : h * 0.22)
                }
                .frame(width: w, height: h)
                .blur(radius: 90)
                .opacity(0.4)
            }
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(0.5), color.opacity(0)], center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
    }
}

// MARK: - Liquid Glass helpers (macOS 26+ with material fallback)

private extension View {
    /// Applies Apple's Liquid Glass on macOS 26+, an ultra-thin material below that, and an opaque
    /// surface when Reduce Transparency is on. `fallbackFilled` gives selected controls a visible
    /// tint on the material/solid paths where glass tint is unavailable.
    @ViewBuilder
    func alt3Glass(
        cornerRadius: CGFloat,
        tint: Color? = nil,
        interactive: Bool = false,
        reduceTransparency: Bool,
        fallbackFilled: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            self
                .background(DesignSystem.Colors.surfaceElevated, in: shape)
                .background((fallbackFilled ? (tint ?? DesignSystem.Colors.ember.opacity(0.18)) : Color.clear), in: shape)
                .overlay(shape.stroke(DesignSystem.Colors.border.opacity(0.6), lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            switch (tint, interactive) {
            case let (.some(t), true):
                self.glassEffect(.regular.tint(t).interactive(), in: shape)
            case (.none, true):
                self.glassEffect(.regular.interactive(), in: shape)
            case let (.some(t), false):
                self.glassEffect(.regular.tint(t), in: shape)
            case (.none, false):
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background((fallbackFilled ? (tint ?? DesignSystem.Colors.ember.opacity(0.18)) : (tint ?? Color.clear)), in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.75))
        }
    }

    /// Groups glass elements so they share a sampling region (macOS 26+); a plain passthrough below.
    @ViewBuilder
    func alt3MorphID(_ id: String, in namespace: Namespace.ID, enabled: Bool) -> some View {
        if enabled, #available(macOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

/// Wraps grouped glass elements in a `GlassEffectContainer` on macOS 26+, passing content through
/// unchanged otherwise (including when Reduce Transparency is on).
private struct Alt3GlassCluster<Content: View>: View {
    let spacing: CGFloat
    let reduceTransparency: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if !reduceTransparency, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Local label helpers

private extension TimeRange {
    var shortLabel: String {
        switch self {
        case .today: return "TODAY"
        case .last7Days: return "7D"
        case .last30Days: return "30D"
        case .thisMonth: return "MONTH"
        case .allTime: return "ALL"
        }
    }
}

private extension ProviderQuotaConfidence {
    var shortLabel: String {
        switch self {
        case .exact: return "exact"
        case .estimated: return "estimated"
        case .unavailable: return "unavailable"
        }
    }

    var accessibilityWord: String { shortLabel }
}

#Preview("Alternate 3 · Liquid Glass") {
    Alternate3DashboardView(dataStore: DataStore(), aggregator: nil)
        .frame(width: 1000, height: 760)
}
