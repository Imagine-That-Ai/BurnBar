import SwiftUI
import OpenBurnBarCore

struct TextExpansionSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    let dataStore: DataStoreCoordinator

    @State private var snippets: [TextExpansionSnippet] = []
    @State private var selectedID: String?
    @State private var title = ""
    @State private var trigger = ""
    @State private var snippetBody = ""
    @State private var mode: TextExpansionMode = .staticText
    @State private var isEnabled = true
    @State private var statusMessage: String?

    private var selectedSnippet: TextExpansionSnippet? {
        snippets.first { $0.id == selectedID }
    }

    private var triggerError: String? {
        let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return TextExpansionTrigger.validationError(for: trimmed)
    }

    private var duplicateTriggerError: String? {
        guard triggerError == nil else { return nil }
        let canonical = TextExpansionTrigger.canonicalName(trigger)
        guard !canonical.isEmpty else { return nil }
        return snippets.contains { snippet in
            snippet.id != selectedID && snippet.deletedAt == nil && snippet.trigger == canonical
        } ? "Trigger already exists." : nil
    }

    private var canSave: Bool {
        triggerError == nil
            && duplicateTriggerError == nil
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !snippetBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            snippetList
                .frame(minWidth: 260, idealWidth: 300)
                .background(DesignSystem.Colors.surface.opacity(0.55))

            Divider()

            SettingsDeepLinkScrollContainer(route: .textExpansionRoot) { _ in
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                        runtimeSection
                        editorSection
                    }
                    .padding(DesignSystem.Spacing.lg)
                    .frame(maxWidth: 760, alignment: .leading)
                }
            }
        }
        .task { reloadSnippets(selectFirst: true) }
    }

    // MARK: - Snippet List

    private var snippetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Snippets")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Button {
                    createDraft()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New snippet")
            }
            .padding(DesignSystem.Spacing.md)

            if snippets.isEmpty {
                VStack(spacing: DesignSystem.Spacing.md) {
                    Spacer()
                    Image(systemName: "text.cursor")
                        .font(.system(size: 36))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text("No snippets yet")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text("Create your first &&trigger")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Button {
                        createDraft()
                    } label: {
                        Label("New Snippet", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(snippets, selection: $selectedID) { snippet in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(snippet.title)
                                .font(DesignSystem.Typography.body)
                                .lineLimit(1)
                            if !snippet.isEnabled {
                                Image(systemName: "circle.slash")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            Spacer(minLength: 0)
                            modeBadge(for: snippet.mode)
                        }
                        Text(snippet.activationToken)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(snippet.isEnabled ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted)
                        Text(relativeTime(snippet.updatedAt))
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    .tag(snippet.id)
                    .opacity(snippet.isEnabled ? 1 : 0.55)
                }
                .listStyle(.sidebar)
                .onChange(of: selectedID) { _, _ in loadSelectedSnippet() }
            }
        }
    }

    // MARK: - Runtime

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsSectionHeader(title: "Runtime")
            SettingsToggle(
                title: "Expand inside OpenBurnBar chat",
                subtitle: "Static snippets insert immediately. LLM snippets open a preview before insertion.",
                icon: "bubble.left.and.text.bubble.right.fill",
                isOn: binding(\.inAppExpansionEnabled)
            )
            #if !DISTRIBUTION_MAS
            SettingsToggle(
                title: "Expand in other Mac apps",
                subtitle: "Requires Accessibility permission. Secure fields are ignored.",
                icon: "keyboard",
                isOn: binding(\.macGlobalExpansionEnabled)
            )
            #endif
            SettingsToggle(
                title: "Allow LLM rewrite previews",
                subtitle: "Uses the active OpenBurnBar chat backend and the current thread context when available.",
                icon: "sparkles",
                isOn: binding(\.llmRewritePreviewEnabled)
            )
            SettingsToggle(
                title: "Share snippets with keyboard extensions",
                subtitle: "Writes an App Group snapshot for iPhone, iPad, and Android surfaces that cannot open the main database.",
                icon: "iphone.and.arrow.forward",
                isOn: binding(\.exportKeyboardSnapshotEnabled)
            )
            SettingsToggle(
                title: "Sync snippets across devices",
                subtitle: "Encrypted end-to-end. Uses your Cloud Vault key to sync via Firestore.",
                icon: "icloud",
                isOn: binding(\.cloudSyncEnabled)
            )
        }
        .settingsAnchor(SettingsAnchor.textExpansionRuntime)
    }

    // MARK: - Editor

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsSectionHeader(title: selectedSnippet == nil ? "New Snippet" : "Snippet")

            // Trigger chip preview
            if !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(trigger.hasPrefix("&&") ? trigger : "&&\(trigger)")
                        .font(DesignSystem.Typography.mono)
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, DesignSystem.Spacing.xs)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.hermesAureate.opacity(0.12))
                        )
                        .overlay(
                            Capsule()
                                .stroke(DesignSystem.Colors.hermesAureate.opacity(0.25), lineWidth: 0.75)
                        )
                    modeBadge(for: mode)
                }
            }

            // Editor card
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Grid(alignment: .topLeading, horizontalSpacing: DesignSystem.Spacing.md, verticalSpacing: DesignSystem.Spacing.md) {
                    GridRow {
                        Text("Name")
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        TextField("Confident reply", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Trigger")
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("&&confident", text: $trigger)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            if let triggerError {
                                Label(triggerError, systemImage: "exclamationmark.triangle.fill")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.error)
                            } else if let duplicateTriggerError {
                                Label(duplicateTriggerError, systemImage: "exclamationmark.triangle.fill")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.error)
                            }
                        }
                    }
                    GridRow {
                        Text("Mode")
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Picker("", selection: $mode) {
                            Text("Static").tag(TextExpansionMode.staticText)
                            Text("LLM preview").tag(TextExpansionMode.llmRewrite)
                        }
                        .pickerStyle(.segmented)
                    }
                    GridRow {
                        Text("Enabled")
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Toggle("", isOn: $isEnabled)
                            .toggleStyle(.switch)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Snippet")
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    TextEditor(text: $snippetBody)
                        .font(DesignSystem.Typography.body)
                        .frame(minHeight: 180)
                        .padding(8)
                        .background(DesignSystem.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.75)
                        )
                }

                // Preview affordance
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    if mode == .llmRewrite {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            Text("Preview will use thread context to rewrite this snippet")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .italic()
                        }
                        .padding(DesignSystem.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DesignSystem.Colors.surfaceMuted.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                    } else {
                        Text(snippetBody.isEmpty ? "Type snippet body above" : snippetBody)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(snippetBody.isEmpty ? DesignSystem.Colors.textMuted : DesignSystem.Colors.textPrimary)
                            .lineLimit(3)
                            .padding(DesignSystem.Spacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DesignSystem.Colors.surfaceMuted.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                    }
                }

                // Action bar
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button {
                        saveSnippet()
                    } label: {
                        Label("Save", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)

                    Button(role: .destructive) {
                        deleteSelectedSnippet()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selectedSnippet == nil)

                    Spacer()

                    if let statusMessage {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: statusMessage.contains("failed") || statusMessage.contains("Could not")
                                  ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(
                                    statusMessage.contains("failed") || statusMessage.contains("Could not")
                                    ? DesignSystem.Colors.error : DesignSystem.Colors.success
                                )
                            Text(statusMessage)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .animation(DesignSystem.Animation.standard, value: statusMessage)
            }
            .padding(DesignSystem.Spacing.lg)
            .background(DesignSystem.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.75)
            )
        }
        .settingsAnchor(SettingsAnchor.textExpansionSnippets)
    }

    // MARK: - Mode Badge

    @ViewBuilder
    private func modeBadge(for snippetMode: TextExpansionMode) -> some View {
        if snippetMode == .llmRewrite {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                Text("LLM")
                    .font(DesignSystem.Typography.tiny)
            }
            .foregroundStyle(DesignSystem.Colors.hermesAureate)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.hermesAureate.opacity(0.1))
            )
        } else {
            Text("Static")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(DesignSystem.Colors.surfaceMuted)
                )
        }
    }

    // MARK: - Helpers

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 30 { return "\(days)d ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<TextExpansionSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settingsManager.textExpansion[keyPath: keyPath] },
            set: { settingsManager.textExpansion[keyPath: keyPath] = $0 }
        )
    }

    private func reloadSnippets(selectFirst: Bool = false) {
        do {
            snippets = try dataStore.fetchTextExpansionSnippets()
            if selectFirst, selectedID == nil {
                selectedID = snippets.first?.id
            }
            loadSelectedSnippet()
            exportSnapshotIfNeeded()
        } catch {
            statusMessage = "Could not load snippets: \(error.localizedDescription)"
        }
    }

    private func loadSelectedSnippet() {
        guard let snippet = selectedSnippet else { return }
        title = snippet.title
        trigger = snippet.activationToken
        snippetBody = snippet.body
        mode = snippet.mode
        isEnabled = snippet.isEnabled
    }

    private func createDraft() {
        selectedID = nil
        title = "Confident reply"
        trigger = "&&confident"
        snippetBody = "I'm confident this is the right next step."
        mode = .staticText
        isEnabled = true
        statusMessage = nil
    }

    private func saveSnippet() {
        let now = Date()
        let id = selectedSnippet?.id ?? UUID().uuidString
        let revision = (selectedSnippet?.revision ?? 0) + 1
        let snippet = TextExpansionSnippet(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            trigger: trigger,
            body: snippetBody.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: mode,
            isEnabled: isEnabled,
            scope: .global,
            revision: revision,
            createdAt: selectedSnippet?.createdAt ?? now,
            updatedAt: now,
            sourceDeviceID: selectedSnippet?.sourceDeviceID
        )
        do {
            try dataStore.upsertTextExpansionSnippet(snippet)
            selectedID = id
            statusMessage = "Saved \(snippet.activationToken)"
            reloadSnippets()
            dismissStatusAfterDelay()
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func deleteSelectedSnippet() {
        guard let selectedID else { return }
        do {
            try dataStore.deleteTextExpansionSnippet(id: selectedID)
            self.selectedID = nil
            statusMessage = "Deleted"
            reloadSnippets(selectFirst: true)
            dismissStatusAfterDelay()
        } catch {
            statusMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func dismissStatusAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(DesignSystem.Animation.gentle) {
                statusMessage = nil
            }
        }
    }

    private func exportSnapshotIfNeeded() {
        guard settingsManager.textExpansion.exportKeyboardSnapshotEnabled,
              let url = TextExpansionSnapshotStore.snapshotURL() else { return }
        let active = snippets.filter { $0.isActive }
        try? TextExpansionSnapshotStore.write(TextExpansionSnapshot(snippets: active), to: url)
    }
}
