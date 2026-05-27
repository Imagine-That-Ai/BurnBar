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

    // Custom States for REDESIGN
    @State private var searchQuery = ""
    @State private var sandboxText = ""
    @State private var sandboxSuccess = false

    private enum Field: Hashable {
        case title
        case trigger
        case body
        case sandbox
    }
    @FocusState private var focusedField: Field?

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

    private var filteredSnippets: [TextExpansionSnippet] {
        let activeSnippets = store.snippets.filter { $0.deletedAt == nil }
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return activeSnippets
        }
        let query = searchQuery.lowercased()
        return activeSnippets.filter {
            $0.title.lowercased().contains(query) ||
            $0.activationToken.lowercased().contains(query) ||
            $0.body.lowercased().contains(query)
        }
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)

            ScrollView {
                VStack(spacing: 20) {

                    // 1. Editor Canvas
                    editorCard
                        .padding(.top, 10)

                    // 2. Saved Snippets List Section
                    savedSnippetsCard

                    // 3. Interactive Sandbox Testing Card
                    sandboxCard

                    // 4. Cloud Sync Section
                    cloudSyncCard

                    // 5. Integration / Keyboard Details Card
                    keyboardCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)

            // Floating toast feedback notification
            if let statusMessage {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(statusIsError ? MobileTheme.error : MobileTheme.success)
                        Text(statusMessage)
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.textPrimary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 12)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .zIndex(99)
            }
        }
        .navigationTitle("Text Expansion")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newDraft()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(MobileTheme.ember)
                }
            }
        }
        .animation(MobileTheme.Animation.standard, value: statusMessage)
    }

    // MARK: - Editor Card

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(editingID == nil ? "NEW SNIPPET" : "EDIT SNIPPET")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.bold)
                    .tracking(1.4)
                    .foregroundStyle(MobileTheme.Colors.textMuted)

                Spacer()

                if editingID != nil {
                    Text("✨ Editing Active")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.hermesAureate)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(MobileTheme.hermesAureate.opacity(0.12)))
                }
            }

            // Live Preview of Trigger Chip
            HStack(spacing: 8) {
                if !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(trigger.hasPrefix("&&") ? trigger : "&&\(trigger)")
                        .font(MobileTheme.Typography.mono)
                        .foregroundStyle(MobileTheme.hermesAureate)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(MobileTheme.hermesAureate.opacity(0.12)))
                        .overlay(Capsule().stroke(MobileTheme.hermesAureate.opacity(0.25), lineWidth: 0.75))
                } else {
                    Text("&&trigger")
                        .font(MobileTheme.Typography.mono)
                        .foregroundStyle(MobileTheme.textMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.04)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                }

                modeBadge(for: mode)
            }

            VStack(spacing: 12) {
                // Name Field
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.textSecondary)

                    TextField("Confident reply", text: $title)
                        .font(MobileTheme.Typography.body)
                        .padding(10)
                        .background(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.40))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(focusedField == .title ? MobileTheme.hermesAureate : Color.white.opacity(0.12), lineWidth: focusedField == .title ? 1.5 : 1)
                        )
                        .focused($focusedField, equals: .title)
                }

                // Trigger Field
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trigger")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.textSecondary)

                    HStack(spacing: 0) {
                        Text("&&")
                            .font(MobileTheme.Typography.mono)
                            .foregroundStyle(MobileTheme.hermesAureate)
                            .padding(.leading, 10)

                        TextField("confident", text: $trigger)
                            .font(MobileTheme.Typography.mono)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.vertical, 10)
                            .padding(.trailing, 10)
                    }
                    .background(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.40))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(focusedField == .trigger ? MobileTheme.hermesAureate : Color.white.opacity(0.12), lineWidth: focusedField == .trigger ? 1.5 : 1)
                    )
                    .focused($focusedField, equals: .trigger)

                    if let triggerError {
                        Label(triggerError, systemImage: "exclamationmark.triangle.fill")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.error)
                            .padding(.leading, 4)
                    }
                    if let duplicateTriggerError {
                        Label(duplicateTriggerError, systemImage: "exclamationmark.triangle.fill")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.error)
                            .padding(.leading, 4)
                    }
                }

                // Content Body TextEditor
                VStack(alignment: .leading, spacing: 6) {
                    Text("Expansion Text")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.textSecondary)

                    TextEditor(text: $snippetBody)
                        .font(MobileTheme.Typography.body)
                        .frame(minHeight: 100)
                        .padding(8)
                        .background(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.40))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(focusedField == .body ? MobileTheme.hermesAureate : Color.white.opacity(0.12), lineWidth: focusedField == .body ? 1.5 : 1)
                        )
                        .focused($focusedField, equals: .body)
                }

                // Picker and Enabled Toggles
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Mode", selection: $mode) {
                        Text("Static").tag(TextExpansionMode.staticText)
                        Text("Mac LLM Preview").tag(TextExpansionMode.llmRewrite)
                    }
                    .pickerStyle(.segmented)

                    Text(mode == .staticText
                         ? "Expands to your exact text in all surfaces."
                         : "On Mac, rewrites dynamically using AI chat context. Mobile keyboard expands as static text.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.textMuted)
                        .padding(.horizontal, 2)

                    Divider().padding(.vertical, 4)

                    Toggle("Enabled", isOn: $isEnabled)
                        .tint(MobileTheme.ember)
                }
                .padding(.top, 4)
            }

            // Buttons
            VStack(spacing: 10) {
                Button {
                    save()
                } label: {
                    Label(editingID == nil ? "Save Snippet" : "Update Snippet", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(PremiumButtonStyle(isDestructive: false))
                .disabled(!canSave)

                if editingID != nil {
                    HStack(spacing: 12) {
                        Button {
                            deleteSnippet(editingID!)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(PremiumButtonStyle(isDestructive: true))

                        Button {
                            newDraft()
                        } label: {
                            Text("Cancel Edit")
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(MobileTheme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 8)
        }
        .padding(18)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Saved Snippets Card

    private var savedSnippetsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SAVED SNIPPETS")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.bold)
                    .tracking(1.4)
                    .foregroundStyle(MobileTheme.Colors.textMuted)

                Spacer()

                if !store.snippets.isEmpty {
                    Text("\(store.snippets.count) total")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.textMuted)
                }
            }

            // Inline Search / Filter inside Card
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(MobileTheme.textMuted)
                TextField("Search trigger or content...", text: $searchQuery)
                    .font(MobileTheme.Typography.caption)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(MobileTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(colorScheme == .dark ? 0.15 : 0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 0.5))

            if filteredSnippets.isEmpty {
                VStack(spacing: MobileTheme.Spacing.md) {
                    Image(systemName: "text.cursor")
                        .font(.system(size: 36))
                        .foregroundStyle(MobileTheme.textMuted.opacity(0.7))
                    Text(searchQuery.isEmpty ? "No snippets yet" : "No matching snippets")
                        .font(MobileTheme.Typography.body.weight(.bold))
                        .foregroundStyle(MobileTheme.textSecondary)
                    Text(searchQuery.isEmpty ? "Create your first &&trigger above" : "Adjust your search criteria")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, MobileTheme.Spacing.xl)
            } else {
                VStack(spacing: 10) {
                    ForEach(filteredSnippets) { snippet in
                        Button {
                            load(snippet)
                        } label: {
                            HStack(spacing: 0) {
                                // Dynamic Glowing Strip on left side
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(snippet.isEnabled ? AnyShapeStyle(LinearGradient(colors: [MobileTheme.ember, MobileTheme.amber], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(MobileTheme.textMuted.opacity(0.3)))
                                    .frame(width: 4)
                                    .padding(.vertical, 6)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(snippet.title)
                                            .font(MobileTheme.Typography.body.weight(.medium))
                                            .foregroundStyle(MobileTheme.textPrimary)
                                            .lineLimit(1)
                                        if !snippet.isEnabled {
                                            Image(systemName: "circle.slash")
                                                .font(.system(size: 9))
                                                .foregroundStyle(MobileTheme.textMuted)
                                        }
                                        Spacer()
                                        modeBadge(for: snippet.mode)
                                    }
                                    HStack {
                                        Text(snippet.activationToken)
                                            .font(MobileTheme.Typography.monoSmall)
                                            .foregroundStyle(snippet.isEnabled ? MobileTheme.hermesAureate : MobileTheme.textMuted)

                                        Spacer()

                                        Text(relativeTime(snippet.updatedAt))
                                            .font(MobileTheme.Typography.monoTiny)
                                            .foregroundStyle(MobileTheme.textMuted)
                                    }
                                }
                                .padding(.leading, 12)
                                .padding(.trailing, 4)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(MobileTheme.textMuted)
                                    .padding(.leading, 4)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 8)
                            .background(Color.white.opacity(editingID == snippet.id ? 0.08 : 0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(editingID == snippet.id ? MobileTheme.hermesAureate.opacity(0.4) : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .opacity(snippet.isEnabled ? 1 : 0.6)
                    }
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Sandbox Testing Card

    private var sandboxCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Live Expansion Sandbox", systemImage: "play.circle.fill")
                    .font(MobileTheme.Typography.body.weight(.bold))
                    .foregroundStyle(MobileTheme.hermesAureate)

                Spacer()

                if sandboxSuccess {
                    Text("Expanded!")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.bold)
                        .foregroundStyle(MobileTheme.success)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            let testTrigger = trigger.isEmpty ? "confident" : trigger.replacingOccurrences(of: "&&", with: "")
            Text("Try it: Type `&&\(testTrigger)` followed by a space to instantly watch it expand:")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.textMuted)

            TextField("Test expanding your shortcuts here...", text: $sandboxText)
                .font(MobileTheme.Typography.mono)
                .padding(10)
                .background(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.40))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(sandboxSuccess ? MobileTheme.success : (focusedField == .sandbox ? MobileTheme.hermesAureate : Color.white.opacity(0.12)), lineWidth: sandboxSuccess || focusedField == .sandbox ? 1.5 : 1)
                )
                .focused($focusedField, equals: .sandbox)
                .onChange(of: sandboxText) { _, newValue in
                    handleSandboxInput(newValue)
                }
        }
        .padding(18)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Cloud Sync Card

    private var cloudSyncCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CLOUD SYNC")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.bold)
                .tracking(1.4)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            Toggle("Sync across devices", isOn: $cloudSyncEnabled)
                .tint(MobileTheme.ember)

            if cloudSyncEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()

                    Button {
                        isSyncing = true
                        Task {
                            await store.syncCloud()
                            isSyncing = false
                            showToast("Synchronization complete", isError: false)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(isSyncing ? "Syncing…" : "Sync Now")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PremiumButtonStyle(isDestructive: false))
                    .disabled(isSyncing)

                    Text("Sync is protected and fully encrypted end-to-end via Cloud Vault device keys.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.textMuted)
                        .padding(.horizontal, 2)
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Keyboard Card

    private var keyboardCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INTEGRATION")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.bold)
                .tracking(1.4)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "keyboard")
                    .font(.title2)
                    .foregroundStyle(MobileTheme.hermesAureate)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    Text("System-wide Keyboard Extension")
                        .font(MobileTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(MobileTheme.textPrimary)
                    Text("Go to iOS Settings → General → Keyboard → Keyboards to activate OpenBurnBar. Now, you can trigger your `&&shortcuts` in any browser, chat, or mail application!")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.textMuted)
                        .lineSpacing(2)
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Subviews & Helpers

    @ViewBuilder
    private func modeBadge(for snippetMode: TextExpansionMode) -> some View {
        if snippetMode == .llmRewrite {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                    .font(.system(size: 8, weight: .bold))
                Text("Mac LLM")
                    .font(MobileTheme.Typography.monoTiny)
                    .fontWeight(.bold)
            }
            .foregroundStyle(MobileTheme.hermesAureate)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(MobileTheme.hermesAureate.opacity(0.12)))
            .overlay(Capsule().stroke(MobileTheme.hermesAureate.opacity(0.2), lineWidth: 0.5))
        } else {
            Text("Static")
                .font(MobileTheme.Typography.monoTiny)
                .foregroundStyle(MobileTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        }
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
        trigger = snippet.activationToken.replacingOccurrences(of: "&&", with: "")
        snippetBody = snippet.body
        mode = snippet.mode
        isEnabled = snippet.isEnabled
        focusedField = .title
    }

    private func newDraft() {
        editingID = nil
        title = ""
        trigger = ""
        snippetBody = ""
        mode = .staticText
        isEnabled = true
        focusedField = .title
    }

    private func save() {
        let now = Date()
        let token = trigger.hasPrefix("&&") ? trigger : "&&\(trigger)"

        let snippet = TextExpansionSnippet(
            id: editingID ?? UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            trigger: token,
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

        showToast("Saved \(snippet.activationToken) successfully", isError: false)
    }

    private func deleteSnippet(_ id: String) {
        store.delete(id: id)
        newDraft()
        showToast("Snippet deleted", isError: false)
    }

    private func handleSandboxInput(_ newValue: String) {
        let activeTrigger = trigger.hasPrefix("&&") ? trigger : "&&\(trigger)"
        if !activeTrigger.isEmpty && newValue.hasSuffix(activeTrigger + " ") {
            let prefix = String(newValue.dropLast(activeTrigger.count + 1))
            sandboxText = prefix + snippetBody
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                sandboxSuccess = true
            }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation {
                    sandboxSuccess = false
                }
            }
            return
        }

        for snippet in store.snippets where snippet.isEnabled && snippet.deletedAt == nil {
            let token = snippet.activationToken
            if newValue.hasSuffix(token + " ") {
                let prefix = String(newValue.dropLast(token.count + 1))
                sandboxText = prefix + snippet.body
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    sandboxSuccess = true
                }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation {
                        sandboxSuccess = false
                    }
                }
                break
            }
        }
    }

    private func showToast(_ message: String, isError: Bool) {
        withAnimation(MobileTheme.Animation.gentle) {
            statusMessage = message
            statusIsError = isError
        }
        dismissStatusAfterDelay()
    }

    private func dismissStatusAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(MobileTheme.Animation.gentle) {
                statusMessage = nil
            }
        }
    }
}

// MARK: - PremiumButtonStyle

struct PremiumButtonStyle: ButtonStyle {
    let isDestructive: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MobileTheme.Typography.body.weight(.bold))
            .foregroundStyle(.white)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: !isEnabled
                        ? [Color.gray.opacity(0.3), Color.gray.opacity(0.2)]
                        : (isDestructive
                            ? [MobileTheme.error, MobileTheme.error.opacity(0.8)]
                            : [MobileTheme.ember, MobileTheme.amber]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: (isDestructive ? MobileTheme.error : MobileTheme.ember).opacity(!isEnabled ? 0.0 : (configuration.isPressed ? 0.12 : 0.25)), radius: 6, x: 0, y: 3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.65)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
