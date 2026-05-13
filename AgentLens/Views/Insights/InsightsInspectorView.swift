import SwiftUI
import OpenBurnBarCore

struct InsightsInspectorView: View {

    @Bindable var environment: InsightsMacEnvironment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
                canvasSection
                Divider().opacity(0.4)
                widgetSection
            }
            .padding(UnifiedDesignSystem.Spacing.md)
        }
        .frame(width: 280)
        .background(UnifiedDesignSystem.Colors.background.opacity(0.6))
    }

    @ViewBuilder
    private var canvasSection: some View {
        if let canvas = environment.currentCanvas {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                Text("Canvas").font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                Text(canvas.title).font(UnifiedDesignSystem.Typography.headline)
                if let summary = canvas.summary {
                    Text(summary).font(UnifiedDesignSystem.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                }
                Picker("Time range", selection: Binding(
                    get: { canvas.filter.window },
                    set: { newWindow in
                        Task {
                            var updated = canvas
                            updated.filter.window = newWindow
                            await environment.updateCanvas(updated)
                            await environment.refreshSelectedCanvasData()
                        }
                    }
                )) {
                    ForEach(predefinedWindows, id: \.id) { window in
                        Text(window.displayName).tag(window)
                    }
                }
                .pickerStyle(.menu)
                Picker("Theme", selection: Binding(
                    get: { canvas.theme },
                    set: { newTheme in
                        Task {
                            var updated = canvas
                            updated.theme = newTheme
                            await environment.updateCanvas(updated)
                        }
                    }
                )) {
                    ForEach(InsightTheme.allCases) { theme in
                        Label(theme.displayName, systemImage: theme.symbolName).tag(theme)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    @ViewBuilder
    private var widgetSection: some View {
        if let canvas = environment.currentCanvas,
           let widget = canvas.widgets.first(where: { $0.id == environment.selectedWidgetID }) {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                Text("Widget").font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                HStack {
                    Image(systemName: widget.kind.symbolName)
                    Text(widget.kind.displayName)
                        .font(UnifiedDesignSystem.Typography.headline)
                }
                TextField("Title", text: Binding(
                    get: { widget.title },
                    set: { newTitle in
                        Task {
                            var updated = canvas
                            updated.update(widgetID: widget.id) { $0.title = newTitle }
                            await environment.updateCanvas(updated)
                        }
                    }
                ))
                if let placement = canvas.layout.placements[widget.id] {
                    Group {
                        Stepper("Column \(placement.column)", value: Binding(
                            get: { placement.column },
                            set: { newColumn in
                                Task {
                                    await environment.moveWidget(id: widget.id,
                                                                  column: newColumn,
                                                                  row: placement.row)
                                }
                            }
                        ), in: 0...max(0, canvas.layout.columnCount - placement.colSpan))
                        Stepper("Row \(placement.row)", value: Binding(
                            get: { placement.row },
                            set: { newRow in
                                Task {
                                    await environment.moveWidget(id: widget.id,
                                                                  column: placement.column,
                                                                  row: newRow)
                                }
                            }
                        ), in: 0...32)
                        Stepper("Width \(placement.colSpan)", value: Binding(
                            get: { placement.colSpan },
                            set: { newSpan in
                                Task {
                                    await environment.resizeWidget(id: widget.id,
                                                                    colSpan: newSpan,
                                                                    rowSpan: placement.rowSpan)
                                }
                            }
                        ), in: 1...canvas.layout.columnCount)
                        Stepper("Height \(placement.rowSpan)", value: Binding(
                            get: { placement.rowSpan },
                            set: { newSpan in
                                Task {
                                    await environment.resizeWidget(id: widget.id,
                                                                    colSpan: placement.colSpan,
                                                                    rowSpan: newSpan)
                                }
                            }
                        ), in: 1...12)
                    }
                }
                Button(role: .destructive) {
                    Task { await environment.removeWidget(id: widget.id) }
                } label: {
                    Label("Remove widget", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        } else {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                Text("Inspector")
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                Text("Select a widget to edit it.")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            }
        }
    }

    private var predefinedWindows: [InsightTimeWindow] {
        [.today, .last24h, .last7d, .last30d, .last90d, .last365d, .allTime]
    }
}
