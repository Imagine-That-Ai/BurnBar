import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Mission FAB (macOS)
//
// The dashboard-corner trigger for the Mission Control Console. Wraps the
// shared `MissionFABGauge` (the living-gauge face) in macOS chrome:
//   • Ambient ring glow tinted by gauge state
//   • Hover-peek popover with the top in-flight mission + a "compose" CTA
//   • Soft drop shadow that lifts on hover
//
// The FAB doesn't own the host — it takes an `@Bindable` reference so the
// gauge re-renders as the underlying snapshot mutates.

struct MissionFAB: View {
    @Bindable var host: MissionConsoleMacHost
    var onOpenConsole: () -> Void

    @State private var isHovering = false
    @State private var appeared = false

    private let diameter: CGFloat = 56

    var body: some View {
        Button(action: onOpenConsole) {
            ZStack {
                ambientGlow

                Circle()
                    .fill(DesignSystem.Colors.surfaceElevated)
                    .frame(width: diameter, height: diameter)
                    .overlay(
                        Circle()
                            .strokeBorder(strokeGradient, lineWidth: 1.2)
                    )
                    .shadow(color: glowColor.opacity(0.32), radius: isHovering ? 18 : 12, y: isHovering ? 8 : 5)

                MissionFABGauge(configuration: gaugeConfiguration)
                    .frame(width: diameter - 8, height: diameter - 8)
            }
            .scaleEffect(appeared ? (isHovering ? 1.03 : 1.0) : 0.001)
            .animation(DesignSystem.Animation.standard, value: appeared)
            .animation(DesignSystem.Animation.hover, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .popover(isPresented: $isHovering, attachmentAnchor: .point(.leading), arrowEdge: .trailing) {
            peekPopover
                .frame(width: 280)
        }
        .accessibilityLabel("Mission Control")
        .accessibilityHint(helpText)
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .onAppear { appeared = true }
    }

    // MARK: Decoration

    private var glowColor: Color {
        if !host.snapshot.health.daemonState.isLive { return DesignSystem.Colors.textMuted }
        if host.snapshot.approvalAsks.count > 0 { return DesignSystem.Colors.hermesAureate }
        let live = host.snapshot.activeTiles.filter { $0.phase.isLive }
        let blocked = host.snapshot.activeTiles.filter { $0.phase == .blocked }
        if !blocked.isEmpty { return DesignSystem.Colors.ember }
        if !live.isEmpty { return DesignSystem.Colors.amber }
        return DesignSystem.Colors.ember
    }

    private var strokeGradient: LinearGradient {
        LinearGradient(
            colors: [
                glowColor.opacity(0.85),
                glowColor.opacity(0.45)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var ambientGlow: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [glowColor.opacity(0.55), glowColor.opacity(0.0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: isHovering ? 38 : 28
                )
            )
            .frame(width: 96, height: 96)
            .blur(radius: 10)
            .opacity(isHovering ? 0.85 : 0.55)
            .animation(DesignSystem.Animation.hover, value: isHovering)
    }

    private var gaugeConfiguration: MissionFABGauge.Configuration {
        MissionFABGauge.Configuration(
            size: .standard,
            activeMissionCount: host.snapshot.activeTiles.filter { $0.phase.isLive }.count,
            approvalPendingCount: host.snapshot.approvalAsks.count,
            blockedCount: host.snapshot.activeTiles.filter { $0.phase == .blocked }.count,
            hasCompletedSinceLastOpen: host.snapshot.activeTiles.contains { $0.phase == .completed },
            burnSweep: min(1.0, host.snapshot.health.burnPerHourUSD / 3.0),
            burnPerHourUSD: host.snapshot.health.burnPerHourUSD,
            macOnline: host.snapshot.health.daemonState != .macOffline
        )
    }

    private var helpText: String {
        if host.snapshot.approvalAsks.count > 0 {
            return "Mission Console — \(host.snapshot.approvalAsks.count) approval pending. ⇧⌘M"
        }
        let live = host.snapshot.activeTiles.filter { $0.phase.isLive }.count
        if live > 0 {
            return "Mission Console — \(live) in flight. ⇧⌘M"
        }
        return "Mission Console — compose a new mission. ⇧⌘M"
    }

    // MARK: Peek popover

    private var peekPopover: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("MISSION CONSOLE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Spacer()
                Text("⇧⌘M")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Divider().overlay(DesignSystem.Colors.borderSubtle.opacity(0.6))

            if host.snapshot.approvalAsks.isEmpty,
               let topActive = host.snapshot.activeTiles.first(where: { $0.phase.isLive }) {
                peekTile(topActive)
            } else if let ask = host.snapshot.approvalAsks.first {
                peekApproval(ask)
            } else {
                peekIdle
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                metaCell("BURN / HR",
                         value: MissionConsoleFormatting.cost(host.snapshot.health.burnPerHourUSD, precise: true))
                metaCell("BURN TODAY",
                         value: MissionConsoleFormatting.cost(host.snapshot.health.burnTodayUSD))
                metaCell("ACTIVE",
                         value: "\(host.snapshot.activeTiles.filter { $0.phase.isLive }.count)")
            }

            Button(action: onOpenConsole) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.expand.vertical")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Open Console")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DesignSystem.Colors.primaryGradient)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(DesignSystem.Spacing.md)
    }

    private func peekTile(_ tile: MissionConsoleActiveTile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.phase.displayLabel.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(DesignSystem.Colors.amber)
            Text(tile.title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(2)
            if let snippet = tile.lastEventSnippet {
                Text(snippet)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func peekApproval(_ ask: MissionConsoleApprovalAsk) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("APPROVAL · \(ask.runtimeDisplayLabel.uppercased())")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(DesignSystem.Colors.hermesAureate)
            Text(ask.title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(2)
        }
    }

    private var peekIdle: some View {
        HStack(spacing: 6) {
            Image(systemName: "compass.drawing")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text("No missions in flight. Compose one.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private func metaCell(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Daemon state helper

private extension MissionConsoleSystemHealth.DaemonState {
    var isLive: Bool { self == .live || self == .stale }
}
