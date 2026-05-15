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

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            tilesRow
            if group.phase == .awaitingMerge {
                mergeBar
            }
            if let summary = group.synthesisSummary, group.phase == .merged {
                synthesisStrip(summary: summary)
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
                ForEach(childTiles) { tile in
                    Button {
                        onOpenChild(tile.id)
                    } label: {
                        childTileView(tile)
                            .frame(width: 220)
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
