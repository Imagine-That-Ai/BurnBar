import SwiftUI
import OpenBurnBarCore

#if canImport(AppKit)
import AppKit
#endif

// MARK: - SubscriptionCard
//
// Rich per-plan card that shows the provider identity, the twin arc dial, a
// readout of the dominant bucket, the source confidence, and a footer with
// actions. Tapping the card expands the full bucket breakdown using the
// existing `ProviderQuotaBucketRow`.

struct SubscriptionCard: View {
    let entry: SubscriptionEntry
    var onRefresh: () -> Void = {}
    var onTogglePin: (Bool) -> Void = { _ in }

    @State private var expanded = false
    @State private var hover = false
    @AppStorage private var isPinned: Bool

    init(
        entry: SubscriptionEntry,
        onRefresh: @escaping () -> Void = {},
        onTogglePin: @escaping (Bool) -> Void = { _ in }
    ) {
        self.entry = entry
        self.onRefresh = onRefresh
        self.onTogglePin = onTogglePin
        self._isPinned = AppStorage(wrappedValue: false, "quotaTab.pinned.\(entry.id)")
    }

    private var theme: ProviderTheme { ProviderTheme.theme(for: entry.provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            headerRow
            mainRow
            footerRow

            if expanded {
                Divider().opacity(0.4)
                VStack(spacing: DesignSystem.Spacing.md) {
                    ForEach(entry.allDisplayableBuckets) { bucket in
                        ProviderQuotaBucketRow(bucket: bucket, provider: entry.provider)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(cardBackground)
        .overlay(cardBorder)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        .shadow(
            color: hover ? theme.primaryColor.opacity(0.18) : Color.black.opacity(0.10),
            radius: hover ? 14 : 8,
            y: hover ? 5 : 3
        )
        .scaleEffect(hover ? 1.005 : 1.0)
        .onHover { hover = $0 }
        .animation(DesignSystem.Animation.hover, value: hover)
        .animation(DesignSystem.Animation.gentle, value: expanded)
        .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(entry.provider.displayName)" +
            (entry.planTierBadge.map { " \($0)" } ?? "") +
            ", \(entry.remainingPercentRounded) percent remaining" +
            (entry.nextResetDate.map { ", resets \($0.formatted(.relative(presentation: .numeric)))" } ?? "")
        )
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ProviderQuotaIdentityOrb(provider: entry.provider, isActive: entry.isRefreshing)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(entry.provider.displayName)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    if let badge = entry.planTierBadge {
                        planTierChip(badge)
                    } else if entry.allDisplayableBuckets.contains(where: \.isEstimated) {
                        QuotaMicroBadge(text: "Estimated", tint: DesignSystem.Colors.warning)
                    } else {
                        QuotaMicroBadge(text: "Active", tint: theme.primaryColor)
                    }
                }

                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text(entry.accountLabel)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let scope = entry.storageScope {
                        ProviderAccountStorageChip(scope: scope, compact: true)
                    }
                }
            }

            Spacer()

            QuotaSourceBadge(source: entry.snapshot.source, confidence: entry.snapshot.confidence)
        }
    }

    // MARK: Main

    private var mainRow: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.lg) {
            QuotaArcDial(
                outer: entry.weeklyOrMonthlyBucket ?? entry.primaryBucket,
                inner: entry.hourlyBucket,
                provider: entry.provider,
                diameter: 138
            )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                metricRow(
                    glyph: "clock.fill",
                    label: shortLabel,
                    bucket: entry.hourlyBucket,
                    fallback: "Short-window quota not exposed"
                )

                metricRow(
                    glyph: "calendar",
                    label: longLabel,
                    bucket: entry.weeklyOrMonthlyBucket,
                    fallback: "Long-window quota not exposed"
                )

                if let nextReset = entry.nextResetDate {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.primaryColor)
                        Text("Next reset \(nextReset.formatted(.relative(presentation: .numeric)))")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Text("· \(nextReset.formatted(date: .abbreviated, time: .shortened))")
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text("Reset time not published by provider.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }

                if entry.isStale {
                    QuotaMicroBadge(text: "Stale signal", tint: DesignSystem.Colors.warning)
                }

                if entry.allDisplayableBuckets.isEmpty {
                    Text(entry.snapshot.statusMessage)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func metricRow(
        glyph: String,
        label: String,
        bucket: ProviderQuotaBucket?,
        fallback: String
    ) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.primaryColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
                    .tracking(0.8)

                if let bucket {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(bucket.remainingText)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(DesignSystem.Animation.gentle, value: bucket.remainingText)
                        Text("·")
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text(bucket.usageText)
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Text(fallback)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
        }
    }

    // MARK: Footer

    private var footerRow: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Button {
                withAnimation(DesignSystem.Animation.gentle) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                    Text(bucketToggleLabel)
                        .font(DesignSystem.Typography.caption)
                }
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(entry.allDisplayableBuckets.isEmpty)
            .opacity(entry.allDisplayableBuckets.isEmpty ? 0.55 : 1)

            Spacer()

            Button {
                isPinned.toggle()
                onTogglePin(isPinned)
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPinned ? theme.primaryColor : DesignSystem.Colors.textMuted)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(
                            isPinned
                                ? theme.primaryColor.opacity(0.16)
                                : DesignSystem.Colors.surface.opacity(0.55)
                        )
                    )
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Pinned to popover" : "Pin to popover")

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(DesignSystem.Colors.surface.opacity(0.55))
                    )
                    .rotationEffect(.degrees(entry.isRefreshing ? 360 : 0))
                    .animation(
                        entry.isRefreshing
                            ? .linear(duration: 1.0).repeatForever(autoreverses: false)
                            : .default,
                        value: entry.isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .disabled(entry.isRefreshing)
            .help("Refresh quota now")

            if let url = entry.managementURL {
                Button {
                    open(url: url)
                } label: {
                    HStack(spacing: 3) {
                        Text("Manage")
                            .font(DesignSystem.Typography.caption)
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(theme.primaryColor)
                }
                .buttonStyle(.plain)
                .help("Open official quota dashboard")
            }
        }
    }

    private var bucketToggleLabel: String {
        if entry.allDisplayableBuckets.isEmpty { return "No live buckets" }
        return expanded ? "Hide buckets" : "Show all buckets (\(entry.allDisplayableBuckets.count))"
    }

    // MARK: Chrome

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.55))
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.primaryColor.opacity(0.10),
                            theme.accentColor.opacity(0.04),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [
                        theme.primaryColor.opacity(0.34),
                        theme.accentColor.opacity(0.14),
                        theme.primaryColor.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.8
            )
    }

    private func planTierChip(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(1.0)
            .foregroundStyle(theme.primaryColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill(theme.primaryColor.opacity(0.14))
            )
            .overlay(
                Capsule().stroke(theme.primaryColor.opacity(0.40), lineWidth: 0.5)
            )
    }

    private var shortLabel: String {
        switch entry.hourlyBucket?.windowKind {
        case .rollingHours: return "5-hour window"
        case .daily: return "Daily window"
        default: return "Short window"
        }
    }

    private var longLabel: String {
        switch entry.weeklyOrMonthlyBucket?.windowKind {
        case .weekly, .rollingDays: return "7-day window"
        case .monthly: return "30-day window"
        case .lifetime: return "Lifetime"
        default: return "Long window"
        }
    }

    private func open(url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - Compact list-mode row

struct SubscriptionListRow: View {
    let entry: SubscriptionEntry
    var onRefresh: () -> Void = {}

    private var theme: ProviderTheme { ProviderTheme.theme(for: entry.provider) }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ProviderQuotaIdentityOrb(provider: entry.provider, isActive: entry.isRefreshing)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(entry.provider.displayName)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    if let badge = entry.planTierBadge {
                        Text(badge.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(theme.primaryColor)
                    }
                }
                Text(entry.accountLabel)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 180, alignment: .leading)

            QuotaDualWindowStrip(
                hourlyBucket: entry.hourlyBucket,
                weeklyBucket: entry.weeklyOrMonthlyBucket,
                fallbackBucket: entry.primaryBucket,
                provider: entry.provider,
                isActive: entry.isRefreshing
            )
            .frame(maxWidth: .infinity)

            Text("\(entry.remainingPercentRounded)%")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(theme.gradient)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(theme.primaryColor.opacity(0.16), lineWidth: 0.75)
        )
    }
}
