import SwiftUI
import OpenBurnBarCore

/// Top-level mobile Insights tab content. Adapts to iPhone vs iPad
/// automatically via size classes.
struct InsightsRootView: View {

    @State private var store: InsightsStore?
    let dashboardStore: DashboardStore
    let hermesService: HermesService

    var body: some View {
        Group {
            if let store {
                AdaptiveInsightsLayout(store: store, hermesService: hermesService)
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
    @Bindable var hermesService: HermesService
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
                missionStatusBanner
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
                missionStatusBanner
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
        if let analysis = store.currentAnalysis {
            ZStack(alignment: .top) {
                IntelligenceBriefView(
                    result: analysis,
                    onCitationTap: { citation in
                        // Convert a citation tap into a natural-language
                        // follow-up prompt — the composer already routes
                        // those into a new analysis turn with the cited
                        // entity scoped into the snapshot filter.
                        Task {
                            await store.compose(prompt: IntelligenceBriefCitationPrompt.prompt(for: citation))
                        }
                    },
                    onFollowUpTap: { question in
                        Task { await store.compose(prompt: question.question) }
                    },
                    onMissionLaunchTap: { question in
                        store.dispatchMission(question, via: hermesService)
                    },
                    onPinWidget: { generated in
                        Task { await store.pinGeneratedWidget(generated) }
                    },
                    onConfigureModel: { showInspector = true },
                    onShowAudit: nil
                )
                .scrollDismissesKeyboard(.interactively)

                // Inline status banner — the user always sees the
                // engine acknowledging the tap, completing, or
                // failing. Without this banner, follow-up taps look
                // like no-ops because the engine work is fast and the
                // resulting hero change is subtle.
                InsightsComposerStatusBanner(store: store)
                    .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
                    .padding(.top, UnifiedDesignSystem.Spacing.sm)
            }
        } else if store.currentCanvas != nil {
            // Fallback for a canvas without a generated analysis (rare —
            // refreshSelectedCanvas always populates analysis on success).
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            InsightsMobileEmptyState(store: store, showTemplates: $showTemplateGallery)
        }
    }

    private var composerBar: some View {
        InsightsMobileComposerBar(store: store)
            .padding(UnifiedDesignSystem.Spacing.md)
            .background(.thinMaterial)
    }

    @ViewBuilder
    private var missionStatusBanner: some View {
        switch store.missionStatus {
        case .idle:
            EmptyView()
        case .dispatched(let title, let runtime):
            missionBanner(
                icon: "paperplane.circle.fill",
                tone: UnifiedDesignSystem.Colors.success,
                title: "Mission dispatched to \(runtime)",
                detail: "\(title). Open the matching assistant tile to watch the Mac-run transcript sync back."
            )
        case .failed(let title, let message):
            missionBanner(
                icon: "exclamationmark.triangle.fill",
                tone: UnifiedDesignSystem.Colors.warning,
                title: "Mission was not dispatched",
                detail: "\(title): \(message)"
            )
        }
    }

    private func missionBanner(icon: String, tone: Color, title: String, detail: String) -> some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(UnifiedDesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Text(detail)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            Button("Dismiss") { store.dismissMissionStatus() }
                .font(UnifiedDesignSystem.Typography.tiny)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
        .background(.thinMaterial)
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
                .accessibilityLabel("Send")
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
}

// MARK: - Inspector

private struct InsightsMobileInspectorView: View {
    @Bindable var store: InsightsStore

    var body: some View {
        NavigationStack {
            Form {
                // Model + privacy is the most-changed control surface
                // for the brief, so it leads the inspector. Both
                // controls are bound to the same `InsightsStore` state
                // that the brief reads back out in its meta strip, so
                // changing them here is immediately reflected on the
                // brief without a round-trip.
                Section {
                    Picker(selection: Binding(
                        get: { store.selectedModelTag.modelID },
                        set: { newID in
                            guard let model = store.modelCatalog.first(where: { $0.id == newID }) else { return }
                            store.selectedModelTag = .init(
                                providerKey: model.providerKey,
                                modelID: model.id,
                                displayName: model.displayName,
                                egressTier: model.egressTier
                            )
                        }
                    )) {
                        ForEach(store.modelCatalog) { model in
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.displayName)
                                    Text(model.egressTier.displayLabel)
                                        .font(.caption2)
                                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                                }
                            } icon: {
                                Image(systemName: model.egressTier.symbolName)
                            }
                            .tag(model.id)
                        }
                    } label: {
                        Label("Model", systemImage: store.selectedModelTag.egressTier.symbolName)
                    }
                    .pickerStyle(.navigationLink)

                    Toggle(isOn: $store.privacyMode) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Local-only models")
                                Text("Restrict to engines that never leave this device")
                                    .font(.caption2)
                                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                            }
                        } icon: {
                            Image(systemName: "lock.shield.fill")
                        }
                    }
                } header: {
                    Text("Model & privacy")
                } footer: {
                    Text("Currently running on \(store.selectedModelTag.displayName) · \(store.selectedModelTag.egressTier.displayLabel).")
                        .font(.caption)
                }

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
            }
            .navigationTitle("Brief options")
            .navigationBarTitleDisplayMode(.inline)
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

// MARK: - Composer status banner

/// Inline banner that shows the live state of the most recent
/// `InsightsStore.compose(prompt:)` call. Renders four states:
///
/// * `.idle` — invisible (no UI noise when nothing is happening).
/// * `.running` — coral-tinted pill with a spinner + "Asking X via
///   {model}" text. Tells the user the tap registered.
/// * `.succeeded` — short-lived green confirmation that auto-dismisses
///   so the brief returns to its quiet editorial mode.
/// * `.failed` — error pill with the underlying error message, the
///   model that was attempted, and a Retry / Dismiss pair.
///
/// This is the single source of truth for "did my tap do anything?"
/// across follow-up links, citation taps, and the inline composer.
private struct InsightsComposerStatusBanner: View {
    @Bindable var store: InsightsStore
    @State private var autoDismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch store.composerStatus {
            case .idle:
                EmptyView()
            case .running(let prompt, let model, let egress):
                runningPill(prompt: prompt, model: model, egress: egress)
            case .succeeded(let prompt, let model):
                succeededPill(prompt: prompt, model: model)
                    .onAppear { scheduleAutoDismiss() }
                    .onDisappear { autoDismissTask?.cancel() }
            case .failed(let prompt, let model, let message):
                failedPill(prompt: prompt, model: model, message: message)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.composerStatus)
    }

    private func runningPill(prompt: String, model: String, egress: String) -> some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
                .tint(UnifiedDesignSystem.Colors.ember)
            VStack(alignment: .leading, spacing: 1) {
                Text("Asking via \(model)")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Text("\"\(prompt)\" · \(egress)")
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.ember.opacity(0.45), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Asking \(model): \(prompt)")
    }

    private func succeededPill(prompt: String, model: String) -> some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(UnifiedDesignSystem.Colors.success)
            Text("Answered by \(model)")
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
            Spacer(minLength: 0)
            Button("Dismiss") {
                autoDismissTask?.cancel()
                store.dismissComposerStatus()
            }
            .buttonStyle(.plain)
            .font(UnifiedDesignSystem.Typography.tiny)
            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.success.opacity(0.45), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Answered by \(model). \(prompt)")
    }

    private func failedPill(prompt: String, model: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(UnifiedDesignSystem.Colors.error)
                Text("\(model) couldn't answer")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Spacer(minLength: 0)
            }
            Text("\"\(prompt)\"")
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .lineLimit(2)
            Text(message)
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.error)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Button {
                    Task { await store.retryComposerStatus() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                        .font(UnifiedDesignSystem.Typography.tiny)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(UnifiedDesignSystem.Colors.ember)
                Button("Dismiss") { store.dismissComposerStatus() }
                    .buttonStyle(.plain)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.error.opacity(0.55), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model) couldn't answer \(prompt). \(message). Tap Retry to try again.")
    }

    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000) // 2.4s
            guard !Task.isCancelled,
                  case .succeeded = store.composerStatus else { return }
            store.dismissComposerStatus()
        }
    }
}
