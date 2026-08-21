import SwiftUI
import OpenBurnBarRecap
import OpenBurnBarKernel

// MARK: - Mission Situation Room
//
// The console's live view. Sections, in priority order:
//   • Approvals — pending asks with Reject / Approve actions
//   • Active — one tile per mission in flight
//   • Activity — the last few events, terminal-style
//
// All pieces accept plain value types so the room previews without the host.
// `includeApprovals` lets the compact layout hoist the approvals section to
// the top of the page while the regular layout keeps it here.

public struct MissionSituationRoom: View {
    public let activeTiles: [MissionConsoleActiveTile]
    public let recentTicker: [MissionConsoleTickerEntry]
    public let approvalAsks: [MissionConsoleApprovalAsk]
    public let burnPerHourUSD: Double
    public let burnTodayUSD: Double
    public let lastDispatchedMissionID: String?
    public let macOnline: Bool
    public let includeApprovals: Bool
    public let onApprove: (MissionConsoleApprovalAsk, Bool) -> Void

    public init(
        activeTiles: [MissionConsoleActiveTile],
        recentTicker: [MissionConsoleTickerEntry],
        approvalAsks: [MissionConsoleApprovalAsk],
        burnPerHourUSD: Double,
        burnTodayUSD: Double,
        lastDispatchedMissionID: String?,
        macOnline: Bool,
        includeApprovals: Bool = true,
        onApprove: @escaping (MissionConsoleApprovalAsk, Bool) -> Void
    ) {
        self.activeTiles = activeTiles
        self.recentTicker = recentTicker
        self.approvalAsks = approvalAsks
        self.burnPerHourUSD = burnPerHourUSD
        self.burnTodayUSD = burnTodayUSD
        self.lastDispatchedMissionID = lastDispatchedMissionID
        self.macOnline = macOnline
        self.includeApprovals = includeApprovals
        self.onApprove = onApprove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xl) {
            if !macOnline {
                macOfflineBanner
            }

            if includeApprovals && !approvalAsks.isEmpty {
                MissionApprovalsSection(approvalAsks: approvalAsks, onApprove: onApprove)
            }

            activeSection
            activitySection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Mac offline banner

    private var macOfflineBanner: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("No Mac claimed the queue")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Text("Open BurnBar on the paired Mac to start execution.")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: MissionChrome.cardCorner, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.warning.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: MissionChrome.cardCorner, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.warning.opacity(0.4), lineWidth: MissionChrome.hairline)
        }
    }

    // MARK: Active missions

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            MissionSectionHeader(
                title: "Active",
                trailing: activeTiles.isEmpty ? nil : "\(activeTiles.count) in flight"
            )

            if activeTiles.isEmpty {
                MissionConsoleCard {
                    HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                        Image(systemName: "moon.zzz")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        Text("Nothing in flight. Dispatch a mission to fill the lane.")
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(UnifiedDesignSystem.Spacing.md)
                }
            } else {
                VStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                    ForEach(Array(activeTiles.prefix(4))) { tile in
                        MissionActiveTile(
                            tile: tile,
                            isFreshDispatch: tile.id == lastDispatchedMissionID
                        )
                    }
                }
            }
        }
    }

    // MARK: Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            MissionSectionHeader(title: "Activity")
            MissionActivityTicker(entries: recentTicker)
        }
    }
}

// MARK: - Approvals Section

public struct MissionApprovalsSection: View {
    public let approvalAsks: [MissionConsoleApprovalAsk]
    public let onApprove: (MissionConsoleApprovalAsk, Bool) -> Void

    public init(
        approvalAsks: [MissionConsoleApprovalAsk],
        onApprove: @escaping (MissionConsoleApprovalAsk, Bool) -> Void
    ) {
        self.approvalAsks = approvalAsks
        self.onApprove = onApprove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            MissionSectionHeader(
                title: "Approvals",
                trailing: approvalAsks.count == 1 ? "1 waiting" : "\(approvalAsks.count) waiting",
                trailingTint: UnifiedDesignSystem.Colors.warning
            )
            VStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                ForEach(approvalAsks) { ask in
                    MissionApprovalCard(ask: ask, onApprove: { approve in onApprove(ask, approve) })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Active Mission Tile

public struct MissionActiveTile: View {
    public let tile: MissionConsoleActiveTile
    public let isFreshDispatch: Bool

    @State private var heartbeat = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(tile: MissionConsoleActiveTile, isFreshDispatch: Bool = false) {
        self.tile = tile
        self.isFreshDispatch = isFreshDispatch
    }

    private var phaseColor: Color {
        if tile.approvalPending { return UnifiedDesignSystem.Colors.warning }
        switch tile.phase {
        case .failed, .blocked, .cancelled: return UnifiedDesignSystem.Colors.error
        case .macOffline:                   return UnifiedDesignSystem.Colors.textMuted
        case .completed:                    return UnifiedDesignSystem.Colors.success
        case .awaitingApproval:             return UnifiedDesignSystem.Colors.warning
        case .queued, .starting:            return UnifiedDesignSystem.Colors.textSecondary
        case .tooling, .streaming:          return UnifiedDesignSystem.Colors.amber
        case .running, .completing:         return UnifiedDesignSystem.Colors.amber
        }
    }

    private var elapsed: TimeInterval {
        guard let started = tile.startedAt else { return 0 }
        return Date().timeIntervalSince(started)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                phasePulse
                Text(tile.phase.displayLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(phaseColor)
                Spacer(minLength: 0)
                Text(tile.runtimeDisplayLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }

            Text(tile.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let tool = tile.currentToolName {
                HStack(spacing: 4) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(tool)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(UnifiedDesignSystem.Colors.amber)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background { Capsule().fill(UnifiedDesignSystem.Colors.amber.opacity(0.12)) }
            }

            if let snippet = tile.lastEventSnippet {
                Text(snippet)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let progress = tile.progressFraction {
                ProgressView(value: progress)
                    .tint(phaseColor)
                    .frame(height: 2)
            }

            HStack(spacing: UnifiedDesignSystem.Spacing.md) {
                Text("\(MissionConsoleFormatting.duration(elapsed)) elapsed")
                Text(MissionConsoleFormatting.cost(tile.burnSoFarUSD, precise: tile.burnSoFarUSD < 1))
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: MissionChrome.cardCorner, style: .continuous)
                .fill(MissionChrome.cardFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: MissionChrome.cardCorner, style: .continuous)
                .strokeBorder(
                    isFreshDispatch ? phaseColor.opacity(0.7) : MissionChrome.hairlineColor,
                    lineWidth: isFreshDispatch ? 1 : MissionChrome.hairline
                )
        }
        .onAppear {
            guard !reduceMotion, tile.phase.isLive else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                heartbeat = true
            }
        }
    }

    private var phasePulse: some View {
        Circle()
            .fill(phaseColor)
            .frame(width: 7, height: 7)
            .overlay {
                if tile.phase.isLive {
                    Circle()
                        .stroke(phaseColor.opacity(0.5), lineWidth: 2)
                        .scaleEffect(heartbeat ? 2.2 : 1.0)
                        .opacity(heartbeat ? 0.0 : 0.8)
                }
            }
    }
}

// MARK: - Approval Card

public struct MissionApprovalCard: View {
    public let ask: MissionConsoleApprovalAsk
    public let onApprove: (Bool) -> Void

    public init(ask: MissionConsoleApprovalAsk, onApprove: @escaping (Bool) -> Void) {
        self.ask = ask
        self.onApprove = onApprove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.warning)
                Text("Approval requested")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.warning)
                Spacer(minLength: 0)
                Text(MissionConsoleFormatting.relativeTime(ask.requestedAt))
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }

            Text(ask.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(ask.message)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Text("Mission · \(ask.runtimeDisplayLabel)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Button { onApprove(false) } label: {
                    Text("Reject")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(UnifiedDesignSystem.Colors.error)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            RoundedRectangle(cornerRadius: MissionChrome.controlCorner, style: .continuous)
                                .fill(UnifiedDesignSystem.Colors.error.opacity(0.10))
                        }
                }
                .buttonStyle(.plain)

                Button { onApprove(true) } label: {
                    Text("Approve")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            RoundedRectangle(cornerRadius: MissionChrome.controlCorner, style: .continuous)
                                .fill(UnifiedDesignSystem.Colors.success)
                        }
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: MissionChrome.cardCorner, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.warning.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: MissionChrome.cardCorner, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.warning.opacity(0.45), lineWidth: 1)
        }
    }
}

// MARK: - Activity Ticker

public struct MissionActivityTicker: View {
    public let entries: [MissionConsoleTickerEntry]

    public init(entries: [MissionConsoleTickerEntry]) {
        self.entries = entries
    }

    public var body: some View {
        MissionConsoleCard {
            VStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        Text("No events yet. They'll stream in here.")
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        Spacer(minLength: 0)
                    }
                    .padding(UnifiedDesignSystem.Spacing.md)
                } else {
                    ForEach(Array(entries.prefix(8).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            MissionRowDivider(indent: 34)
                        }
                        entryRow(entry)
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: MissionConsoleTickerEntry) -> some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: glyph(for: entry.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color(for: entry.kind, isError: entry.isError))
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if let title = entry.title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(entry.isError ? UnifiedDesignSystem.Colors.error : UnifiedDesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                    } else {
                        Text(entry.phase.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(entry.isError ? UnifiedDesignSystem.Colors.error : UnifiedDesignSystem.Colors.textPrimary)
                    }
                    Spacer(minLength: 0)
                    Text(MissionConsoleFormatting.relativeTime(entry.timestamp))
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }
                Text(entry.message)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let path = entry.pathDetail, !path.isEmpty {
                    Text(path)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, 8)
    }

    private func glyph(for kind: MissionConsoleTickerEntry.Kind) -> String {
        switch kind {
        case .status:       return "circle.fill"
        case .toolCall:     return "hammer.fill"
        case .toolResult:   return "checkmark.circle.fill"
        case .llmResponse:  return "text.bubble.fill"
        case .finalAnswer:  return "flag.checkered"
        case .changedFile:  return "pencil.and.outline"
        case .artifact:     return "doc.fill"
        case .error:        return "exclamationmark.triangle.fill"
        case .approval:     return "hand.raised.fill"
        }
    }

    private func color(for kind: MissionConsoleTickerEntry.Kind, isError: Bool) -> Color {
        if isError { return UnifiedDesignSystem.Colors.error }
        switch kind {
        case .status:      return UnifiedDesignSystem.Colors.textMuted
        case .toolCall:    return UnifiedDesignSystem.Colors.amber
        case .toolResult:  return UnifiedDesignSystem.Colors.success
        case .llmResponse: return UnifiedDesignSystem.Colors.textSecondary
        case .finalAnswer: return UnifiedDesignSystem.Colors.success
        case .changedFile: return UnifiedDesignSystem.Colors.textSecondary
        case .artifact:    return UnifiedDesignSystem.Colors.textSecondary
        case .error:       return UnifiedDesignSystem.Colors.error
        case .approval:    return UnifiedDesignSystem.Colors.warning
        }
    }
}
