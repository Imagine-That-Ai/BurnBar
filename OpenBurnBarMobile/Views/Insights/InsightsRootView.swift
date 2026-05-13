import SwiftUI
import OpenBurnBarCore

/// Top-level mobile Insights tab content. Adapts to iPhone vs iPad
/// automatically via size classes.
struct InsightsRootView: View {

    @State private var store: InsightsStore?
    let dashboardStore: DashboardStore

    var body: some View {
        Group {
            if let store {
                AdaptiveInsightsLayout(store: store)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Ensure the dashboard store is hydrated before any snapshot is
            // requested — otherwise the synthetic InsightUsageRows would be
            // empty until the user happened to visit another tab first.
            await dashboardStore.load()
            if store == nil {
                let dataSource = MobileInsightDataSource(dashboardStore: dashboardStore)
                if let s = try? InsightsStore(dataSource: dataSource) {
                    store = s
                }
            } else {
                await store?.refreshSelectedCanvas()
            }
        }
    }
}
private struct AdaptiveInsightsLayout: View {

    @Bindable var store: InsightsStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showCanvasList: Bool = false
    @State private var showInspector: Bool = false
    @State private var showTemplateGallery: Bool = false
    private static let iPhoneNavigationTrayClearance: CGFloat = 96

    var body: some View {
        if sizeClass == .regular {
            iPadLayout
        } else {
            iPhoneLayout
        }
    }

    // MARK: - iPad layout

    private var iPadLayout: some View {
        NavigationSplitView {
            InsightsMobileCanvasList(store: store, showTemplates: $showTemplateGallery)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
        } detail: {
            VStack(spacing: 0) {
                canvasContent
                    .frame(maxHeight: .infinity)
                composerBar
            }
            .background(UnifiedDesignSystem.Colors.background)
            .navigationTitle(store.currentCanvas?.title ?? "Insights")
            .toolbar { toolbar }
        }
        .sheet(isPresented: $showInspector) {
            InsightsMobileInspectorView(store: store)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showTemplateGallery) {
            InsightsMobileTemplateGallery(store: store, isPresented: $showTemplateGallery)
        }
    }

    // MARK: - iPhone layout

    private var iPhoneLayout: some View {
        NavigationStack {
            VStack(spacing: 0) {
                canvasContent
                    .frame(maxHeight: .infinity)
                composerBar
                    .padding(.bottom, Self.iPhoneNavigationTrayClearance)
            }
            .background(UnifiedDesignSystem.Colors.background)
            .navigationTitle(store.currentCanvas?.title ?? "Insights")
            .toolbar { toolbar }
        }
        .sheet(isPresented: $showCanvasList) {
            InsightsMobileCanvasList(store: store, showTemplates: $showTemplateGallery)
                .presentationDetents([.fraction(0.5), .large])
        }
        .sheet(isPresented: $showInspector) {
            InsightsMobileInspectorView(store: store)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showTemplateGallery) {
            InsightsMobileTemplateGallery(store: store, isPresented: $showTemplateGallery)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showCanvasList = true
            } label: {
                Image(systemName: "rectangle.stack")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await store.refreshSelectedCanvas() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showInspector = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
        }
    }

    @ViewBuilder
    private var canvasContent: some View {
        if let canvas = store.currentCanvas {
            ScrollView {
                LazyVStack(spacing: UnifiedDesignSystem.Spacing.md) {
                    if let analysis = store.currentAnalysis {
                        InsightsMobileAnalysisBrief(analysis: analysis)
                    }
                    ForEach(canvas.widgets) { widget in
                        InsightWidgetRenderer(
                            widget: widget,
                            isSelected: widget.id == store.selectedWidgetID,
                            onConfigure: {
                                store.selectedWidgetID = widget.id
                                showInspector = true
                            },
                            onCitationTapped: { _ in }
                        )
                        .onTapGesture {
                            store.selectedWidgetID = widget.id
                        }
                    }
                }
                .padding(UnifiedDesignSystem.Spacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
        } else {
            InsightsMobileEmptyState(store: store, showTemplates: $showTemplateGallery)
        }
    }

    private var composerBar: some View {
        InsightsMobileComposerBar(store: store)
            .padding(UnifiedDesignSystem.Spacing.md)
            .background(.thinMaterial)
    }
}

private struct InsightsMobileAnalysisBrief: View {
    let analysis: InsightAnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Label("Intelligence Brief", systemImage: "sparkles")
                    .font(UnifiedDesignSystem.Typography.headline)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Spacer()
                Text(analysis.modelTag.displayName)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }
            Text(analysis.executiveSummary)
                .font(UnifiedDesignSystem.Typography.body)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(analysis.findings.prefix(3)) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title)
                        .font(UnifiedDesignSystem.Typography.caption.weight(.semibold))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    Text(finding.recommendedAction)
                        .font(UnifiedDesignSystem.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.surface)
        )
    }
}

// MARK: - Empty state

private struct InsightsMobileEmptyState: View {
    @Bindable var store: InsightsStore
    @Binding var showTemplates: Bool

    var body: some View {
        VStack(spacing: UnifiedDesignSystem.Spacing.md) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(UnifiedDesignSystem.Colors.ember)
            Text("Start with a template")
                .font(UnifiedDesignSystem.Typography.title)
            Text("Or just ask the composer below — we'll author a canvas from your data.")
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button("Browse templates") { showTemplates = true }
                .buttonStyle(.borderedProminent)
                .tint(UnifiedDesignSystem.Colors.ember)
        }
        .padding(UnifiedDesignSystem.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Canvas list

private struct InsightsMobileCanvasList: View {
    @Bindable var store: InsightsStore
    @Binding var showTemplates: Bool

    var body: some View {
        List {
            Section("Canvases") {
                ForEach(store.canvases) { canvas in
                    Button {
                        store.selectedCanvasID = canvas.id
                        Task { await store.refreshSelectedCanvas(autoSwitchEmptyDefaultCanvas: false) }
                    } label: {
                        HStack {
                            Image(systemName: canvas.symbolName)
                                .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                            VStack(alignment: .leading) {
                                Text(canvas.title)
                                if let summary = canvas.summary {
                                    Text(summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    Task {
                        for idx in offsets {
                            let id = store.canvases[idx].id
                            store.selectedCanvasID = id
                            await store.deleteCurrentCanvas()
                        }
                    }
                }
            }
            Section {
                Button("New from template") { showTemplates = true }
            }
        }
        .navigationTitle("Canvases")
    }
}

// MARK: - Composer bar

private struct InsightsMobileComposerBar: View {
    @Bindable var store: InsightsStore
    @State private var prompt: String = ""
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            HStack {
                modelMenu
                Spacer()
                Toggle(isOn: $store.privacyMode) {
                    Label("Privacy", systemImage: "lock.shield.fill")
                        .labelStyle(.titleAndIcon)
                        .font(UnifiedDesignSystem.Typography.tiny)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                TextField("Ask anything…", text: $prompt, axis: .horizontal)
                    .textFieldStyle(.plain)
                    .focused($promptFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.vertical, 6)
                    .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                            .fill(UnifiedDesignSystem.Colors.surface)
                    )
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { promptFocused = false }
                                .font(UnifiedDesignSystem.Typography.caption)
                        }
                    }
                Button {
                    send()
                } label: {
                    if store.isComposing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(UnifiedDesignSystem.Colors.ember)
                .disabled(prompt.isEmpty || store.isComposing)
            }
            if let error = store.composerError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.error)
            }
        }
    }

    private func send() {
        let p = prompt
        guard !p.isEmpty, !store.isComposing else { return }
        prompt = ""
        promptFocused = false
        Task { await store.compose(prompt: p) }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(store.modelCatalog) { model in
                Button {
                    store.selectedModelTag = .init(
                        providerKey: model.providerKey,
                        modelID: model.id,
                        displayName: model.displayName,
                        egressTier: model.egressTier
                    )
                } label: {
                    Label("\(model.displayName) · \(model.egressTier.displayLabel)",
                          systemImage: model.egressTier.symbolName)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.selectedModelTag.egressTier.symbolName)
                Text(store.selectedModelTag.displayName)
                Image(systemName: "chevron.down").font(.caption)
            }
            .font(UnifiedDesignSystem.Typography.caption)
            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
            .padding(.vertical, 4)
            .background(Capsule().fill(UnifiedDesignSystem.Colors.surface))
        }
    }
}

// MARK: - Inspector

private struct InsightsMobileInspectorView: View {
    @Bindable var store: InsightsStore

    var body: some View {
        NavigationStack {
            Form {
                if let canvas = store.currentCanvas {
                    Section("Canvas") {
                        Text(canvas.title)
                        Picker("Window", selection: Binding(
                            get: { canvas.filter.window },
                            set: { newWindow in
                                Task {
                                    var updated = canvas
                                    updated.filter.window = newWindow
                                    await store.updateCanvas(updated)
                                    await store.refreshSelectedCanvas(autoSwitchEmptyDefaultCanvas: false)
                                }
                            }
                        )) {
                            ForEach(predefinedWindows, id: \.id) { window in
                                Text(window.displayName).tag(window)
                            }
                        }
                        Picker("Theme", selection: Binding(
                            get: { canvas.theme },
                            set: { newTheme in
                                Task {
                                    var updated = canvas
                                    updated.theme = newTheme
                                    await store.updateCanvas(updated)
                                }
                            }
                        )) {
                            ForEach(InsightTheme.allCases) { theme in
                                Text(theme.displayName).tag(theme)
                            }
                        }
                    }
                }
                Section("Privacy") {
                    Toggle("Local-only models", isOn: $store.privacyMode)
                }
            }
            .navigationTitle("Inspector")
        }
    }

    private var predefinedWindows: [InsightTimeWindow] {
        [.today, .last24h, .last7d, .last30d, .last90d, .last365d, .allTime]
    }
}

// MARK: - Templates

private struct InsightsMobileTemplateGallery: View {
    @Bindable var store: InsightsStore
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List(MobileInsightsTemplates.all) { template in
                Button {
                    Task {
                        await store.createCanvas(from: template)
                        isPresented = false
                    }
                } label: {
                    HStack {
                        Image(systemName: template.symbolName)
                            .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                        VStack(alignment: .leading) {
                            Text(template.title)
                            Text(template.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Templates")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { isPresented = false }
                }
            }
        }
    }
}
