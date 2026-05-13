import SwiftUI

/// Shared chrome wrapper for every widget on the canvas.
///
/// Reuses `UnifiedGlassCard` from the design system so widgets feel
/// continuous with the rest of the app, and centralizes the header /
/// footer / freshness-pill conventions in one place.
public struct InsightWidgetChrome<Body: View>: View {

    public let widget: InsightWidget
    public let isSelected: Bool
    public let onConfigure: (() -> Void)?
    private let content: () -> Body

    public init(widget: InsightWidget,
                isSelected: Bool = false,
                onConfigure: (() -> Void)? = nil,
                @ViewBuilder body: @escaping () -> Body) {
        self.widget = widget
        self.isSelected = isSelected
        self.onConfigure = onConfigure
        self.content = body
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            header
            contentArea
            footer
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .background(background)
        .overlay(selectionRing)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: UnifiedDesignSystem.Spacing.xs) {
            Image(systemName: widget.kind.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(widget.title)
                    .font(UnifiedDesignSystem.Typography.headline)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                if let subtitle = widget.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(UnifiedDesignSystem.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            freshnessPill
            if onConfigure != nil {
                Button {
                    onConfigure?()
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Configure widget")
            }
        }
    }

    private var contentArea: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var footer: some View {
        if let modelTag = widget.modelTag {
            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                Image(systemName: modelTag.egressTier.symbolName)
                    .font(.system(size: 10, weight: .medium))
                Text(modelTag.displayName)
                    .font(UnifiedDesignSystem.Typography.tiny)
                Text("·")
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                Text(modelTag.egressTier.displayLabel)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                Spacer(minLength: 0)
                if let rationale = widget.rationale, !rationale.isEmpty {
                    Text(rationale)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
        }
    }

    private var freshnessPill: some View {
        let (color, label, icon) = freshnessPresentation
        return HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(UnifiedDesignSystem.Typography.tiny)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.xs)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
        .foregroundStyle(color)
    }

    private var freshnessPresentation: (Color, String, String?) {
        switch widget.freshness {
        case .fresh: return (UnifiedDesignSystem.Colors.success, "Live", nil)
        case .stale: return (UnifiedDesignSystem.Colors.warning, "Stale", nil)
        case .computing: return (UnifiedDesignSystem.Colors.whimsy, "Computing", "sparkles")
        case .error: return (UnifiedDesignSystem.Colors.error, "Error", "exclamationmark.triangle.fill")
        case .locked: return (UnifiedDesignSystem.Colors.textMuted, "Pinned", "lock.fill")
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg, style: .continuous)
                    .stroke(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private var selectionRing: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg, style: .continuous)
                .stroke(UnifiedDesignSystem.Colors.ember, lineWidth: 2)
                .animation(UnifiedDesignSystem.Animation.snappy, value: isSelected)
        }
    }
}
