import SwiftUI

/// Grid of saved canvases scoped to the current agent. Tap a card to
/// navigate into the canvas detail (mobile sheet, macOS workspace).
public struct AgentInsightsCanvasGridView: View {
    public let canvases: [InsightCanvas]
    public let presentation: AgentInsightsView.Presentation
    public var onTap: ((InsightCanvas) -> Void)?

    public init(
        canvases: [InsightCanvas],
        presentation: AgentInsightsView.Presentation,
        onTap: ((InsightCanvas) -> Void)? = nil
    ) {
        self.canvases = canvases
        self.presentation = presentation
        self.onTap = onTap
    }

    public var body: some View {
        let columns: [GridItem] = presentation == .roomy
            ? Array(repeating: GridItem(.flexible(), spacing: UnifiedDesignSystem.Spacing.md), count: 3)
            : Array(repeating: GridItem(.flexible(), spacing: UnifiedDesignSystem.Spacing.md), count: 2)

        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                Text("Saved canvases")
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                Spacer(minLength: 0)
                Text("\(canvases.count)")
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
            LazyVGrid(columns: columns, spacing: UnifiedDesignSystem.Spacing.md) {
                ForEach(canvases) { canvas in
                    CanvasCard(canvas: canvas, onTap: onTap)
                }
            }
        }
    }
}

private struct CanvasCard: View {
    let canvas: InsightCanvas
    let onTap: ((InsightCanvas) -> Void)?

    var body: some View {
        Button {
            onTap?(canvas)
        } label: {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                HStack {
                    Image(systemName: canvas.symbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                    Spacer(minLength: 0)
                    Text("\(canvas.widgets.count)")
                        .font(UnifiedDesignSystem.Typography.monoTiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }
                Text(canvas.title)
                    .font(UnifiedDesignSystem.Typography.headline)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let summary = canvas.summary, !summary.isEmpty {
                    Text(summary)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } else {
                    Text(canvas.filter.window.displayName)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }
            }
            .padding(UnifiedDesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                    .fill(UnifiedDesignSystem.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                            .strokeBorder(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Canvas: \(canvas.title)")
    }
}
