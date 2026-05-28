import SwiftUI
import OpenBurnBarCore
#if canImport(AppKit)
import AppKit
import ApplicationServices
#if !DISTRIBUTION_MAS
import OpenBurnBarComputerUseCore
#endif
#endif

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

    // Custom States for REDESIGN
    @State private var searchQuery = ""
    @State private var sandboxText = ""
    @State private var sandboxSuccess = false
    #if canImport(AppKit) && !DISTRIBUTION_MAS
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    #endif

    private enum Field: Hashable {
        case title
        case trigger
        case body
        case sandbox
    }
    @FocusState private var focusedField: Field?

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

    private var filteredSnippets: [TextExpansionSnippet] {
        let activeSnippets = snippets.filter { $0.deletedAt == nil }
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
            HStack(spacing: 0) {
                snippetList
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                    .background(DesignSystem.Colors.surface.opacity(0.45))

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

            // Floating Premium Toast Notification
            if let statusMessage {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: statusMessage.contains("failed") || statusMessage.contains("Could not")
                              ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(
                                statusMessage.contains("failed") || statusMessage.contains("Could not")
                                ? DesignSystem.Colors.error : DesignSystem.Colors.success
                            )
                        Text(statusMessage)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 24)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .zIndex(999)
            }
        }
        .task { reloadSnippets(selectFirst: true) }
        #if canImport(AppKit) && !DISTRIBUTION_MAS
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
        }
        #endif
        .animation(DesignSystem.Animation.standard, value: statusMessage)
    }

    // MARK: - Snippet List

    private var snippetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                Text("Snippets")
                    .font(DesignSystem.Typography.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Button {
                    createDraft()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(DesignSystem.Colors.ember)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Create new trigger")
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.top, DesignSystem.Spacing.md)
            .padding(.bottom, DesignSystem.Spacing.sm)

            // Dynamic Search Box
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                TextField("Search trigger or text...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(DesignSystem.Colors.surfaceMuted.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.75)
            )
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.bottom, DesignSystem.Spacing.sm)

            if filteredSnippets.isEmpty {
                VStack(spacing: DesignSystem.Spacing.md) {
                    Spacer()
                    Image(systemName: "text.cursor")
                        .font(.system(size: 40))
                        .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.7))
                    Text(searchQuery.isEmpty ? "No snippets yet" : "No matches found")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text(searchQuery.isEmpty ? "Create your first &&trigger" : "Try adjusting your filter query")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    if searchQuery.isEmpty {
                        Button {
                            createDraft()
                        } label: {
                            Label("New Snippet", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(DesignSystem.Colors.ember)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(filteredSnippets) { snippet in
                            let isSelected = snippet.id == selectedID
                            SnippetCardView(
                                snippet: snippet,
                                isSelected: isSelected,
                                onSelect: {
                                    selectedID = snippet.id
                                },
                                onToggle: {
                                    toggleSnippet(snippet)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.automatic)
                .onChange(of: selectedID) { _, _ in loadSelectedSnippet() }
            }
        }
    }

    // MARK: - Runtime Section

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsSectionHeader(title: "Runtime Settings")

            #if !DISTRIBUTION_MAS
            globalMacExpansionCard
            #endif

            VStack(spacing: 1) {
                SettingsToggle(
                    title: "Expand inside OpenBurnBar chat",
                    subtitle: "Static snippets insert immediately. LLM snippets open a preview before insertion.",
                    icon: "bubble.left.and.text.bubble.right.fill",
                    isOn: binding(\.inAppExpansionEnabled)
                )

                Divider().padding(.leading, 48)
                SettingsToggle(
                    title: "Allow LLM rewrite previews",
                    subtitle: "Uses the active OpenBurnBar chat backend and the current thread context when available.",
                    icon: "sparkles",
                    isOn: binding(\.llmRewritePreviewEnabled)
                )

                Divider().padding(.leading, 48)
                SettingsToggle(
                    title: "Share snippets with keyboard extensions",
                    subtitle: "Writes an App Group snapshot for iPhone, iPad, and Android surfaces that cannot open the main database.",
                    icon: "iphone.and.arrow.forward",
                    isOn: binding(\.exportKeyboardSnapshotEnabled)
                )

                Divider().padding(.leading, 48)
                SettingsToggle(
                    title: "Sync snippets across devices",
                    subtitle: "Encrypted end-to-end. Uses your Cloud Vault key to sync via Firestore.",
                    icon: "icloud",
                    isOn: binding(\.cloudSyncEnabled)
                )
            }
            .background(DesignSystem.Colors.surfaceElevated.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.75)
            )
        }
        .settingsAnchor(SettingsAnchor.textExpansionRuntime)
        #if canImport(AppKit) && !DISTRIBUTION_MAS
        .onChange(of: settingsManager.textExpansion.macGlobalExpansionEnabled) { _, enabled in
            guard enabled, !accessibilityTrusted else { return }
            requestAccessibilityPermission()
        }
        #endif
    }

    #if canImport(AppKit) && !DISTRIBUTION_MAS
    private var globalMacExpansionCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            globalMacExpansionStatusBanner

            SettingsToggle(
                title: "Expand in other Mac apps",
                subtitle: "Required for TextEdit, Mail, Safari, and every app outside OpenBurnBar.",
                icon: "keyboard",
                isOn: binding(\.macGlobalExpansionEnabled)
            )
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs)

            if settingsManager.textExpansion.macGlobalExpansionEnabled && !accessibilityTrusted {
                accessibilityPermissionCallout
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(globalMacExpansionCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(globalMacExpansionCardBorder, lineWidth: settingsManager.textExpansion.macGlobalExpansionEnabled ? 0.75 : 1.25)
        )
    }

    @ViewBuilder
    private var globalMacExpansionStatusBanner: some View {
        if settingsManager.textExpansion.macGlobalExpansionEnabled {
            if accessibilityTrusted {
                globalMacExpansionBanner(
                    icon: "checkmark.circle.fill",
                    iconColor: DesignSystem.Colors.success,
                    title: "Other Mac apps: On",
                    message: "&& triggers expand in TextEdit, Mail, Safari, and other apps.",
                    background: DesignSystem.Colors.success.opacity(0.10),
                    showEnableButton: false
                )
            }
        } else {
            globalMacExpansionBanner(
                icon: "macbook.and.arrow.down",
                iconColor: DesignSystem.Colors.warning,
                title: "Other Mac apps: Off",
                message: "Snippets only work inside OpenBurnBar chat right now. Flip the switch below to expand && triggers everywhere on your Mac.",
                background: DesignSystem.Colors.warning.opacity(0.12),
                showEnableButton: true
            )
        }
    }

    private func globalMacExpansionBanner(
        icon: String,
        iconColor: Color,
        title: String,
        message: String,
        background: Color,
        showEnableButton: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
                .background(iconColor.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(DesignSystem.Typography.caption.weight(.bold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(message)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if showEnableButton {
                    Button {
                        settingsManager.textExpansion.macGlobalExpansionEnabled = true
                    } label: {
                        Label("Enable for other Mac apps", systemImage: "switch.2")
                            .font(DesignSystem.Typography.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.ember)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.sm)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var globalMacExpansionCardBackground: Color {
        if settingsManager.textExpansion.macGlobalExpansionEnabled {
            return DesignSystem.Colors.surfaceElevated.opacity(0.7)
        }
        return DesignSystem.Colors.warning.opacity(0.05)
    }

    private var globalMacExpansionCardBorder: Color {
        if settingsManager.textExpansion.macGlobalExpansionEnabled {
            return accessibilityTrusted
                ? DesignSystem.Colors.success.opacity(0.35)
                : DesignSystem.Colors.borderSubtle
        }
        return DesignSystem.Colors.warning.opacity(0.45)
    }
    #endif

    #if canImport(AppKit) && !DISTRIBUTION_MAS
    private var accessibilityPermissionCallout: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "accessibility")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                .frame(width: 32, height: 32)
                .background(DesignSystem.Colors.hermesAureate.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Accessibility permission needed")
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Open System Settings → Privacy & Security → Accessibility, then turn on OpenBurnBar.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Spacer()

            Button("Open System Settings") {
                requestAccessibilityPermission()
            }
            .buttonStyle(.bordered)
        }
        .padding(DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.hermesAureate.opacity(0.08))
    }

    private func requestAccessibilityPermission() {
        accessibilityTrusted = MacAccessibilityPermissionRequester.promptAndOpenSettings()
    }
    #endif

    // MARK: - Editor

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsSectionHeader(title: selectedSnippet == nil ? "Create Snippet" : "Snippet Configuration")

            // Editor card
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {

                // Real-time Visual Trigger Chip Preview
                HStack(spacing: DesignSystem.Spacing.sm) {
                    if !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(trigger.hasPrefix("&&") ? trigger : "&&\(trigger)")
                            .font(DesignSystem.Typography.mono)
                            .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DesignSystem.Colors.hermesAureate.opacity(0.12))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(DesignSystem.Colors.hermesAureate.opacity(0.3), lineWidth: 1)
                            )
                            .shadow(color: DesignSystem.Colors.hermesAureate.opacity(0.1), radius: 3)
                    } else {
                        Text("&&trigger-preview")
                            .font(DesignSystem.Typography.mono)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DesignSystem.Colors.surfaceMuted)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.75)
                            )
                    }
                    modeBadge(for: mode)

                    Spacer()

                    if selectedSnippet != nil {
                        Text("✨ Saved snippet")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(DesignSystem.Colors.hermesAureate.opacity(0.08)))
                    }
                }

                // Grid Inputs
                VStack(spacing: DesignSystem.Spacing.md) {
                    // Name Field
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Name")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fontWeight(.medium)

                        TextField("Confident reply", text: $title)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(DesignSystem.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(focusedField == .title ? DesignSystem.Colors.hermesAureate : DesignSystem.Colors.borderSubtle, lineWidth: focusedField == .title ? 1.5 : 0.75)
                            )
                            .shadow(color: focusedField == .title ? DesignSystem.Colors.hermesAureate.opacity(0.15) : Color.clear, radius: 4)
                            .focused($focusedField, equals: .title)
                    }

                    // Trigger Field
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Trigger Token")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fontWeight(.medium)

                        HStack(spacing: 0) {
                            Text("&&")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                                .padding(.leading, 10)
                                .padding(.trailing, 2)

                            TextField("confident", text: $trigger)
                                .textFieldStyle(.plain)
                                .font(.system(.body, design: .monospaced))
                                .padding(.vertical, 7)
                                .padding(.trailing, 10)
                        }
                        .background(DesignSystem.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(focusedField == .trigger ? DesignSystem.Colors.hermesAureate : DesignSystem.Colors.borderSubtle, lineWidth: focusedField == .trigger ? 1.5 : 0.75)
                        )
                        .shadow(color: focusedField == .trigger ? DesignSystem.Colors.hermesAureate.opacity(0.15) : Color.clear, radius: 4)
                        .focused($focusedField, equals: .trigger)

                        if let triggerError {
                            Label(triggerError, systemImage: "exclamationmark.triangle.fill")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.error)
                                .padding(.top, 2)
                        } else if let duplicateTriggerError {
                            Label(duplicateTriggerError, systemImage: "exclamationmark.triangle.fill")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.error)
                                .padding(.top, 2)
                        }
                    }

                    // Mode Picker Row
                    HStack(spacing: DesignSystem.Spacing.lg) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Expansion Mode")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .fontWeight(.medium)
                            Text(mode == .llmRewrite
                                 ? "Rewrites text dynamically using LLM thread context."
                                 : "Inserts exact matching text immediately.")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }

                        Spacer()

                        Picker("", selection: $mode) {
                            Text("Static").tag(TextExpansionMode.staticText)
                            Text("LLM Preview").tag(TextExpansionMode.llmRewrite)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                    .padding(.vertical, 4)
                }

                // Text Expansion Body Editor
                VStack(alignment: .leading, spacing: 6) {
                    Text("Snippet Content")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fontWeight(.medium)

                    TextEditor(text: $snippetBody)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140, maxHeight: 180)
                        .padding(8)
                        .background(DesignSystem.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(focusedField == .body ? DesignSystem.Colors.hermesAureate : DesignSystem.Colors.borderSubtle, lineWidth: focusedField == .body ? 1.5 : 0.75)
                        )
                        .shadow(color: focusedField == .body ? DesignSystem.Colors.hermesAureate.opacity(0.15) : Color.clear, radius: 4)
                        .focused($focusedField, equals: .body)
                }

                // Preview Box
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live Preview")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fontWeight(.semibold)

                    Group {
                        if mode == .llmRewrite {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                                Text("Dynamic Preview: Matches context and rewrites using the active LLM engine.")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .italic()
                            }
                        } else {
                            Text(snippetBody.isEmpty ? "Type snippet content above to view expansion..." : snippetBody)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(snippetBody.isEmpty ? DesignSystem.Colors.textMuted : DesignSystem.Colors.textPrimary)
                                .lineLimit(3)
                        }
                    }
                    .padding(DesignSystem.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignSystem.Colors.surfaceMuted.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                    )
                }

                // INTERACTIVE LIVE SANDBOX (HOLY SHIT! feature)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Live Expansion Sandbox", systemImage: "play.circle.fill")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            .fontWeight(.bold)

                        Spacer()

                        if sandboxSuccess {
                            Text("✨ Snippet Expanded Live!")
                                .font(DesignSystem.Typography.tiny)
                                .fontWeight(.bold)
                                .foregroundStyle(DesignSystem.Colors.success)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

                    Text("Test ground: Type `\(sandboxHintActivationToken)` below to trigger instant expansion:")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    TextField("Test expanding your shortcuts here...", text: $sandboxText)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .padding(10)
                        .background(DesignSystem.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(sandboxSuccess ? DesignSystem.Colors.success : (focusedField == .sandbox ? DesignSystem.Colors.hermesAureate : DesignSystem.Colors.borderSubtle), lineWidth: sandboxSuccess || focusedField == .sandbox ? 1.5 : 0.75)
                        )
                        .shadow(color: sandboxSuccess ? DesignSystem.Colors.success.opacity(0.15) : (focusedField == .sandbox ? DesignSystem.Colors.hermesAureate.opacity(0.15) : Color.clear), radius: 4)
                        .focused($focusedField, equals: .sandbox)
                        .onChange(of: sandboxText) { _, newValue in
                            handleSandboxInput(newValue)
                        }
                }
                .padding(14)
                .background(DesignSystem.Colors.surfaceMuted.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.75)
                )

                // Action buttons
                HStack(spacing: DesignSystem.Spacing.md) {
                    Button {
                        saveSnippet()
                    } label: {
                        Label("Save Snippet", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.ember)
                    .disabled(!canSave)

                    Button(role: .destructive) {
                        deleteSelectedSnippet()
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 6)
                    }
                    .disabled(selectedSnippet == nil)

                    Spacer()

                    if selectedSnippet != nil {
                        Button {
                            createDraft()
                        } label: {
                            Text("New Draft")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
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
                    .font(.system(size: 9, weight: .bold))
                Text("LLM")
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.bold)
            }
            .foregroundStyle(DesignSystem.Colors.hermesAureate)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.hermesAureate.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .stroke(DesignSystem.Colors.hermesAureate.opacity(0.25), lineWidth: 0.5)
            )
        } else {
            Text("Static")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(DesignSystem.Colors.surfaceMuted)
                )
                .overlay(
                    Capsule()
                        .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
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
                selectedID = snippets.first { $0.deletedAt == nil }?.id
            }
            loadSelectedSnippet()
            exportSnapshotIfNeeded()
        } catch {
            showToast("Could not load snippets: \(error.localizedDescription)")
        }
    }

    private func loadSelectedSnippet() {
        guard let snippet = selectedSnippet else { return }
        title = snippet.title
        trigger = snippet.activationToken.replacingOccurrences(of: "&&", with: "")
        snippetBody = snippet.body
        mode = snippet.mode
        isEnabled = snippet.isEnabled
    }

    private func createDraft() {
        selectedID = nil
        title = ""
        trigger = ""
        snippetBody = ""
        mode = .staticText
        isEnabled = true
        focusedField = .title
    }

    private func saveSnippet() {
        let now = Date()
        let id = selectedSnippet?.id ?? UUID().uuidString
        let revision = (selectedSnippet?.revision ?? 0) + 1

        let token = trigger.hasPrefix("&&") ? trigger : "&&\(trigger)"

        let snippet = TextExpansionSnippet(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            trigger: token,
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
            showToast("Saved \(snippet.activationToken) successfully")
            reloadSnippets()
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
        }
    }

    private func deleteSelectedSnippet() {
        guard let selectedID else { return }
        do {
            try dataStore.deleteTextExpansionSnippet(id: selectedID)
            self.selectedID = nil
            showToast("Snippet deleted successfully")
            reloadSnippets(selectFirst: true)
        } catch {
            showToast("Delete failed: \(error.localizedDescription)")
        }
    }

    private func toggleSnippet(_ snippet: TextExpansionSnippet) {
        var updated = snippet
        updated.isEnabled.toggle()
        updated.updatedAt = Date()
        updated.revision += 1
        do {
            try dataStore.upsertTextExpansionSnippet(updated)
            showToast("\(updated.isEnabled ? "Enabled" : "Disabled") \(updated.activationToken)")
            reloadSnippets()
        } catch {
            showToast("Failed to toggle: \(error.localizedDescription)")
        }
    }

    private var sandboxHintActivationToken: String {
        let canonical = TextExpansionTrigger.canonicalName(trigger)
        guard !canonical.isEmpty else { return "&&confident" }
        return TextExpansionTrigger.activationToken(for: canonical)
    }

    private var sandboxMatcherSnippets: [TextExpansionSnippet] {
        var candidates = snippets.filter(\.isActive)
        guard let draft = sandboxDraftSnippet else { return candidates }
        candidates.removeAll { $0.id == draft.id || $0.trigger == draft.trigger }
        candidates.insert(draft, at: 0)
        return candidates
    }

    private var sandboxDraftSnippet: TextExpansionSnippet? {
        let canonical = TextExpansionTrigger.canonicalName(trigger)
        guard !canonical.isEmpty,
              TextExpansionTrigger.validationError(for: canonical) == nil,
              !snippetBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let now = Date()
        return TextExpansionSnippet(
            id: selectedSnippet?.id ?? "__draft__",
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            trigger: canonical,
            body: snippetBody.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: mode,
            isEnabled: isEnabled,
            scope: .global,
            revision: selectedSnippet?.revision ?? 1,
            createdAt: selectedSnippet?.createdAt ?? now,
            updatedAt: now,
            sourceDeviceID: selectedSnippet?.sourceDeviceID
        )
    }

    private func handleSandboxInput(_ newValue: String) {
        guard let result = TextExpansionMatcher.expandStaticIfAvailable(
            in: newValue,
            snippets: sandboxMatcherSnippets,
            surface: .inAppThread
        ), result.text != newValue else {
            return
        }
        sandboxText = result.text
        showSandboxSuccess()
    }

    private func showSandboxSuccess() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            sandboxSuccess = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation {
                sandboxSuccess = false
            }
        }
    }

    private func showToast(_ message: String) {
        withAnimation(DesignSystem.Animation.gentle) {
            statusMessage = message
        }
        dismissStatusAfterDelay()
    }

    private func dismissStatusAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(DesignSystem.Animation.gentle) {
                if statusMessage != nil {
                    statusMessage = nil
                }
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

// MARK: - Subviews forRedesign

struct SnippetCardView: View {
    let snippet: TextExpansionSnippet
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                // Glow indicator strip on left
                RoundedRectangle(cornerRadius: 2)
                    .fill(snippet.isEnabled ? AnyShapeStyle(DesignSystem.Colors.primaryGradient) : AnyShapeStyle(DesignSystem.Colors.textMuted.opacity(0.3)))
                    .frame(width: 4)
                    .padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(snippet.title.isEmpty ? "Untitled snippet" : snippet.title)
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.medium)
                            .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textPrimary.opacity(0.9))
                            .lineLimit(1)

                        Spacer()

                        modeBadge(for: snippet.mode)
                    }

                    HStack {
                        Text(snippet.activationToken)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(snippet.isEnabled ? DesignSystem.Colors.hermesAureate : DesignSystem.Colors.textMuted)

                        Spacer()

                        Text(relativeTime(snippet.updatedAt))
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)

                // Simple Inline Quick Toggle for SOTA Redesign
                Button(action: onToggle) {
                    Image(systemName: snippet.isEnabled ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(snippet.isEnabled ? DesignSystem.Colors.ember : DesignSystem.Colors.textMuted.opacity(0.6))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(snippet.isEnabled ? "Disable snippet" : "Enable snippet")
            }
            .padding(.vertical, 6)
            .padding(.trailing, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? DesignSystem.Colors.surfaceElevated : (isHovered ? DesignSystem.Colors.surfaceElevated.opacity(0.4) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? DesignSystem.Colors.hermesAureate.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.015 : 1.0)
            .shadow(color: isSelected ? DesignSystem.Colors.hermesAureate.opacity(0.08) : Color.clear, radius: 4)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .opacity(snippet.isEnabled ? 1.0 : 0.65)
    }

    @ViewBuilder
    private func modeBadge(for snippetMode: TextExpansionMode) -> some View {
        if snippetMode == .llmRewrite {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                .padding(4)
                .background(Circle().fill(DesignSystem.Colors.hermesAureate.opacity(0.12)))
        } else {
            Image(systemName: "doc.text")
                .font(.system(size: 9))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .padding(4)
                .background(Circle().fill(DesignSystem.Colors.surfaceMuted))
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
