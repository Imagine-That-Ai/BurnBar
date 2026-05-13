import SwiftUI
import OpenBurnBarCore

struct InsightsCanvasLibraryView: View {

    @Bindable var environment: InsightsMacEnvironment
    @State private var showTemplateGallery = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(environment.canvases) { canvas in
                        canvasRow(canvas)
                    }
                }
                .padding(UnifiedDesignSystem.Spacing.sm)
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 220)
        .background(UnifiedDesignSystem.Colors.background.opacity(0.6))
        .sheet(isPresented: $showTemplateGallery) {
            InsightsTemplateGalleryView(environment: environment, isPresented: $showTemplateGallery)
        }
    }

    private var header: some View {
        HStack {
            Text("Canvases")
                .font(UnifiedDesignSystem.Typography.headline)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
            Spacer()
            Button {
                showTemplateGallery = true
            } label: {
                Image(systemName: "plus.square.dashed")
            }
            .buttonStyle(.plain)
            .help("New canvas from template")
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
    }

    private func canvasRow(_ canvas: InsightCanvas) -> some View {
        let isSelected = canvas.id == environment.selectedCanvasID
        return Button {
            environment.selectedCanvasID = canvas.id
            Task { await environment.refreshSelectedCanvasData() }
        } label: {
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Image(systemName: canvas.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        isSelected
                            ? UnifiedDesignSystem.Colors.ember
                            : UnifiedDesignSystem.Colors.textSecondary
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(canvas.title)
                        .font(UnifiedDesignSystem.Typography.body)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                    if let summary = canvas.summary, !summary.isEmpty {
                        Text(summary)
                            .font(UnifiedDesignSystem.Typography.tiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                    .fill(isSelected ? UnifiedDesignSystem.Colors.ember.opacity(0.10) : .clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) {
                environment.selectedCanvasID = canvas.id
                Task { await environment.deleteCurrentCanvas() }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("New from template") { showTemplateGallery = true }
                .buttonStyle(.borderless)
                .font(UnifiedDesignSystem.Typography.caption)
            Spacer()
        }
        .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
    }
}
