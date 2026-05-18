import SwiftUI

/// The 1-4 bullet rows below the rings.
public struct VerdictBulletList: View {

    public var bullets: [VerdictBullet]
    public var onCitationTap: (InsightCitation) -> Void
    public var onAcceptAction: (VerdictBullet, VerdictAcceptAction) -> Void

    public init(
        bullets: [VerdictBullet],
        onCitationTap: @escaping (InsightCitation) -> Void = { _ in },
        onAcceptAction: @escaping (VerdictBullet, VerdictAcceptAction) -> Void = { _, _ in }
    ) {
        self.bullets = bullets
        self.onCitationTap = onCitationTap
        self.onAcceptAction = onAcceptAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            ForEach(bullets) { bullet in
                VerdictBulletRow(
                    bullet: bullet,
                    onCitationTap: onCitationTap,
                    onAcceptAction: { action in
                        onAcceptAction(bullet, action)
                    }
                )
            }
        }
    }
}

/// One bullet — claim + delta chip + cite chips + optional accept action.
public struct VerdictBulletRow: View {

    public var bullet: VerdictBullet
    public var onCitationTap: (InsightCitation) -> Void
    public var onAcceptAction: (VerdictAcceptAction) -> Void

    public init(
        bullet: VerdictBullet,
        onCitationTap: @escaping (InsightCitation) -> Void = { _ in },
        onAcceptAction: @escaping (VerdictAcceptAction) -> Void = { _ in }
    ) {
        self.bullet = bullet
        self.onCitationTap = onCitationTap
        self.onAcceptAction = onAcceptAction
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UnifiedDesignSystem.Spacing.md) {
            // Glyph leader (recommendation/anomaly/etc).
            Image(systemName: glyph)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(glyphTint)
                .frame(width: 14, alignment: .leading)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                Text(bullet.claim)
                    .font(UnifiedDesignSystem.Typography.body)
                    .foregroundStyle(textColor)
                    .italic(bullet.confidence == .low)
                    .multilineTextAlignment(.leading)
                if !bullet.citations.isEmpty || bullet.delta != nil {
                    citationStrip
                }
            }
            Spacer(minLength: 0)
            if let action = bullet.acceptAction {
                acceptButton(action)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var citationStrip: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
            if let delta = bullet.delta {
                VerdictDeltaChip(delta: delta, compact: true)
            }
            ForEach(bullet.citations) { citation in
                citationChip(citation)
            }
        }
    }

    private func citationChip(_ citation: InsightCitation) -> some View {
        Button(action: { onCitationTap(citation) }) {
            Text(citation.label)
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .padding(.horizontal, UnifiedDesignSystem.Spacing.xs)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open citation: \(citation.label)")
    }

    private func acceptButton(_ action: VerdictAcceptAction) -> some View {
        Button(action: { onAcceptAction(action) }) {
            HStack(spacing: 4) {
                Text(action.label)
                    .font(UnifiedDesignSystem.Typography.caption)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
            .padding(.vertical, UnifiedDesignSystem.Spacing.xs)
            .background(
                Capsule().fill(UnifiedDesignSystem.Colors.ember.opacity(0.16))
            )
            .foregroundStyle(UnifiedDesignSystem.Colors.ember)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Performs the recommended action")
    }

    private var glyph: String {
        switch bullet.type {
        case .reflectiveFact: return "circle.fill"
        case .comparison: return "arrow.left.and.right"
        case .pattern: return "waveform"
        case .anomaly: return "exclamationmark.triangle.fill"
        case .recommendation: return "wand.and.stars"
        case .discovery: return "sparkles"
        case .forecast: return "chart.line.uptrend.xyaxis"
        case .achievement: return "rosette"
        case .risk: return "shield.lefthalf.filled"
        case .story: return "book.closed"
        }
    }

    private var glyphTint: Color {
        switch bullet.type {
        case .anomaly, .risk: return UnifiedDesignSystem.Colors.warning
        case .recommendation, .achievement, .discovery: return UnifiedDesignSystem.Colors.ember
        case .forecast: return UnifiedDesignSystem.Colors.whimsy
        default: return UnifiedDesignSystem.Colors.textMuted
        }
    }

    private var textColor: Color {
        bullet.confidence == .low
            ? UnifiedDesignSystem.Colors.textSecondary
            : UnifiedDesignSystem.Colors.textPrimary
    }

    private var accessibilityLabel: String {
        var parts: [String] = ["\(bullet.type.rawValue.replacingOccurrences(of: "_", with: " ")) bullet.",
                               bullet.claim]
        if let delta = bullet.delta {
            parts.append("Delta \(Int(abs(delta.value).rounded()))% \(delta.baseline).")
        }
        if !bullet.citations.isEmpty {
            parts.append("Cites \(bullet.citations.count).")
        }
        if let action = bullet.acceptAction {
            parts.append("Has action: \(action.label).")
        }
        return parts.joined(separator: " ")
    }
}
