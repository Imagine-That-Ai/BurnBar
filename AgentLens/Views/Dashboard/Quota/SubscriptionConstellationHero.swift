import SwiftUI

// MARK: - SubscriptionConstellationHero
//
// Editorial Observatory-style hero that opens the Quota workspace. Carries
// the eyebrow caption + 22pt headline + mono meta strip + mercury hairline
// shimmer, with a horizontal scroll of `SubscriptionOrb`s underneath that
// gives an at-a-glance constellation of plan health.

struct SubscriptionConstellationHero: View {
    let entries: [SubscriptionEntry]
    let summary: QuotaWorkspaceViewModel.AggregateSummary
    var onOrbTap: (SubscriptionEntry) -> Void = { _ in }

    private static let now = Date()

    private var headlineText: String {
        guard summary.activeCount > 0 else {
            return "Connect a plan to start tracking quota"
        }
        if summary.nearEdgeCount > 0 {
            return "\(summary.activeCount) plan\(summary.activeCount == 1 ? "" : "s") tracked · \(summary.nearEdgeCount) near the edge"
        }
        if summary.narrowingCount > 0 {
            return "\(summary.wideOpenCount) of \(summary.activeCount) plans wide open · \(summary.narrowingCount) narrowing"
        }
        return "All \(summary.activeCount) plan\(summary.activeCount == 1 ? "" : "s") have headroom"
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
            // Eyebrow
            Text("SUBSCRIPTION VAULT · \(summary.activeCount) ACTIVE PLAN\(summary.activeCount == 1 ? "" : "S")")
                .font(DesignSystem.Typography.monoTiny)
                .tracking(1.2)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            // Headline
            Text(headlineText)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

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

            // Orb constellation
            if !entries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignSystem.Spacing.md) {
                        ForEach(entries) { entry in
                            SubscriptionOrb(entry: entry)
                                .onTapGesture { onOrbTap(entry) }
                        }
                    }
                    .padding(.vertical, DesignSystem.Spacing.sm)
                }
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    @State private var animateRing = false
    @State private var hover = false

    private var theme: ProviderTheme { ProviderTheme.theme(for: entry.provider) }
    private var remainingFraction: Double {
        max(0, min(1, 1 - entry.pressure))
    }
    private var ringColor: Color {
        switch remainingFraction {
        case 0.75...: return theme.primaryColor
        case 0.50..<0.75: return theme.primaryColor.opacity(0.78)
        case 0.25..<0.50: return DesignSystem.Colors.amber
        default: return DesignSystem.Colors.warning
        }
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            ZStack {
                Circle()
                    .stroke(DesignSystem.Colors.surfaceElevated.opacity(0.85), lineWidth: 3)
                    .frame(width: 54, height: 54)

                Circle()
                    .trim(from: 0, to: animateRing ? remainingFraction : 0)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 54, height: 54)
                    .shadow(color: ringColor.opacity(0.30), radius: 4, y: 0)

                ProviderQuotaIdentityOrb(provider: entry.provider, isActive: entry.isRefreshing)
                    .scaleEffect(hover ? 1.08 : 1.0)
            }
            .frame(width: 60, height: 60)
            .offset(y: hover ? -4 : 0)

            VStack(spacing: 1) {
                Text(entry.provider.displayName)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: 80)
                Text("\(entry.remainingPercentRounded)%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(ringColor)
            }
        }
        .onAppear {
            guard !animateRing else { return }
            withAnimation(.easeOut(duration: 0.55).delay(0.05)) {
                animateRing = true
            }
        }
        .onHover { hover = $0 }
        .animation(DesignSystem.Animation.hover, value: hover)
        .help(tooltipText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.provider.displayName), \(entry.remainingPercentRounded)% remaining")
    }

    private var tooltipText: String {
        var lines: [String] = ["\(entry.provider.displayName) — \(entry.accountLabel)"]
        if let bucket = entry.weeklyOrMonthlyBucket ?? entry.primaryBucket as ProviderQuotaBucket? {
            lines.append("\(bucket.label): \(bucket.remainingText) left")
        }
        if let reset = entry.nextResetDate {
            lines.append("Resets \(reset.formatted(.relative(presentation: .numeric)))")
        }
        return lines.joined(separator: "\n")
    }
}
