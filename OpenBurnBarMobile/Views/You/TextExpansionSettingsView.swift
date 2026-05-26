import SwiftUI
import OpenBurnBarCore

struct MobileTextExpansionSettingsView: View {
    @State private var store = MobileTextExpansionStore()
    @State private var editingID: String?
    @State private var title = ""
    @State private var trigger = ""
    @State private var snippetBody = ""
    @State private var mode: TextExpansionMode = .staticText
    @State private var isEnabled = true
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isSyncing = false
    @AppStorage("textExpansion.cloudSyncEnabled") private var cloudSyncEnabled = true
    @Environment(\.colorScheme) private var colorScheme

    private var editingSnippet: TextExpansionSnippet? {
        store.snippets.first { $0.id == editingID }
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
        return store.snippets.contains { snippet in
            snippet.id != editingID && snippet.deletedAt == nil && snippet.trigger == canonical
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
        ZStack {
            AuroraBackdrop(density: .subtle)
            Form {
                editorSection
                savedSection
                cloudSyncSection
                keyboardSection
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Text Expansion")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                newDraft()
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    // MARK: - Editor Section

    private var editorSection: some View {
        Section {
            // Trigger chip preview
            if !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: MobileTheme.Spacing.sm) {
                    Text(trigger.hasPrefix("&&") ? trigger : "&&\(trigger)")
                        .font(MobileTheme.Typography.mono)
                        .foregroundStyle(MobileTheme.hermesAureate)
                        .padding(.horizontal, MobileTheme.Spacing.sm)
                        .padding(.vertical, MobileTheme.Spacing.xs)
                        .background(
                            Capsule()
                                .fill(MobileTheme.hermesAureate.opacity(0.12))
                        )
                        .overlay(
                            Capsule()
                                .stroke(MobileTheme.hermesAureate.opacity(0.25), lineWidth: 0.75)
                        )
                    modeBadge(for: mode)
                }
                .listRowBackground(Color.clear)
            }

            TextField("Name", text: $title)
                .font(MobileTheme.Typography.body)
                .listRowBackground(rowBackground)

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                TextField("Trigger", text: $trigger)
                    .font(MobileTheme.Typography.mono)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let triggerError {
                    Label(triggerError, systemImage: "exclamationmark.triangle.fill")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.error)
                }
                if let duplicateTriggerError {
                    Label(duplicateTriggerError, systemImage: "exclamationmark.triangle.fill")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.error)
                }
            }
            .listRowBackground(rowBackground)

            TextEditor(text: $snippetBody)
                .font(MobileTheme.Typography.body)
                .frame(minHeight: 120)
                .listRowBackground(rowBackground)

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                Picker("Mode", selection: $mode) {
                    Text("Static").tag(TextExpansionMode.staticText)
                    Text("Mac LLM Preview").tag(TextExpansionMode.llmRewrite)
                }
                Text(mode == .staticText
                     ? "Expands to your exact text in all surfaces."
                     : "On Mac, rewrites using chat context. On mobile, expands as static text.")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.textMuted)
            }
            .listRowBackground(rowBackground)

            Toggle("Enabled", isOn: $isEnabled)
                .tint(MobileTheme.ember)
                .listRowBackground(rowBackground)

            // Save button + status
            VStack(spacing: MobileTheme.Spacing.sm) {
                Button {
                    save()
                } label: {
                    Label(editingID == nil ? "Save Snippet" : "Update Snippet", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(MobileTheme.ember)
                .disabled(!canSave)

                if editingID != nil {
                    Button {
                        newDraft()
                    } label: {
                        Text("Cancel Editing")
                            .font(MobileTheme.Typography.caption)
                    }
                    .foregroundStyle(MobileTheme.textMuted)
                }

                if let statusMessage {
                    HStack(spacing: MobileTheme.Spacing.xs) {
                        Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 11))
                        Text(statusMessage)
                            .font(MobileTheme.Typography.tiny)
                    }
                    .foregroundStyle(statusIsError ? MobileTheme.error : MobileTheme.success)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .listRowBackground(Color.clear)
        } header: {
            groupHeader(editingID == nil ? "New Snippet" : "Edit Snippet")
        }
    }

    // MARK: - Saved Section

    private var savedSection: some View {
        Section {
            if store.snippets.isEmpty {
                VStack(spacing: MobileTheme.Spacing.md) {
                    Image(systemName: "text.cursor")
                        .font(.system(size: 32))
                        .foregroundStyle(MobileTheme.textMuted)
                    Text("No snippets yet")
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.textSecondary)
                    Text("Create your first &&trigger above")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, MobileTheme.Spacing.xl)
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.snippets) { snippet in
                    Button {
                        load(snippet)
                    } label: {
                        HStack(spacing: MobileTheme.Spacing.md) {
                            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                                HStack(spacing: MobileTheme.Spacing.sm) {
                                    Text(snippet.title)
                                        .font(MobileTheme.Typography.body)
                                        .foregroundStyle(MobileTheme.textPrimary)
                                        .lineLimit(1)
                                    if !snippet.isEnabled {
                                        Image(systemName: "circle.slash")
                                            .font(.system(size: 10))
                                            .foregroundStyle(MobileTheme.textMuted)
                                    }
                                }
                                HStack(spacing: MobileTheme.Spacing.sm) {
                                    Text(snippet.activationToken)
                                        .font(MobileTheme.Typography.monoSmall)
                                        .foregroundStyle(MobileTheme.textSecondary)
                                    modeBadge(for: snippet.mode)
                                }
                                Text(relativeTime(snippet.updatedAt))
                                    .font(MobileTheme.Typography.monoTiny)
                                    .foregroundStyle(MobileTheme.textMuted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(MobileTheme.textMuted)
                        }
                    }
                    .opacity(snippet.isEnabled ? 1 : 0.55)
                    .listRowBackground(rowBackground)
                }
                .onDelete { offsets in
                    for index in offsets {
                        store.delete(id: store.snippets[index].id)
                    }
                }
            }
        } header: {
            groupHeader("Saved Snippets")
        }
    }

    // MARK: - Keyboard Section

    private var keyboardSection: some View {
        Section {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                Label("Keyboard Extension", systemImage: "keyboard")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.textPrimary)
                Text("Enable OpenBurnBar Keyboard in Settings → General → Keyboard → Keyboards to expand &&triggers in any app. Only static snippets expand on the keyboard.")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.textMuted)
            }
            .listRowBackground(rowBackground)
        } header: {
            groupHeader("Integration")
        }
    }

    // MARK: - Cloud Sync Section

    private var cloudSyncSection: some View {
        Section {
            Toggle("Sync across devices", isOn: $cloudSyncEnabled)
                .tint(MobileTheme.ember)
                .listRowBackground(rowBackground)
            if cloudSyncEnabled {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                    Button {
                        isSyncing = true
                        Task {
                            await store.syncCloud()
                            isSyncing = false
                        }
                    } label: {
                        HStack(spacing: MobileTheme.Spacing.sm) {
                            if isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Label(isSyncing ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isSyncing)
                    Text("Encrypted end-to-end via Cloud Vault.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.textMuted)
                }
                .listRowBackground(rowBackground)
            }
        } header: {
            groupHeader("Cloud Sync")
        }
    }

    // MARK: - Helpers

    private var rowBackground: Color {
        Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60)
    }

    @ViewBuilder
    private func modeBadge(for snippetMode: TextExpansionMode) -> some View {
        if snippetMode == .llmRewrite {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                Text("Mac LLM")
                    .font(MobileTheme.Typography.tiny)
            }
            .foregroundStyle(MobileTheme.hermesAureate)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(MobileTheme.hermesAureate.opacity(0.12))
            )
        } else {
            Text("Static")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(MobileTheme.textMuted.opacity(0.12))
                )
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(MobileTheme.Typography.tiny)
            .fontWeight(.semibold)
            .tracking(1.4)
            .foregroundStyle(MobileTheme.Colors.textMuted)
    }

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

    private func load(_ snippet: TextExpansionSnippet) {
        editingID = snippet.id
        title = snippet.title
        trigger = snippet.activationToken
        snippetBody = snippet.body
        mode = snippet.mode
        isEnabled = snippet.isEnabled
    }

    private func newDraft() {
        editingID = nil
        title = ""
        trigger = ""
        snippetBody = ""
        mode = .staticText
        isEnabled = true
        statusMessage = nil
    }

    private func save() {
        let now = Date()
        let snippet = TextExpansionSnippet(
            id: editingID ?? UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            trigger: trigger,
            body: snippetBody.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: mode,
            isEnabled: isEnabled,
            scope: .global,
            revision: (editingSnippet?.revision ?? 0) + 1,
            createdAt: editingSnippet?.createdAt ?? now,
            updatedAt: now
        )
        editingID = snippet.id
        store.upsert(snippet)
        withAnimation(MobileTheme.Animation.standard) {
            statusMessage = "Saved \(snippet.activationToken)"
            statusIsError = false
        }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(MobileTheme.Animation.gentle) {
                statusMessage = nil
            }
        }
    }
}
