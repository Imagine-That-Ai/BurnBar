import SwiftUI
import OpenBurnBarCore

// MARK: - SubscriptionConstellationHero
//
// Editorial Observatory-style hero that opens the Quota workspace. Carries
// the eyebrow caption + 22pt headline + mono meta strip + mercury hairline
// shimmer, with a horizontal scroll of `SubscriptionOrb`s underneath that
// gives an at-a-glance constellation of plan health.
//
// Clicking an orb selects its provider — the workspace listens for taps and
// filters every downstream surface (entries grid, reset atlas, summary
// readouts) to just that provider's accounts. Tapping the same provider's
// orb again clears the filter.

struct SubscriptionConstellationHero: View {
    let entries: [SubscriptionEntry]
    let summary: QuotaWorkspaceViewModel.AggregateSummary
    var selectedProvider: AgentProvider?
    var totalProviderCount: Int
    var onOrbTap: (AgentProvider) -> Void = { _ in }
    var onClearSelection: () -> Void = {}

    private static let now = Date()

    private var isFiltered: Bool { selectedProvider != nil }

    private var headlineText: String {
        guard summary.activeCount > 0 else {
            return "Connect a plan to start tracking quota"
        }
        if let selected = selectedProvider {
            let accountWord = summary.activeCount == 1 ? "account" : "accounts"
            if summary.nearEdgeCount > 0 {
                return "\(selected.displayName) · \(summary.activeCount) \(accountWord) · \(summary.nearEdgeCount) near the edge"
            }
            return "\(selected.displayName) · \(summary.activeCount) \(accountWord) tracked"
        }
        if summary.nearEdgeCount > 0 {
            return "\(summary.activeCount) plan\(summary.activeCount == 1 ? "" : "s") tracked · \(summary.nearEdgeCount) near the edge"
        }
        if summary.narrowingCount > 0 {
            return "\(summary.wideOpenCount) of \(summary.activeCount) plans wide open · \(summary.narrowingCount) narrowing"
        }
        return "All \(summary.activeCount) plan\(summary.activeCount == 1 ? "" : "s") have headroom"
    }

    private var eyebrowText: String {
        if let selected = selectedProvider {
            return "FOCUSED · \(selected.displayName.uppercased()) · \(summary.activeCount) ACTIVE ACCOUNT\(summary.activeCount == 1 ? "" : "S")"
        }
        return "SUBSCRIPTION VAULT · \(summary.activeCount) ACTIVE PLAN\(summary.activeCount == 1 ? "" : "S")"
    }

    private var metaItems: [String] {
        var items: [String] = []
        if summary.activeCount > 0 {
            items.append("\(summary.activeCount) ACTIVE")
        } else {
            items.append("0 ACTIVE")
        }
        if let next = summary.nextResetEntry, let date = next.nextResetDate {
            items.append("NEXT RESET · \(next.provider.displayName.uppercased()) · \(date.formatted(.relative(presentation: .numeric)).uppercased())")
        }
        if let last = summary.lastSync {
            items.append("SYNC \(last.formatted(.relative(presentation: .numeric)).uppercased())")
        }
        if summary.nearEdgeCount > 0 {
            items.append("\(summary.nearEdgeCount) NEAR EDGE")
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            // Eyebrow row — surfaces selection state inline
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text(eyebrowText)
                    .font(DesignSystem.Typography.monoTiny)
                    .tracking(1.2)
                    .foregroundStyle(
                        isFiltered
                            ? DesignSystem.Colors.ember
                            : DesignSystem.Colors.textMuted
                    )

                if isFiltered {
                    Button(action: onClearSelection) {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Show all providers")
                                .font(DesignSystem.Typography.monoTiny)
                                .tracking(0.8)
                        }
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(DesignSystem.Colors.surface.opacity(0.55))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Clear provider focus")
                }

                Spacer()
            }

            // Headline
            Text(headlineText)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.numericText())
                .animation(DesignSystem.Animation.gentle, value: headlineText)

            // Meta strip
            if !metaItems.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(metaItems.enumerated()), id: \.offset) { idx, item in
                        if idx > 0 {
                            Text("·")
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.6))
                        }
                        Text(item)
                            .font(DesignSystem.Typography.monoTiny)
                            .tracking(0.8)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .truncationMode(.tail)
            }

            // Mercury hairline
            mercuryHairline
                .frame(height: 1)
                .padding(.top, 2)

            // Orb constellation — derived from the unfiltered provider set so
            // every chip stays visible while one is selected (the user needs
            // a way to pivot, not just clear).
            if !providerChipEntries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignSystem.Spacing.md) {
                        ForEach(providerChipEntries, id: \.id) { entry in
                            SubscriptionOrb(
                                entry: entry,
                                isSelected: selectedProvider == entry.provider,
                                isDimmed: isFiltered && selectedProvider != entry.provider,
                                onTap: { onOrbTap(entry.provider) }
                            )
                        }
                    }
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .padding(.horizontal, 2)
                }
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One orb per provider. When a provider has multiple accounts, the orb
    /// represents the worst-pressured account so the constellation telegraphs
    /// the true health of that provider's footprint.
    private var providerChipEntries: [SubscriptionEntry] {
        var byProvider: [AgentProvider: SubscriptionEntry] = [:]
        for entry in entries {
            if let existing = byProvider[entry.provider] {
                if entry.pressure > existing.pressure {
                    byProvider[entry.provider] = entry
                }
            } else {
                byProvider[entry.provider] = entry
            }
        }
        return byProvider.values.sorted { lhs, rhs in
            if lhs.pressure != rhs.pressure { return lhs.pressure > rhs.pressure }
            return lhs.provider.displayName
                .localizedCaseInsensitiveCompare(rhs.provider.displayName) == .orderedAscending
        }
    }

    private var mercuryHairline: some View {
        LinearGradient(
            colors: [
                DesignSystem.Colors.hermesMercury.opacity(0.0),
                DesignSystem.Colors.hermesMercury.opacity(0.75),
                DesignSystem.Colors.hermesAureate.opacity(0.85),
                DesignSystem.Colors.hermesMercury.opacity(0.75),
                DesignSystem.Colors.hermesMercury.opacity(0.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - SubscriptionOrb

private struct SubscriptionOrb: View {
    let entry: SubscriptionEntry
    var isSelected: Bool = false
    var isDimmed: Bool = false
    var onTap: () -> Void = {}

    @State private var animateRing = false
    @State private var hover = false

    private var theme: ProviderTheme { ProviderTheme.theme(for: entry.provider) }
    private var remainingFraction: Double {
        guard entry.primaryDisplayableBucket != nil else { return 0 }
        return max(0, min(1, 1 - entry.pressure))
    }
    private var ringColor: Color {
        guard entry.primaryDisplayableBucket != nil else {
            return DesignSystem.Colors.textMuted
        }
        switch remainingFraction {
        case 0.75...: return theme.primaryColor
        case 0.50..<0.75: return theme.primaryColor.opacity(0.78)
        case 0.25..<0.50: return DesignSystem.Colors.amber
        default: return DesignSystem.Colors.warning
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: DesignSystem.Spacing.xs) {
                ZStack {
                    // Outer halo when selected
                    if isSelected {
                        Circle()
                            .stroke(ringColor.opacity(0.50), lineWidth: 1.5)
                            .frame(width: 64, height: 64)
                            .shadow(color: ringColor.opacity(0.45), radius: 8, y: 0)
                            .transition(.scale.combined(with: .opacity))
                    }

                    Circle()
                        .stroke(DesignSystem.Colors.surfaceElevated.opacity(0.85), lineWidth: 3)
                        .frame(width: 54, height: 54)

                    Circle()
                        .trim(from: 0, to: animateRing ? remainingFraction : 0)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 54, height: 54)
                        .shadow(color: ringColor.opacity(isSelected ? 0.50 : 0.30), radius: isSelected ? 6 : 4, y: 0)

                    ProviderQuotaIdentityOrb(provider: entry.provider, isActive: entry.isRefreshing)
                        .scaleEffect(hover ? 1.08 : 1.0)
                }
                .frame(width: 64, height: 64)
                .offset(y: hover ? -4 : 0)

                VStack(spacing: 1) {
                    Text(entry.provider.displayName)
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(
                            isSelected
                                ? DesignSystem.Colors.textPrimary
                                : DesignSystem.Colors.textSecondary
                        )
                        .lineLimit(1)
                        .frame(maxWidth: 80)
                    Text(entry.remainingPercentText)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(ringColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isDimmed ? 0.38 : 1.0)
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .onAppear {
            guard !animateRing else { return }
            withAnimation(.easeOut(duration: 0.55).delay(0.05)) {
                animateRing = true
            }
        }
        .onHover { hover = $0 }
        .animation(DesignSystem.Animation.hover, value: hover)
        .animation(DesignSystem.Animation.gentle, value: isSelected)
        .animation(DesignSystem.Animation.gentle, value: isDimmed)
        .help(tooltipText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            entry.primaryDisplayableBucket == nil
                ? "\(entry.provider.displayName), quota signal unavailable"
                : "\(entry.provider.displayName), \(entry.remainingPercentText) remaining"
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isSelected ? "Tap to clear focus" : "Tap to focus on this provider")
    }

    private var tooltipText: String {
        var lines: [String] = ["\(entry.provider.displayName) — \(entry.accountLabel)"]
        if let bucket = entry.weeklyOrMonthlyBucket ?? entry.primaryDisplayableBucket {
            lines.append("\(bucket.label): \(bucket.remainingText) left")
        } else {
            lines.append(entry.snapshot.statusMessage)
        }
        if let reset = entry.nextResetDate {
            lines.append("Resets \(reset.formatted(.relative(presentation: .numeric)))")
        }
        lines.append(isSelected ? "Click to clear focus" : "Click to focus on \(entry.provider.displayName)")
        return lines.joined(separator: "\n")
    }
}
