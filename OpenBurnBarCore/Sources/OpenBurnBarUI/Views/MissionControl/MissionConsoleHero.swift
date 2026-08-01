import SwiftUI
import OpenBurnBarKernel

// MARK: - Mission Console Header
//
// Slim top bar for the console. Two lines:
//   1. "Mission Control" title + daemon state pill (when degraded) + close.
//   2. One live status line — a green/amber/red pulse dot followed by plain
//      segments: in-flight, approvals, blocked, burn, runtimes, last refresh.
//
// The old editorial hero (display headline, gauge, shimmer hairline, mono
// stat grid) is gone: the status line says the same things in one glance and
// pending approvals are surfaced as actionable cards directly below.

public struct MissionConsoleHeader: View {
    public let health: MissionConsoleSystemHealth
    public let activeMissionCount: Int
    public let approvalPendingCount: Int
    public let blockedCount: Int
    public let onDismiss: (() -> Void)?

    public init(
        health: MissionConsoleSystemHealth,
        activeMissionCount: Int,
        approvalPendingCount: Int,
        blockedCount: Int,
        onDismiss: (() -> Void)? = nil
    ) {
        self.health = health
        self.activeMissionCount = activeMissionCount
        self.approvalPendingCount = approvalPendingCount
        self.blockedCount = blockedCount
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Text("Mission Control")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                if health.daemonState == .macOffline {
                    statePill("Mac offline", tint: UnifiedDesignSystem.Colors.warning)
                } else if health.daemonState == .stale {
                    statePill("Stale", tint: UnifiedDesignSystem.Colors.textMuted)
                }

                Spacer(minLength: 0)

                if let onDismiss {
                    closeButton(action: onDismiss)
                }
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                    .padding(.top, 1)
                Text(statusLine)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)
        .padding(.vertical, UnifiedDesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Status line

    private var statusDotColor: Color {
        switch health.daemonState {
        case .live:       return UnifiedDesignSystem.Colors.success
        case .stale:      return UnifiedDesignSystem.Colors.warning
        case .macOffline: return UnifiedDesignSystem.Colors.error
        case .unknown:    return UnifiedDesignSystem.Colors.textMuted
        }
    }

    private var statusLine: String {
        var segments: [String] = []

        if activeMissionCount > 0 {
            segments.append(activeMissionCount == 1 ? "1 in flight" : "\(activeMissionCount) in flight")
        } else {
            segments.append("No missions in flight")
        }
        if approvalPendingCount > 0 {
            segments.append(approvalPendingCount == 1 ? "1 needs approval" : "\(approvalPendingCount) need approval")
        }
        if blockedCount > 0 {
            segments.append(blockedCount == 1 ? "1 blocked" : "\(blockedCount) blocked")
        }
        if health.burnPerHourUSD > 0 {
            segments.append("\(MissionConsoleFormatting.cost(health.burnPerHourUSD, precise: health.burnPerHourUSD < 1))/hr")
        }
        if health.burnTodayUSD > 0 {
            segments.append("\(MissionConsoleFormatting.cost(health.burnTodayUSD)) today")
        }
        if health.totalRuntimes > 0 {
            segments.append("\(health.onlineRuntimes)/\(health.totalRuntimes) runtimes online")
        }
        if let last = health.lastRefresh {
            segments.append("updated \(MissionConsoleFormatting.relativeTime(last))")
        }
        return segments.joined(separator: " · ")
    }

    // MARK: Pieces

    private func statePill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(tint.opacity(0.14))
            }
    }

    private func closeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(UnifiedDesignSystem.Colors.surfaceElevated))
                .overlay(Circle().stroke(MissionChrome.hairlineColor, lineWidth: MissionChrome.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Mission Control")
    }
}
