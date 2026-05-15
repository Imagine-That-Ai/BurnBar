import SwiftUI

// MARK: - Mission Console Hero
//
// The console's top strip. Editorial language borrowed from `IntelligenceBriefView`:
//   • Eyebrow (mono, 2pt tracking): "MISSION · CONTROL"
//   • Display headline (rounded heavy, kern -0.6): "Mission Console"
//   • Mercury hairline (shimmers once on appear, then settles)
//   • Mono meta strip: in-flight · queued · burn today · runtimes online

public struct MissionConsoleHero: View {
    public let health: MissionConsoleSystemHealth
    public let activeMissionCount: Int
    public let approvalPendingCount: Int
    public let blockedCount: Int
    public let burnPerHourUSD: Double
    public let hasCompletedSinceLastOpen: Bool
    public let onDismiss: (() -> Void)?

    @State private var hairlineShimmered = false
    @State private var heroAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        health: MissionConsoleSystemHealth,
        activeMissionCount: Int,
        approvalPendingCount: Int,
        blockedCount: Int,
        burnPerHourUSD: Double,
        hasCompletedSinceLastOpen: Bool,
        onDismiss: (() -> Void)? = nil
    ) {
        self.health = health
        self.activeMissionCount = activeMissionCount
        self.approvalPendingCount = approvalPendingCount
        self.blockedCount = blockedCount
        self.burnPerHourUSD = burnPerHourUSD
        self.hasCompletedSinceLastOpen = hasCompletedSinceLastOpen
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.lg) {
                gauge

                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                    eyebrow
                    headline
                    subtitle
                }

                Spacer(minLength: 0)

                if let onDismiss {
                    closeButton(action: onDismiss)
                }
            }

            mercuryHairline

            metaStrip
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.xl)
        .padding(.vertical, UnifiedDesignSystem.Spacing.lg)
        .opacity(heroAppeared ? 1 : 0)
        .offset(y: heroAppeared ? 0 : 8)
        .animation(UnifiedDesignSystem.Animation.gentle, value: heroAppeared)
        .onAppear {
            heroAppeared = true
            guard !reduceMotion else { return }
            // One-shot shimmer to confirm "live"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.linear(duration: 1.6)) {
                    hairlineShimmered = true
                }
            }
        }
    }

    // MARK: Pieces

    private var gauge: some View {
        MissionFABGauge(configuration: MissionFABGauge.Configuration(
            size: .hero,
            activeMissionCount: activeMissionCount,
            approvalPendingCount: approvalPendingCount,
            blockedCount: blockedCount,
            hasCompletedSinceLastOpen: hasCompletedSinceLastOpen,
            burnSweep: burnSweep,
            burnPerHourUSD: burnPerHourUSD,
            macOnline: health.daemonState != .macOffline
        ))
    }

    private var burnSweep: Double {
        // 1 USD/hr = a third of the dial, $3/hr = full sweep.
        min(1.0, burnPerHourUSD / 3.0)
    }

    private var eyebrow: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: "scope")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.ember)
            Text("MISSION · CONTROL")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(2.8)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            if health.daemonState == .macOffline {
                Text("· MAC OFFLINE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(UnifiedDesignSystem.Colors.warning)
            } else if health.daemonState == .stale {
                Text("· STALE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
        }
    }

    private var headline: some View {
        Text(headlineText)
            .font(.system(size: 32, weight: .heavy, design: .rounded))
            .kerning(-0.6)
            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
            .lineLimit(2)
    }

    private var headlineText: String {
        if approvalPendingCount > 0 {
            return "Approval awaits the captain."
        }
        if blockedCount > 0 {
            return "A run is wedged. Look here."
        }
        if activeMissionCount > 0 {
            return activeMissionCount == 1
                ? "1 mission in flight."
                : "\(activeMissionCount) missions in flight."
        }
        if hasCompletedSinceLastOpen {
            return "All clear. Pick the next one."
        }
        return "Compose a mission."
    }

    private var subtitle: some View {
        Text(subtitleText)
            .font(UnifiedDesignSystem.Typography.body)
            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var subtitleText: String {
        if let last = health.lastRefresh {
            let rel = MissionConsoleFormatting.relativeTime(last)
            return "Today's burn \(MissionConsoleFormatting.cost(health.burnTodayUSD)) · \(health.onlineRuntimes)/\(health.totalRuntimes) runtimes awake · runtime snapshot \(rel)."
        }
        return "Daemon snapshot not yet observed — refresh when you're ready."
    }

    private var mercuryHairline: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6))
                    .frame(height: 1)
                Capsule()
                    .fill(UnifiedDesignSystem.mercuryGradient)
                    .frame(width: max(40, width * 0.22), height: 1.5)
                    .offset(x: hairlineShimmered ? width - max(40, width * 0.22) : 0)
                    .opacity(hairlineShimmered ? 0.0 : 0.95)
                    .blendMode(.plusLighter)
            }
        }
        .frame(height: 2)
    }

    private var metaStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: UnifiedDesignSystem.Spacing.lg) {
                metaCell(label: "IN FLIGHT", value: "\(activeMissionCount)", tint: UnifiedDesignSystem.Colors.amber)
                metaCell(label: "QUEUED", value: "\(health.queuedMissions)", tint: UnifiedDesignSystem.Colors.textSecondary)
                metaCell(label: "BURN / HR", value: MissionConsoleFormatting.cost(burnPerHourUSD, precise: burnPerHourUSD < 1), tint: burnPerHourUSD > 1.5 ? UnifiedDesignSystem.Colors.ember : UnifiedDesignSystem.Colors.textPrimary)
                metaCell(label: "BURN TODAY", value: MissionConsoleFormatting.cost(health.burnTodayUSD), tint: UnifiedDesignSystem.Colors.textPrimary)
                metaCell(label: "RUNTIMES", value: "\(health.onlineRuntimes)/\(health.totalRuntimes)", tint: UnifiedDesignSystem.Colors.hermesAureate)
                if blockedCount > 0 {
                    metaCell(label: "BLOCKED", value: "\(blockedCount)", tint: UnifiedDesignSystem.Colors.ember)
                }
                if approvalPendingCount > 0 {
                    metaCell(label: "APPROVALS", value: "\(approvalPendingCount)", tint: UnifiedDesignSystem.Colors.hermesAureate)
                }
            }
            .padding(.trailing, UnifiedDesignSystem.Spacing.xl)
        }
    }

    private func metaCell(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Text(value)
                .font(UnifiedDesignSystem.Typography.mono)
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .animation(UnifiedDesignSystem.Animation.gentle, value: value)
        }
    }

    private func closeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.7))
                )
                .overlay(
                    Circle().stroke(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.7), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Mission Console")
    }
}
