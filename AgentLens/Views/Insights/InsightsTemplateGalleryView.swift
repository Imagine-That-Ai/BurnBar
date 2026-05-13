import SwiftUI
import OpenBurnBarCore

struct InsightsTemplateGalleryView: View {

    @Bindable var environment: InsightsMacEnvironment
    @Binding var isPresented: Bool

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            HStack {
                Text("Start from a template")
                    .font(UnifiedDesignSystem.Typography.title)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Spacer()
                Button("Close") { isPresented = false }
            }
            Text("Eight beautifully tuned canvases. Pick one to stamp — everything is editable afterward.")
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(InsightsBuiltInTemplates.all) { template in
                        templateCard(template)
                    }
                }
            }
        }
        .padding(UnifiedDesignSystem.Spacing.xl)
        .frame(width: 720, height: 480)
        .background(UnifiedDesignSystem.Colors.background)
    }

    private func templateCard(_ template: InsightCanvasTemplate) -> some View {
        Button {
            Task {
                await environment.createCanvas(from: template)
                isPresented = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: template.symbolName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                    Spacer()
                    Text("\(template.widgets.count) widgets")
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }
                Text(template.title)
                    .font(UnifiedDesignSystem.Typography.headline)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Text(template.summary)
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(UnifiedDesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg)
                            .stroke(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
