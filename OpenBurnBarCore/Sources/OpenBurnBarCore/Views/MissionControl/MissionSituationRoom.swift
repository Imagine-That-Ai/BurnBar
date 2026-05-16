import SwiftUI

// MARK: - Mission Situation Room
//
// Right-column live view inside the Mission Control Console. Bundles:
//   • MissionLiveBurnGauge — radial $/hr gauge with a needle
//   • MissionApprovalCard — surfaces when there's a pending approval
//   • MissionActiveTile — one row per active mission
//   • MissionActivityTicker — terminal-style last-N events
//
// All pieces accept their data via plain value types so the room can be
// previewed without the host.

public struct MissionSituationRoom: View {
    public let activeTiles: [MissionConsoleActiveTile]
    public let recentTicker: [MissionConsoleTickerEntry]
    public let approvalAsks: [MissionConsoleApprovalAsk]
    public let burnPerHourUSD: Double
    public let burnTodayUSD: Double
    public let lastDispatchedMissionID: String?
    public let macOnline: Bool
    public let onApprove: (MissionConsoleApprovalAsk, Bool) -> Void

    public init(
        activeTiles: [MissionConsoleActiveTile],
        recentTicker: [MissionConsoleTickerEntry],
        approvalAsks: [MissionConsoleApprovalAsk],
        burnPerHourUSD: Double,
        burnTodayUSD: Double,
        lastDispatchedMissionID: String?,
        macOnline: Bool,
        onApprove: @escaping (MissionConsoleApprovalAsk, Bool) -> Void
    ) {
        self.activeTiles = activeTiles
        self.recentTicker = recentTicker
        self.approvalAsks = approvalAsks
        self.burnPerHourUSD = burnPerHourUSD
        self.burnTodayUSD = burnTodayUSD
        self.lastDispatchedMissionID = lastDispatchedMissionID
        self.macOnline = macOnline
        self.onApprove = onApprove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
            header

            if !macOnline {
                macOfflineBanner
            }

            MissionLiveBurnGauge(
                burnPerHourUSD: burnPerHourUSD,
                burnTodayUSD: burnTodayUSD
            )

            if !approvalAsks.isEmpty {
                VStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                    ForEach(approvalAsks) { ask in
                        MissionApprovalCard(ask: ask, onApprove: { approve in onApprove(ask, approve) })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            activeMissionsSection
            tickerSection

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(UnifiedDesignSystem.Colors.hermesAureate)
            Text("SITUATION ROOM")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Rectangle()
                .fill(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Mac offline banner

    private var macOfflineBanner: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("No Mac claimed the queue")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Text("Open BurnBar on the paired Mac to start execution.")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(UnifiedDesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.warning.opacity(0.14))
        }
        .overlay {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.warning.opacity(0.5), lineWidth: 0.6)
        }
    }

    // MARK: Active missions

    private var activeMissionsSection: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            sectionLabel(
                "ACTIVE MISSIONS",
                trailing: activeTiles.isEmpty ? "—" : "\(activeTiles.count) in flight"
            )

            if activeTiles.isEmpty {
                emptyActive
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

    private var emptyActive: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Text("Nothing flying. Compose a mission to fill the lane.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.surface.opacity(0.5))
        }
        .overlay {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.55), lineWidth: 0.5)
        }
    }

    // MARK: Ticker

    private var tickerSection: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            sectionLabel("LIVE FEED", trailing: recentTicker.isEmpty ? nil : "\(recentTicker.count) recent")
            MissionActivityTicker(entries: recentTicker)
        }
    }

    private func sectionLabel(_ text: String, trailing: String? = nil) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Rectangle()
                .fill(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.5))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
        }
    }
}

// MARK: - Live Burn Gauge

public struct MissionLiveBurnGauge: View {
    public let burnPerHourUSD: Double
    public let burnTodayUSD: Double

    @State private var animated: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(burnPerHourUSD: Double, burnTodayUSD: Double) {
        self.burnPerHourUSD = burnPerHourUSD
        self.burnTodayUSD = burnTodayUSD
    }

    private var fraction: Double {
        min(1.0, burnPerHourUSD / 3.0)
    }

    public var body: some View {
        HStack(alignment: .center, spacing: UnifiedDesignSystem.Spacing.lg) {
            ZStack {
                // Track
                Circle()
                    .trim(from: 0.05, to: 0.95)
                    .stroke(
                        UnifiedDesignSystem.Colors.borderSubtle.opacity(0.5),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(135))

                // Filled arc
                Circle()
                    .trim(from: 0.05, to: 0.05 + (0.9 * animated))
                    .stroke(
                        AngularGradient(
                            colors: [
                                UnifiedDesignSystem.Colors.success,
                                UnifiedDesignSystem.Colors.amber,
                                UnifiedDesignSystem.Colors.ember
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(135))
                    .animation(UnifiedDesignSystem.Animation.gentle, value: animated)

                VStack(spacing: 0) {
                    Text(MissionConsoleFormatting.cost(burnPerHourUSD, precise: burnPerHourUSD < 1))
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        .contentTransition(.numericText())
                        .animation(UnifiedDesignSystem.Animation.gentle, value: burnPerHourUSD)
                    Text("PER HOUR")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }
            }
            .frame(width: 88, height: 88)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(MissionConsoleFormatting.cost(burnTodayUSD))
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        .contentTransition(.numericText())
                    Text("BURNED TODAY")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }

                if burnPerHourUSD > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("at this pace, ~\(MissionConsoleFormatting.cost(burnPerHourUSD * 8)) over 8h")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(burnPerHourUSD > 1.5 ? UnifiedDesignSystem.Colors.ember : UnifiedDesignSystem.Colors.textSecondary)
                } else {
                    Text("idle")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6), lineWidth: 0.6)
        }
        .onAppear {
            if reduceMotion {
                animated = fraction
            } else {
                withAnimation(.easeOut(duration: 0.8)) { animated = fraction }
            }
        }
        .onChange(of: fraction) { _, new in
            withAnimation(UnifiedDesignSystem.Animation.gentle) { animated = new }
        }
    }
}

// MARK: - Active Mission Tile

public struct MissionActiveTile: View {
    public let tile: MissionConsoleActiveTile
    public let isFreshDispatch: Bool

    @State private var heartbeat = false
    @State private var freshGlow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(tile: MissionConsoleActiveTile, isFreshDispatch: Bool = false) {
        self.tile = tile
        self.isFreshDispatch = isFreshDispatch
    }

    private var phaseColor: Color {
        if tile.approvalPending { return UnifiedDesignSystem.Colors.hermesAureate }
        switch tile.phase {
        case .failed, .blocked, .cancelled: return UnifiedDesignSystem.Colors.ember
        case .macOffline:                   return UnifiedDesignSystem.Colors.textMuted
        case .completed:                    return UnifiedDesignSystem.Colors.success
        case .awaitingApproval:             return UnifiedDesignSystem.Colors.hermesAureate
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
        HStack(alignment: .top, spacing: 0) {
            // Phase stripe (left edge)
            Rectangle()
                .fill(phaseColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    phasePulse
                    Text(tile.phase.displayLabel.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(phaseColor)
                    Spacer(minLength: 0)
                    Text(tile.runtimeDisplayLabel)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                }

                Text(tile.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let tool = tile.currentToolName {
                    HStack(spacing: 4) {
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 8, weight: .bold))
                        Text(tool)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(UnifiedDesignSystem.Colors.amber)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        Capsule().fill(UnifiedDesignSystem.Colors.amber.opacity(0.14))
                    }
                }

                if let snippet = tile.lastEventSnippet {
                    Text(snippet)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
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
                    metaPair(label: "Elapsed", value: MissionConsoleFormatting.duration(elapsed))
                    metaPair(label: "Burn", value: MissionConsoleFormatting.cost(tile.burnSoFarUSD, precise: tile.burnSoFarUSD < 1))
                    if tile.approvalPending {
                        Text("APPROVAL")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1.0)
                            .foregroundStyle(UnifiedDesignSystem.Colors.hermesAureate)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background {
                                Capsule().fill(UnifiedDesignSystem.Colors.hermesAureate.opacity(0.16))
                            }
                            .overlay {
                                Capsule().stroke(UnifiedDesignSystem.Colors.hermesAureate.opacity(0.5), lineWidth: 0.5)
                            }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
            .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
        }
        .background {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.surface.opacity(0.65))
        }
        .overlay {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .strokeBorder(
                    isFreshDispatch
                        ? phaseColor.opacity(0.75)
                        : UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6),
                    lineWidth: isFreshDispatch ? 1.2 : 0.5
                )
        }
        .overlay {
            if freshGlow {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                    .stroke(phaseColor.opacity(0.45), lineWidth: 3)
                    .blur(radius: 8)
                    .padding(-2)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous))
        .onAppear {
            guard !reduceMotion else { return }
            if tile.phase.isLive {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    heartbeat = true
                }
            }
            if isFreshDispatch {
                freshGlow = true
                withAnimation(.easeOut(duration: 1.6).delay(0.2)) {
                    freshGlow = false
                }
            }
        }
    }

    private var phasePulse: some View {
        Circle()
            .fill(phaseColor)
            .frame(width: 7, height: 7)
            .overlay {
                Circle()
                    .stroke(phaseColor.opacity(0.55), lineWidth: 2)
                    .scaleEffect(heartbeat ? 2.4 : 1.0)
                    .opacity(heartbeat ? 0.0 : 0.85)
            }
    }

    private func metaPair(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
        }
    }
}

// MARK: - Approval Card

public struct MissionApprovalCard: View {
    public let ask: MissionConsoleApprovalAsk
    public let onApprove: (Bool) -> Void

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(ask: MissionConsoleApprovalAsk, onApprove: @escaping (Bool) -> Void) {
        self.ask = ask
        self.onApprove = onApprove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.hermesAureate)
                Text("APPROVAL ASK")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(UnifiedDesignSystem.Colors.hermesAureate)
                Spacer()
                Text(MissionConsoleFormatting.relativeTime(ask.requestedAt).uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(ask.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Text(ask.message)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Mission · \(ask.runtimeDisplayLabel)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(UnifiedDesignSystem.Colors.hermesAureate.opacity(0.85))
                    .padding(.top, 2)
            }

            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Button { onApprove(false) } label: {
                    Label("Reject", systemImage: "xmark")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(UnifiedDesignSystem.Colors.error)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            Capsule().fill(UnifiedDesignSystem.Colors.error.opacity(0.12))
                        }
                        .overlay {
                            Capsule().strokeBorder(UnifiedDesignSystem.Colors.error.opacity(0.55), lineWidth: 0.6)
                        }
                }
                .buttonStyle(.plain)

                Button { onApprove(true) } label: {
                    Label("Approve", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            Capsule().fill(UnifiedDesignSystem.mercuryGradient)
                        }
                        .overlay {
                            Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.hermesAureate.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.hermesAureate.opacity(pulse ? 0.85 : 0.5), lineWidth: 1.0)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
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
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                empty
            } else {
                ForEach(Array(entries.prefix(8).enumerated()), id: \.element.id) { (index, entry) in
                    if index > 0 {
                        Divider().overlay(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.4))
                    }
                    entryRow(entry)
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.45))
        }
        .overlay {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
        }
    }

    private var empty: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Text("No events yet. Dispatch a mission and they'll stream in here.")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
    }

    private func entryRow(_ entry: MissionConsoleTickerEntry) -> some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.sm) {
            // Glyph for kind
            Image(systemName: glyph(for: entry.kind))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color(for: entry.kind, isError: entry.isError))
                .frame(width: 12, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if let title = entry.title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(entry.isError ? UnifiedDesignSystem.Colors.error : UnifiedDesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                    } else {
                        Text(entry.phase.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(entry.isError ? UnifiedDesignSystem.Colors.error : UnifiedDesignSystem.Colors.textPrimary)
                    }
                    if let tool = entry.toolName, !tool.isEmpty {
                        Text(tool)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(0.4)
                            .foregroundStyle(UnifiedDesignSystem.Colors.amber)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background { Capsule().fill(UnifiedDesignSystem.Colors.amber.opacity(0.16)) }
                    }
                    Spacer(minLength: 0)
                    Text(MissionConsoleFormatting.relativeTime(entry.timestamp))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }
                Text(entry.message)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let path = entry.pathDetail, !path.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 8))
                        Text(path)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(UnifiedDesignSystem.Colors.hermesAureate)
                }
            }
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, 7)
    }

    private func glyph(for kind: MissionConsoleTickerEntry.Kind) -> String {
        switch kind {
        case .status:       return "circle.fill"
        case .toolCall:     return "hammer.fill"
        case .toolResult:   return "checkmark.diamond.fill"
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
        case .status:      return UnifiedDesignSystem.Colors.textSecondary
        case .toolCall:    return UnifiedDesignSystem.Colors.amber
        case .toolResult:  return UnifiedDesignSystem.Colors.success
        case .llmResponse: return UnifiedDesignSystem.Colors.ember
        case .finalAnswer: return UnifiedDesignSystem.Colors.success
        case .changedFile: return UnifiedDesignSystem.Colors.hermesAureate
        case .artifact:    return UnifiedDesignSystem.Colors.hermesAureate
        case .error:       return UnifiedDesignSystem.Colors.error
        case .approval:    return UnifiedDesignSystem.Colors.hermesAureate
        }
    }
}
