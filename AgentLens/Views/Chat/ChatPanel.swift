import SwiftUI

// MARK: - Chat Panel

struct ChatPanel: View {
    @Bindable var controller: ChatSessionController
    var dataStore: DataStore
    var settingsManager: SettingsManager
    var onClose: () -> Void

    @State private var brief = InsightBriefSnapshot()
    @State private var panelResizeStart: CGFloat?
    @State private var bottomResizeStart: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(DesignSystem.Colors.border)
            content
            Divider().background(DesignSystem.Colors.border)
            inputRow
        }
        .frame(width: panelWidth, height: panelHeight)
        .background {
            ZStack {
                DesignSystem.Colors.surface.opacity(0.96)
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.coral.opacity(0.05),
                        Color.clear,
                        DesignSystem.Colors.teal.opacity(0.04)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5)
        )
        .shadow(color: DesignSystem.Colors.background.opacity(0.35), radius: 28, y: 12)
        .overlay(alignment: controller.dock == .leading ? .trailing : .leading) {
            if controller.dock != .bottom {
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { g in
                                if panelResizeStart == nil { panelResizeStart = controller.panelWidth }
                                let base = panelResizeStart ?? 320
                                let delta = controller.dock == .leading ? g.translation.width : -g.translation.width
                                controller.panelWidth = min(520, max(260, base + delta))
                            }
                            .onEnded { _ in panelResizeStart = nil }
                    )
            }
        }
        .overlay(alignment: .top) {
            if controller.dock == .bottom {
                Color.clear
                    .frame(height: 10)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { g in
                                if bottomResizeStart == nil { bottomResizeStart = controller.panelHeight }
                                let base = bottomResizeStart ?? 280
                                controller.panelHeight = min(520, max(200, base - g.translation.height))
                            }
                            .onEnded { _ in bottomResizeStart = nil }
                    )
            }
        }
        .onAppear {
            brief = InsightBriefSnapshot.build(from: dataStore)
            controller.loadPersistedMessages()
        }
        .onChange(of: dataStore.lastRefresh) { _, _ in
            brief = InsightBriefSnapshot.build(from: dataStore)
        }
    }

    private var panelWidth: CGFloat {
        switch controller.dock {
        case .bottom: return 520
        case .leading, .trailing: return controller.panelWidth
        }
    }

    private var panelHeight: CGFloat {
        switch controller.dock {
        case .bottom: return controller.panelHeight
        case .leading, .trailing: return 560
        }
    }

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            TextField("Search sessions…", text: $controller.searchQuery)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .onSubmit { controller.performSearch() }
                .onChange(of: controller.searchQuery) { _, new in
                    if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        controller.searchResults = []
                        return
                    }
                    let q = new
                    Task {
                        try? await Task.sleep(nanoseconds: 320_000_000)
                        guard controller.searchQuery == q else { return }
                        controller.performSearch()
                    }
                }

            if controller.isSearching {
                ProgressView().controlSize(.small)
            }

            Picker("Dock", selection: $controller.dock) {
                ForEach(ChatPanelDock.allCases) { d in
                    Text(d.label).tag(d)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private var content: some View {
        Group {
            if !controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !controller.searchResults.isEmpty {
                searchResultsList
            } else if !controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      controller.searchResults.isEmpty, !controller.isSearching {
                Text("No matches")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                            if !settingsManager.conversationIndexingEnabled {
                                Text("Conversation indexing is off. Enable it in Settings to unlock search and richer context.")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.warning)
                                    .padding(.horizontal, DesignSystem.Spacing.sm)
                            }

                            if controller.messages.isEmpty && settingsManager.conversationIndexingEnabled {
                                insightSection
                            }

                            ForEach(controller.messages) { msg in
                                ChatMessageView(
                                    message: msg,
                                    isStreaming: controller.isStreaming && msg.id == controller.activeStreamMessageId && msg.role == .assistant,
                                    showViaBadge: msg.cliUsed != nil
                                )
                                .id(msg.id)
                            }
                        }
                        .padding(DesignSystem.Spacing.md)
                    }
                    .onChange(of: controller.messages.count) { _, _ in
                        if let last = controller.messages.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private var searchResultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ForEach(controller.searchResults) { r in
                    Button {
                        controller.selectSearchResult(r)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.conversation.inferredTaskTitle)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .lineLimit(2)
                            Text(r.snippet.strippingSimpleTags)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .lineLimit(2)
                            Text("\(r.conversation.provider.displayName) · \(r.conversation.projectName)")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignSystem.Spacing.sm)
                        .background(DesignSystem.Colors.surfaceElevated.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private var insightSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Brief")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .textCase(.uppercase)

            if let w = brief.whereLeftOff {
                InsightBriefCard(
                    title: "Where you left off",
                    bodyText: w,
                    icon: "arrow.turn.down.right",
                    accent: DesignSystem.Colors.teal
                ) {
                    controller.inputText = "Tell me more about my work on \(brief.whereLeftOffProject ?? "this project")"
                }
            }

            if let title = brief.heaviestTaskTitle, let cost = brief.heaviestTaskCost, let proj = brief.heaviestTaskProject {
                InsightBriefCard(
                    title: "Heaviest task this week",
                    bodyText: "\(cost.formatAsCost()) on \(proj) — \(title)",
                    icon: "flame.fill",
                    accent: DesignSystem.Colors.coral
                ) {
                    controller.inputText = "What did I spend on \(title) this week?"
                }
            }

            if let m = brief.modelShiftHeadline {
                InsightBriefCard(
                    title: "New model activity",
                    bodyText: m,
                    icon: "sparkles",
                    accent: DesignSystem.Colors.purple
                ) {
                    controller.inputText = "Tell me more about my new model usage"
                }
            }

            if let inc = brief.incompleteHint {
                InsightBriefCard(
                    title: "Open thread",
                    bodyText: inc,
                    icon: "ellipsis.bubble",
                    accent: DesignSystem.Colors.gold
                ) {
                    controller.inputText = "Help me continue where I left off"
                }
            }
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: DesignSystem.Spacing.sm) {
            TextField("Message…", text: $controller.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .lineLimit(1...5)
                .padding(DesignSystem.Spacing.sm)
                .background(DesignSystem.Colors.background.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .stroke(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
                )

            VStack(spacing: 6) {
                if controller.isStreaming {
                    Button("Stop") {
                        controller.cancelGeneration()
                    }
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.error)
                }

                Button {
                    Task { await controller.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(DesignSystem.Colors.primaryGradient)
                }
                .buttonStyle(.plain)
                .disabled(controller.isStreaming || controller.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DesignSystem.Spacing.md)
    }
}

private extension String {
    var strippingSimpleTags: String {
        replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")
    }
}
