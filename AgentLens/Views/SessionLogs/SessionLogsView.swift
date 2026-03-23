import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Source Filter

private enum SessionLogSourceFilter: String, CaseIterable, Identifiable {
    case all      = "All"
    case provider = "Provider"
    case assistant = "Assistant"
    var id: String { rawValue }
}

// MARK: - Session Logs View

struct SessionLogsView: View {
    var dataStore: DataStore
    var accountManager: AccountManager
    var settingsManager: SettingsManager

    @State private var allLogs: [ConversationRecord] = []
    @State private var searchText = ""
    @State private var sourceFilter: SessionLogSourceFilter = .all
    @State private var selectedId: String?
    @State private var listAppeared = false
    @State private var isLoading = false

    // MARK: Filtered list

    private var filteredLogs: [ConversationRecord] {
        var result = allLogs
        switch sourceFilter {
        case .all: break
        case .provider:  result = result.filter { $0.sourceType == .providerLog }
        case .assistant: result = result.filter { $0.sourceType == .cliAssistant }
        }
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return result }
        let q = searchText.lowercased()
        return result.filter {
            $0.inferredTaskTitle.lowercased().contains(q)
                || $0.projectName.lowercased().contains(q)
                || $0.provider.displayName.lowercased().contains(q)
                || $0.fullText.lowercased().contains(q)
        }
    }

    private var selectedLog: ConversationRecord? {
        guard let id = selectedId else { return nil }
        return allLogs.first { $0.id == id }
    }

    // MARK: Body

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(width: 300)

            Divider().background(DesignSystem.Colors.border)

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
        .task {
            await loadLogs()
        }
    }

    // MARK: - List Pane

    private var listPane: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "scroll")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.ember)
                    Text("Session Logs")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .textCase(.uppercase)
                }

                Text("\(filteredLogs.count) log\(filteredLogs.count == 1 ? "" : "s")")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.lg)
            .padding(.bottom, DesignSystem.Spacing.md)

            // Search bar
            searchBar
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.sm)

            // Source filter chips
            sourceFilterRow
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.md)

            Divider().background(DesignSystem.Colors.border.opacity(0.6))

            // List
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if filteredLogs.isEmpty {
                emptyListState
            } else {
                ScrollView {
                    LazyVStack(spacing: DesignSystem.Spacing.xs) {
                        ForEach(Array(filteredLogs.enumerated()), id: \.element.id) { idx, record in
                            SessionLogRow(
                                record: record,
                                isSelected: selectedId == record.id
                            ) {
                                withAnimation(DesignSystem.Animation.snappy) {
                                    selectedId = record.id
                                }
                            }
                            .opacity(listAppeared ? 1 : 0)
                            .offset(y: listAppeared ? 0 : 6)
                            .animation(
                                DesignSystem.Animation.gentle.delay(Double(min(idx, 20)) * 0.025),
                                value: listAppeared
                            )
                        }
                    }
                    .padding(DesignSystem.Spacing.md)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background {
            ZStack {
                DesignSystem.Colors.surface.opacity(0.92)
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.textPrimary.opacity(0.015),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .onAppear { listAppeared = true }
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            TextField("Search logs…", text: $searchText)
                .font(DesignSystem.Typography.caption)
                .textFieldStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            if searchText.isEmpty == false {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                        .strokeBorder(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
                )
        )
    }

    // MARK: Source filter row

    private var sourceFilterRow: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(SessionLogSourceFilter.allCases) { filter in
                Button {
                    withAnimation(DesignSystem.Animation.snappy) {
                        sourceFilter = filter
                    }
                } label: {
                    Text(filter.rawValue)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(
                            sourceFilter == filter
                                ? DesignSystem.Colors.textPrimary
                                : DesignSystem.Colors.textMuted
                        )
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                                .fill(
                                    sourceFilter == filter
                                        ? AnyShapeStyle(filterAccent(for: filter).opacity(0.18))
                                        : AnyShapeStyle(DesignSystem.Colors.surfaceElevated.opacity(0.4))
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                                .strokeBorder(
                                    sourceFilter == filter
                                        ? filterAccent(for: filter).opacity(0.45)
                                        : DesignSystem.Colors.border.opacity(0.3),
                                    lineWidth: 0.5
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func filterAccent(for filter: SessionLogSourceFilter) -> Color {
        switch filter {
        case .all:       return DesignSystem.Colors.ember
        case .provider:  return DesignSystem.Colors.amber
        case .assistant: return DesignSystem.Colors.whimsy
        }
    }

    // MARK: Empty state

    private var emptyListState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Spacer()
            Image(systemName: "scroll")
                .font(.system(size: 36))
                .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.5))

            if !settingsManager.conversationIndexingEnabled && sourceFilter != .assistant {
                Text("Enable conversation indexing")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Turn on indexing in Settings to track your provider sessions here.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
            } else {
                Text(searchText.isEmpty ? "No logs yet" : "No results")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(searchText.isEmpty
                        ? "Start a chat with the BurnBar Assistant, or scan your provider sessions."
                        : "Try a different search term."
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.Spacing.lg)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        if let log = selectedLog {
            SessionLogDetailPane(record: log, dataStore: dataStore)
                .id(log.id)
        } else {
            VStack(spacing: DesignSystem.Spacing.lg) {
                Spacer()
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.4))
                Text("Select a session log")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Pick any log from the list to preview its full Markdown.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Data Loading

    private func loadLogs() async {
        isLoading = true
        do {
            // Synthesize CLI conversation from persisted messages
            let messages = try dataStore.fetchChatMessages()
            if messages.isEmpty == false {
                try dataStore.upsertCLIConversation(from: messages)
            }
            allLogs = try dataStore.fetchAllSessionLogs()
            if selectedId == nil { selectedId = allLogs.first?.id }
        } catch {
            print("SessionLogsView: Failed to load logs: \(error)")
        }
        isLoading = false
    }
}

// MARK: - Session Log Row

private struct SessionLogRow: View {
    let record: ConversationRecord
    let isSelected: Bool
    let action: () -> Void

    private var accentColor: Color {
        record.sourceType == .cliAssistant
            ? DesignSystem.Colors.whimsy
            : DesignSystem.Colors.amber
    }

    private var sourceLabel: String {
        record.sourceType == .cliAssistant
            ? "Assistant"
            : record.provider.displayName
    }

    private var timeLabel: String {
        guard let date = record.endTime ?? record.startTime else {
            return record.indexedAt.relativeLabel
        }
        return date.relativeLabel
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.md) {
                // Source indicator dot
                ZStack {
                    Circle()
                        .fill(isSelected ? accentColor.opacity(0.22) : DesignSystem.Colors.surfaceElevated)
                        .frame(width: 34, height: 34)

                    if record.sourceType == .cliAssistant {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? accentColor : DesignSystem.Colors.textSecondary)
                    } else {
                        ProviderLogoView(provider: record.provider, size: 20, useFallbackColor: false)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.inferredTaskTitle.isEmpty ? "Session" : record.inferredTaskTitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                        .lineLimit(1)

                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(sourceLabel)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(isSelected ? accentColor : DesignSystem.Colors.textMuted)

                        Text("·")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)

                        Text(record.projectName)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(timeLabel)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    Text("\(record.messageCount) msg\(record.messageCount == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .fill(isSelected ? accentColor.opacity(0.09) : DesignSystem.Colors.surfaceElevated.opacity(0.3))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(
                        isSelected ? accentColor.opacity(0.35) : DesignSystem.Colors.border.opacity(0.3),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Session Log Detail Pane

private struct SessionLogDetailPane: View {
    let record: ConversationRecord
    var dataStore: DataStore

    @State private var markdownBody = ""
    @State private var copyConfirmed = false

    private var accentColor: Color {
        record.sourceType == .cliAssistant
            ? DesignSystem.Colors.whimsy
            : DesignSystem.Colors.amber
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            detailHeader
            Divider().background(DesignSystem.Colors.border.opacity(0.5))

            // Markdown preview
            ScrollView {
                Text(.init(markdownBody.isEmpty ? "Loading…" : markdownBody))
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(DesignSystem.Spacing.xl)
            }
            .scrollContentBackground(.hidden)

            Divider().background(DesignSystem.Colors.border.opacity(0.5))

            // Action bar
            actionBar
        }
        .background(Color.clear)
        .task { buildMarkdown() }
    }

    // MARK: Header

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                // Source badge
                HStack(spacing: DesignSystem.Spacing.xs) {
                    if record.sourceType == .cliAssistant {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 9, weight: .semibold))
                    } else {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    Text(record.sourceType == .cliAssistant ? "Assistant" : record.provider.displayName)
                        .font(DesignSystem.Typography.tiny)
                }
                .foregroundStyle(accentColor)
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xxs)
                .background(
                    Capsule().fill(accentColor.opacity(0.14))
                )
                .overlay(
                    Capsule().strokeBorder(accentColor.opacity(0.35), lineWidth: 0.5)
                )

                Text(record.projectName)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Spacer(minLength: 0)

                if let date = record.endTime ?? record.startTime {
                    Text(date.relativeLabel)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            Text(record.inferredTaskTitle.isEmpty ? "Session" : record.inferredTaskTitle)
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Metadata chips
            HStack(spacing: DesignSystem.Spacing.sm) {
                metaChip(icon: "bubble.left.and.bubble.right", label: "\(record.messageCount) messages")
                if record.userWordCount > 0 {
                    metaChip(icon: "textformat", label: "\(record.userWordCount + record.assistantWordCount) words")
                }
                if record.sourceType == .providerLog, let start = record.startTime, let end = record.endTime {
                    let duration = end.timeIntervalSince(start)
                    if duration > 60 {
                        metaChip(icon: "clock", label: durationLabel(duration))
                    }
                }
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .background(Color.clear)
    }

    private func metaChip(icon: String, label: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(label)
                .font(DesignSystem.Typography.tiny)
        }
        .foregroundStyle(DesignSystem.Colors.textMuted)
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xxs)
        .background(
            Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.5))
        )
        .overlay(
            Capsule().strokeBorder(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Spacer()

            // Copy Markdown
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdownBody, forType: .string)
                withAnimation(DesignSystem.Animation.snappy) { copyConfirmed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(DesignSystem.Animation.snappy) { copyConfirmed = false }
                }
            } label: {
                Label(
                    copyConfirmed ? "Copied!" : "Copy Markdown",
                    systemImage: copyConfirmed ? "checkmark" : "doc.on.doc"
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(copyConfirmed ? DesignSystem.Colors.success : accentColor)
            }
            .buttonStyle(.plain)
            .disabled(markdownBody.isEmpty)

            // Export .md
            Button {
                exportMarkdown()
            } label: {
                Label("Export .md", systemImage: "arrow.down.doc")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(markdownBody.isEmpty)
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.md)
    }

    // MARK: Helpers

    private func buildMarkdown() {
        markdownBody = SessionLogMarkdownFormatter.markdown(for: record)
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        let slug = record.inferredTaskTitle.isEmpty ? "session" : record.inferredTaskTitle
        let safe = slug
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
            .prefix(60)
        panel.nameFieldStringValue = "\(safe).md"
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType]
        }
        panel.title = "Export session log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdownBody.write(to: url, atomically: true, encoding: .utf8)
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        return mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m"
    }
}

// MARK: - Date Relative Label

private extension Date {
    var relativeLabel: String {
        let interval = Date().timeIntervalSince(self)
        switch interval {
        case ..<60:          return "Just now"
        case ..<3_600:       return "\(Int(interval / 60))m ago"
        case ..<86_400:      return "\(Int(interval / 3_600))h ago"
        case ..<604_800:     return "\(Int(interval / 86_400))d ago"
        default:
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .none
            return fmt.string(from: self)
        }
    }
}

// MARK: - Session Log Cloud Consent Sheet

struct SessionLogCloudConsentSheet: View {
    @Bindable var settingsManager: SettingsManager
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            // Icon + title
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignSystem.Colors.ember.opacity(0.4),
                                    DesignSystem.Colors.amber.opacity(0.25)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)

                    Image(systemName: "scroll.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Back up session logs to the cloud?")
                        .font(DesignSystem.Typography.title)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("BurnBar can securely back up your full conversation logs — including provider sessions and BurnBar Assistant history — to your private cloud storage. Access and export them from any device.")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Feature bullets
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                featureBullet(
                    icon: "lock.icloud",
                    iconColor: DesignSystem.Colors.whimsy,
                    text: "Stored under your account — no other user can access your logs."
                )
                featureBullet(
                    icon: "arrow.triangle.2.circlepath",
                    iconColor: DesignSystem.Colors.amber,
                    text: "Existing logs are backfilled automatically on first enable."
                )
                featureBullet(
                    icon: "gearshape",
                    iconColor: DesignSystem.Colors.textMuted,
                    text: "Toggle off anytime in Settings → Account."
                )
            }

            Divider().background(DesignSystem.Colors.border.opacity(0.5))

            // Actions
            HStack(spacing: DesignSystem.Spacing.md) {
                Button("Not now") {
                    settingsManager.sessionLogCloudBackupEnabled = false
                    settingsManager.sessionLogCloudBackupConsentShown = true
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Enable Cloud Backup") {
                    settingsManager.sessionLogCloudBackupEnabled = true
                    settingsManager.sessionLogCloudBackupConsentShown = true
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 440, maxWidth: 520)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.55))

                // Subtle ember glow at top
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.ember.opacity(0.06),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), DesignSystem.Colors.border.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
        }
    }

    private func featureBullet(icon: String, iconColor: Color, text: String) -> some View {
        Label {
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 20, alignment: .center)
        }
    }
}
