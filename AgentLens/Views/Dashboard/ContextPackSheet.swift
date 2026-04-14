import SwiftUI

// MARK: - Context Pack Sheet

/// Sheet for creating and exporting context packs.
///
/// This sheet supports two launch modes:
/// - **Unanchored** (Dashboard): Uses the selected time range and fetches all eligible sessions.
///   If `anchorSessionId` is nil, uses the most recent eligible session as the default anchor.
/// - **Anchored** (Session Detail): Scoped to a specific session/project via `anchorSessionId` and `anchorProject`.
///
/// The sheet maintains deterministic state: target selection always resets to `claude` on reopen.
struct ContextPackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var dataStore: DataStore

    /// Optional anchor session ID. When provided, the pack is assembled around this session.
    let anchorSessionId: String?

    /// Optional anchor project name for same-project boost.
    let anchorProject: String?

    /// Optional date range for unanchored launches (Dashboard).
    /// Ignored when `anchorSessionId` is provided.
    let dateRange: ClosedRange<Date>?

    /// Called when the user explicitly dismisses the sheet.
    var onDismiss: (() -> Void)?

    // MARK: - State

    @State private var selectedTarget: ContextPackExportTarget = .claude
    @State private var assembledPack: ContextPack?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showCopyConfirmation = false
    @State private var copyConfirmationTask: Task<Void, Never>?

    // MARK: - Constants

    /// Warning threshold for character budget indicator (UI display threshold, not service cap).
    private static let charBudgetWarningThreshold = 16_000

    /// The service-level hard cap (must match ContextPackAssemblyParams).
    private static let serviceCharCap = 12_000

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider().background(DesignSystem.Colors.border)

            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(message: error)
            } else if let pack = assembledPack, pack.isEmpty {
                emptyStateView
            } else if let pack = assembledPack {
                contentView(pack: pack)
            }
        }
        .frame(width: 560, height: 480)
        .background(DesignSystem.Colors.surface)
        .task {
            await assemblePack()
        }
        .onDisappear {
            copyConfirmationTask?.cancel()
            onDismiss?()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("Create Context Pack")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }

            if let pack = assembledPack, !pack.isEmpty {
                headerMetadataView(pack: pack)
            }
        }
        .padding(DesignSystem.Spacing.lg)
    }

    @ViewBuilder
    private func headerMetadataView(pack: ContextPack) -> some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            if let project = pack.project {
                Label(project, systemImage: "folder")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Label("\(pack.sessions.count) session\(pack.sessions.count == 1 ? "" : "s")", systemImage: "doc.text")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Label("~\(pack.charEstimate.formatted()) chars", systemImage: "text.alignleft")
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(charBudgetColor(pack.charEstimate))
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            ProgressView()
                .controlSize(.regular)
            Text("Assembling context pack...")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(DesignSystem.Colors.error)

            Text("Failed to assemble context pack")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text("No eligible sessions")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Enable conversation indexing and run a scan to collect session history.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content

    @ViewBuilder
    private func contentView(pack: ContextPack) -> some View {
        VStack(spacing: 0) {
            // Session list
            ScrollView {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(pack.sessions) { session in
                        sessionRowView(session)
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }

            Divider().background(DesignSystem.Colors.border)

            // Target pills and actions
            actionBarView(pack: pack)
        }
    }

    private func sessionRowView(_ session: ContextPackSession) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack {
                Text(session.title)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(session.reasonLabel)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, 2)
                    .background(DesignSystem.Colors.surfaceElevated)
                    .clipShape(Capsule())
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                Label(session.provider, systemImage: "brain")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                if let endTime = session.endTime {
                    Text(formatRelativeDate(endTime))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                Text("\(session.bodyText.count) chars")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
    }

    // MARK: - Action Bar

    private func actionBarView(pack: ContextPack) -> some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            // Target pills
            targetPillsView

            // Char budget indicator
            charBudgetIndicatorView(pack: pack)

            // Copy button and confirmation
            copyButtonView(pack: pack)
        }
        .padding(DesignSystem.Spacing.lg)
    }

    private var targetPillsView: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("Export as:")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            ForEach(ContextPackExportTarget.allCases, id: \.self) { target in
                targetPill(target)
            }

            Spacer()
        }
    }

    private func targetPill(_ target: ContextPackExportTarget) -> some View {
        Button {
            selectedTarget = target
        } label: {
            Text(target.displayName)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(selectedTarget == target
                    ? DesignSystem.Colors.textPrimary
                    : DesignSystem.Colors.textMuted)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(
                    selectedTarget == target
                        ? DesignSystem.Colors.whimsy.opacity(0.2)
                        : DesignSystem.Colors.surfaceElevated
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(
                            selectedTarget == target
                                ? DesignSystem.Colors.whimsy
                                : DesignSystem.Colors.border,
                            lineWidth: 0.75
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func charBudgetIndicatorView(pack: ContextPack) -> some View {
        HStack {
            Text("Est. size: \(pack.charEstimate.formatted()) chars")
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(charBudgetColor(pack.charEstimate))

            Spacer()

            if pack.charEstimate > Self.charBudgetWarningThreshold {
                Label("Approaching limit", systemImage: "exclamationmark.triangle.fill")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.warning)
            }
        }
    }

    private func charBudgetColor(_ charCount: Int) -> Color {
        if charCount > Self.charBudgetWarningThreshold {
            return DesignSystem.Colors.warning
        }
        return DesignSystem.Colors.textSecondary
    }

    private func copyButtonView(pack: ContextPack) -> some View {
        HStack {
            Button {
                copyPack(pack)
            } label: {
                HStack {
                    Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                    Text(showCopyConfirmation ? "Copied!" : "Copy to Clipboard")
                }
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(showCopyConfirmation
                    ? DesignSystem.Colors.success
                    : DesignSystem.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignSystem.Spacing.md)
                .background(
                    showCopyConfirmation
                        ? DesignSystem.Colors.success.opacity(0.15)
                        : DesignSystem.Colors.whimsy.opacity(0.15)
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                        .strokeBorder(
                            showCopyConfirmation
                                ? DesignSystem.Colors.success
                                : DesignSystem.Colors.whimsy.opacity(0.5),
                            lineWidth: 0.75
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(showCopyConfirmation)
        }
    }

    // MARK: - Actions

    private func copyPack(_ pack: ContextPack) {
        let payload = ContextPackExporter.export(pack, target: selectedTarget)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)

        showCopyConfirmation = true
        copyConfirmationTask?.cancel()
        copyConfirmationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled {
                showCopyConfirmation = false
            }
        }
    }

    // MARK: - Pack Assembly

    private func assemblePack() async {
        isLoading = true
        errorMessage = nil

        do {
            // Fetch eligible conversations
            let candidates: [ConversationRecord]

            if let anchorSessionId {
                // Anchored launch (Session Detail): use project-scoped candidate assembly.
                // anchorSessionId identifies the selected session, but the pack should include
                // all eligible sessions from the same project (anchorProject) so that
                // ranking can produce a project-scoped context pack, not a single-session export.
                candidates = try dataStore.fetchConversationsForTranscriptScan(
                    provider: nil,
                    projectName: anchorProject,
                    dateRange: dateRange,
                    conversationSources: nil
                )
            } else {
                // Unanchored launch (Dashboard): fetch all eligible sessions within date range
                candidates = try dataStore.fetchConversationsForTranscriptScan(
                    provider: nil,
                    projectName: anchorProject,
                    dateRange: dateRange,
                    conversationSources: nil
                )
            }

            // Build params
            let params = ContextPackAssemblyParams(
                anchorProject: anchorProject,
                dateRange: dateRange,
                maxSessions: 5,
                maxCharBudget: Self.serviceCharCap,
                referenceDate: Date()
            )

            // Assemble pack
            let pack = ContextPackService.assemble(candidates: candidates, params: params)
            assembledPack = pack
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Helpers

    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Dashboard Context Pack Card

/// Entry card shown on the Dashboard overview that opens the Context Pack sheet.
struct ContextPackDashboardCard: View {
    @Bindable var dataStore: DataStore
    let selectedTimeRange: TimeRange
    var onPresentSheet: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            onPresentSheet()
        } label: {
            GlassCard(interactive: true) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(DesignSystem.Colors.whimsy.opacity(0.15))
                            .frame(width: 40, height: 40)

                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(DesignSystem.Colors.whimsy)
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Create Context Pack")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Text("Build a prompt-ready brief of recent sessions for any AI agent")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isHovered
                            ? DesignSystem.Colors.whimsy
                            : DesignSystem.Colors.textMuted)
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Session Detail Context Pack Row

/// Row action shown in Session Detail for creating a context pack anchored to the current session.
struct SessionDetailContextPackRow: View {
    let session: TokenUsage
    let conversation: ConversationRecord?
    @Bindable var dataStore: DataStore
    var onPresentSheet: (String?, String?) -> Void

    @State private var isHovered = false

    private var isEnabled: Bool {
        SettingsManager.shared.conversationIndexingEnabled && conversation != nil
    }

    var body: some View {
        Button {
            guard let conversation else { return }
            let stableId = ConversationRecord.stableId(provider: session.provider, sessionId: session.sessionId)
            onPresentSheet(stableId, conversation.projectName)
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 13, weight: .medium))
                Text("Create Context Pack")
                    .font(DesignSystem.Typography.caption)
            }
            .foregroundStyle(isEnabled
                ? (isHovered ? DesignSystem.Colors.whimsy : DesignSystem.Colors.textSecondary)
                : DesignSystem.Colors.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(isHovered && isEnabled
                ? DesignSystem.Colors.whimsy.opacity(0.08)
                : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
    }
}
