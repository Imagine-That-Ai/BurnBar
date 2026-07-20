import SwiftUI

// MARK: - AI Insight Strip
//
// Renders the ChartInsightEngine's state above the grid when the AI toggle
// is on: authored insights, suggested-chart chips, and honest offline /
// unavailable states. The privacy footnote always names where the summary
// went ("Processed locally via Hermes" vs "Sent to <backend>").

struct ChartAIInsightCard: View {
    let state: ChartInsightEngine.State
    let onRevealChart: (ChartKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            switch state {
            case .idle, .loading:
                loadingContent
            case let .loaded(result, backend, isLocal):
                loadedContent(result: result, backend: backend, isLocal: isLocal)
            case let .unavailable(message):
                unavailableContent(message: message)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
            if #available(macOS 26, *) {
                shape
                    .fill(DesignSystem.Colors.whimsy.opacity(0.08))
                    .liquidGlassEffect(.regular, in: shape)
            } else {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(DesignSystem.Colors.surface.opacity(0.5))
                    shape.fill(DesignSystem.Colors.whimsy.opacity(0.08))
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .stroke(DesignSystem.Colors.whimsy.opacity(0.3), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
    }

    // MARK: Loading

    private var loadingContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.whimsy)
            Text("Reading your usage…")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            ProgressView()
                .controlSize(.small)
        }
    }

    // MARK: Loaded

    @ViewBuilder
    private func loadedContent(result: ChartInsightResult, backend: String, isLocal: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.whimsy)
            Text("AI INSIGHTS")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Spacer()
            Text(isLocal ? "Processed locally via \(backend)" : "Sent to \(backend)")
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }

        ForEach(result.insights) { insight in
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(for: insight.severity))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color(for: insight.severity))
                    .frame(width: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(insight.title)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(insight.body)
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }

        if !result.suggestedCharts.isEmpty {
            HStack(spacing: 8) {
                ForEach(result.suggestedCharts) { suggestion in
                    Button {
                        onRevealChart(suggestion.kind)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 10, weight: .semibold))
                            Text(suggestion.kind.title)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.Colors.whimsy)
                    .liquidGlassInteractive(in: Capsule())
                    .help(suggestion.reason)
                }
                Spacer()
            }
        }
    }

    // MARK: Unavailable

    private func unavailableContent(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.slash" )
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(message)
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
        }
    }

    private func symbol(for severity: ChartInsight.Severity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .win: return "checkmark.seal"
        case .warning: return "exclamationmark.triangle"
        }
    }

    private func color(for severity: ChartInsight.Severity) -> Color {
        switch severity {
        case .info: return DesignSystem.Colors.whimsy
        case .win: return DesignSystem.Colors.success
        case .warning: return DesignSystem.Colors.amber
        }
    }
}
