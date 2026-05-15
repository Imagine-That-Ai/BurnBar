import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Square Thread Row (Hermes Square §6.2)
//
// Inbox row rendering a `ThreadInboxItem`. Compact, editorial. Shows the
// agent glyph + name, title, preview, last-activity, plus a "needs
// attention" badge if applicable.

struct HermesSquareThreadRow: View {
    let item: ThreadInboxItem
    let registry: AgentIdentityRegistry

    private var identity: AgentIdentity? {
        registry.identity(for: item.agentURI)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(identity?.displayName ?? "Agent")
                        .font(.caption.bold())
                        .foregroundStyle(DesignSystemColors.textSecondary)
                    Spacer()
                    Text(MissionConsoleFormatting.relativeTime(item.lastActivityAt))
                        .font(.caption2)
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
                Text(item.title)
                    .font(.callout.bold())
                    .foregroundStyle(DesignSystemColors.textPrimary)
                    .lineLimit(1)
                Text(item.preview)
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
                    .lineLimit(2)
                if item.needsAttention {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(DesignSystemColors.warning)
                        Text("Needs attention")
                            .font(.caption2.bold())
                            .foregroundStyle(DesignSystemColors.warning)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignSystemColors.surface.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(item.needsAttention
                                ? DesignSystemColors.warning.opacity(0.5)
                                : DesignSystemColors.borderSubtle,
                                lineWidth: 0.5)
                )
        )
    }

    private var avatar: some View {
        Group {
            if let identity {
                HermesSquareAgentAvatar(
                    identity: identity,
                    size: 28,
                    showAvailability: false,
                    ringStroke: false
                )
            } else {
                ZStack {
                    Circle()
                        .fill(DesignSystemColors.surface)
                        .frame(width: 28, height: 28)
                    Image(systemName: "questionmark")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
            }
        }
    }
}

// MARK: - Mission Tile (compact version)

struct HermesSquareMissionTile: View {
    let tile: MissionConsoleActiveTile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                phaseBadge
                Spacer()
                Text(tile.runtimeDisplayLabel)
                    .font(.caption2.bold())
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
            Text(tile.title)
                .font(.callout.bold())
                .foregroundStyle(DesignSystemColors.textPrimary)
                .lineLimit(2)
            if let snippet = tile.lastEventSnippet ?? tile.phaseDetail {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
                    .lineLimit(2)
            }
            Spacer()
            HStack(spacing: 4) {
                if tile.approvalPending {
                    Image(systemName: "hand.raised.fill")
                        .font(.caption2)
                        .foregroundStyle(DesignSystemColors.warning)
                    Text("Awaiting approval")
                        .font(.caption2.bold())
                        .foregroundStyle(DesignSystemColors.warning)
                }
                Spacer()
                if let progress = tile.progressFraction {
                    ProgressView(value: progress).controlSize(.mini)
                        .frame(width: 56)
                }
                Text(MissionConsoleFormatting.cost(tile.burnSoFarUSD))
                    .font(.caption2.monospaced())
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
        }
        .padding(12)
        .frame(height: 140, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignSystemColors.surface.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(DesignSystemColors.borderSubtle, lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private var phaseBadge: some View {
        let label = tile.phase.displayLabel
        let color: Color = {
            if tile.phase.isProblem { return DesignSystemColors.error }
            if tile.phase == .completed { return DesignSystemColors.success }
            if tile.phase.isLive { return DesignSystemColors.ember }
            return DesignSystemColors.textMuted
        }()
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(color)
        }
    }
}

// MARK: - Search Hit Row

struct HermesSquareSearchHitRow: View {
    let hit: UnifiedSearchIndex.Hit

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: glyph(for: hit.ref.corpus))
                .foregroundStyle(DesignSystemColors.ember)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.title)
                        .font(.callout.bold())
                        .foregroundStyle(DesignSystemColors.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(hit.ref.corpus.rawValue)
                        .font(.caption2.bold())
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
                Text(hit.preview)
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DesignSystemColors.surface.opacity(0.4))
        )
    }

    private func glyph(for corpus: UnifiedSearchIndex.Corpus) -> String {
        switch corpus {
        case .agents:    return "person.crop.circle"
        case .threads:   return "bubble.left.and.bubble.right"
        case .missions:  return "doc.viewfinder"
        case .projects:  return "book.closed"
        case .artifacts: return "doc"
        case .cards:     return "square.text.square"
        case .cloudSessions: return "lock.doc"
        case .web:       return "globe"
        }
    }
}
