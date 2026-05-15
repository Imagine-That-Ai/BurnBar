import SwiftUI

// MARK: - Mission Fan-Out Group Card (Hermes Square §6.4)
//
// Renders a `MissionGroupDocument` as a horizontally-scrollable stack of
// child mission tiles, with a merge bar that appears once every child
// reaches a terminal state. Pure SwiftUI — caller wires it into the
// Living Inbox / Situation Room.

public struct MissionFanOutGroupCard: View {
    public let group: MissionGroupDocument
    public let childTiles: [MissionConsoleActiveTile]
    public let onMerge: (MergeAction) -> Void
    public let onOpenChild: (String) -> Void

    public enum MergeAction: Equatable, Sendable {
        case pickOne(missionID: String)
        case keepAll
        case synthesize
    }

    public init(
        group: MissionGroupDocument,
        childTiles: [MissionConsoleActiveTile],
        onMerge: @escaping (MergeAction) -> Void,
        onOpenChild: @escaping (String) -> Void
    ) {
        self.group = group
        self.childTiles = childTiles
        self.onMerge = onMerge
        self.onOpenChild = onOpenChild
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            tilesRow
            if group.phase == .awaitingMerge {
                mergeBar
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let summary = group.synthesisSummary, group.phase == .merged {
                synthesisStrip(summary: summary)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(DesignSystemColors.surface.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(DesignSystemColors.borderSubtle, lineWidth: 0.5)
                )
        )
        // The card enters from the top of the inbox with a spring slide +
        // fade, leaves with a soft opacity. Honors Reduce Motion.
        .transition(reduceMotion
                    ? .opacity
                    : .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .top)),
                        removal: .opacity
                      ))
        .animation(reduceMotion ? .none : .spring(response: 0.48, dampingFraction: 0.82), value: group.phase)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack.fill")
                .foregroundStyle(DesignSystemColors.ember)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.callout.bold())
                    .foregroundStyle(DesignSystemColors.textPrimary)
                    .lineLimit(1)
                Text("\(group.runtimeTokens.count) runtimes · \(group.phase.displayLabel)")
                    .font(.caption2)
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
            Spacer()
            forecastBadge
        }
    }

    private var forecastBadge: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(MissionConsoleFormatting.costRange(group.forecast.costLowUSD, group.forecast.costHighUSD))
                .font(.caption.monospacedDigit())
                .foregroundStyle(DesignSystemColors.textSecondary)
            Text("worst-case sum")
                .font(.caption2)
                .foregroundStyle(DesignSystemColors.textMuted)
        }
    }

    // MARK: Tiles

    private var tilesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(childTiles.enumerated()), id: \.element.id) { offset, tile in
                    Button {
                        onOpenChild(tile.id)
                    } label: {
                        StaggeredChildTile(
                            tile: tile,
                            isWinner: group.winnerMissionID == tile.id,
                            reduceMotion: reduceMotion,
                            staggerIndex: offset
                        ) { phase in
                            childTileView(tile)
                                .frame(width: 220)
                                .scaleEffect(phase.scale, anchor: .bottomLeading)
                                .opacity(phase.opacity)
                                .offset(y: phase.yOffset)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func childTileView(_ tile: MissionConsoleActiveTile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                phaseDot(for: tile.phase)
                Text(tile.runtimeDisplayLabel.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(DesignSystemColors.textSecondary)
                Spacer()
                if group.winnerMissionID == tile.id {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(DesignSystemColors.success)
                }
            }
            Text(tile.phase.displayLabel)
                .font(.caption.bold())
                .foregroundStyle(DesignSystemColors.textPrimary)
            Text(tile.lastEventSnippet ?? tile.phaseDetail ?? "—")
                .font(.caption2)
                .foregroundStyle(DesignSystemColors.textMuted)
                .lineLimit(3)
            Spacer()
            HStack {
                if let progress = tile.progressFraction {
                    ProgressView(value: progress).controlSize(.mini).frame(width: 56)
                }
                Spacer()
                Text(MissionConsoleFormatting.cost(tile.burnSoFarUSD))
                    .font(.caption2.monospaced())
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
        }
        .padding(10)
        .frame(height: 140, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignSystemColors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(borderColor(for: tile), lineWidth: 0.5)
                )
        )
    }

    private func phaseDot(for phase: MissionConsoleActiveTile.Phase) -> some View {
        let color: Color = {
            if phase.isProblem { return DesignSystemColors.error }
            if phase == .completed { return DesignSystemColors.success }
            if phase.isLive { return DesignSystemColors.ember }
            return DesignSystemColors.textMuted
        }()
        return Circle().fill(color).frame(width: 6, height: 6)
    }

    private func borderColor(for tile: MissionConsoleActiveTile) -> Color {
        if group.winnerMissionID == tile.id { return DesignSystemColors.success }
        if tile.phase.isProblem { return DesignSystemColors.error.opacity(0.5) }
        return DesignSystemColors.borderSubtle
    }

    // MARK: Merge bar

    private var mergeBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ready to merge")
                .font(.caption.bold())
                .foregroundStyle(DesignSystemColors.textSecondary)
            HStack(spacing: 8) {
                ForEach(childTiles) { tile in
                    Button {
                        onMerge(.pickOne(missionID: tile.id))
                    } label: {
                        Text("Keep \(tile.runtimeDisplayLabel)")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(DesignSystemColors.ember.opacity(0.18)))
                            .foregroundStyle(DesignSystemColors.ember)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    onMerge(.synthesize)
                } label: {
                    Text("Synthesize")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DesignSystemColors.whimsy.opacity(0.18)))
                        .foregroundStyle(DesignSystemColors.whimsy)
                }
                .buttonStyle(.plain)
                Button {
                    onMerge(.keepAll)
                } label: {
                    Text("Keep all")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DesignSystemColors.surface))
                        .foregroundStyle(DesignSystemColors.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func synthesisStrip(summary: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Synthesis")
                .font(.caption.bold())
                .foregroundStyle(DesignSystemColors.whimsy)
            Text(summary)
                .font(.caption)
                .foregroundStyle(DesignSystemColors.textPrimary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DesignSystemColors.whimsy.opacity(0.08))
        )
    }
}

// MARK: - StaggeredChildTile (cascade-in animator)
//
// Wraps a child tile with a `PhaseAnimator` that runs through enter →
// settled on first appearance, staggered by `staggerIndex`. When the
// tile is the winner, an extra "celebrate" phase adds a quick scale
// pulse. Pure presentation — no state mutation.

private struct StaggeredChildTile<Content: View>: View {
    let tile: MissionConsoleActiveTile
    let isWinner: Bool
    let reduceMotion: Bool
    let staggerIndex: Int
    let content: (CascadePhase) -> Content

    @State private var hasAppeared: Bool = false
    @State private var winnerCelebrationTick: Int = 0

    enum CascadePhase: CaseIterable {
        case enter, settle

        var scale: CGFloat {
            switch self {
            case .enter:  return 0.94
            case .settle: return 1.0
            }
        }

        var opacity: Double {
            switch self {
            case .enter:  return 0.0
            case .settle: return 1.0
            }
        }

        var yOffset: CGFloat {
            switch self {
            case .enter:  return 18
            case .settle: return 0
            }
        }
    }

    var body: some View {
        if reduceMotion {
            content(.settle)
        } else {
            content(hasAppeared ? .settle : .enter)
                .animation(
                    .spring(response: 0.55, dampingFraction: 0.78)
                        .delay(Double(staggerIndex) * 0.08),
                    value: hasAppeared
                )
                .onAppear {
                    hasAppeared = true
                }
                .onChange(of: isWinner) { _, newValue in
                    if newValue { winnerCelebrationTick &+= 1 }
                }
                .scaleEffect(winnerScale, anchor: .center)
                .animation(.spring(response: 0.34, dampingFraction: 0.5), value: winnerCelebrationTick)
        }
    }

    private var winnerScale: CGFloat {
        // Quick pulse when the user picks this tile as winner: scale to
        // 1.04 then settle back via the spring above.
        guard isWinner else { return 1.0 }
        return winnerCelebrationTick > 0 && winnerCelebrationTick % 2 == 1 ? 1.04 : 1.0
    }
}
