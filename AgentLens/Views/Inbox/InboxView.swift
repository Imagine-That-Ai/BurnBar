import SwiftUI
import OpenBurnBarKernel

// MARK: - Inbox surface

/// The AI Inbox: a two-pane list + detail surface, mirroring the Session Logs
/// command-center idiom (`SessionLogsView.mainLayout`) so the app has one
/// consistent shape for "browse a list, read a thing".
///
/// Visual grammar is borrowed, not invented:
///   • unread = 7pt ember dot + faint ember card wash (the Controller Inbox idiom)
///   • priority = `OpenBurnBarStatusBadge` capsule
///   • cards = `GlassCard`, sections = pinned `LazyVStack` headers
struct InboxView: View {
    @State private var model: InboxModel
    let onOpenSessionLog: (String) -> Void
    let onOpenSettings: () -> Void
    /// Nil when no memory store is available; the detail view then shows the
    /// proposal read-only rather than offering an approve button that cannot work.
    var memoryApproval: InboxMemoryApprovalHandler?
    /// Item to open on appear, set when a notification deep link routed here.
    var openItemID: String?

    @Environment(\.dashboardLiveBackdropActive) private var liveBackdropActive

    init(
        model: InboxModel,
        onOpenSessionLog: @escaping (String) -> Void,
        onOpenSettings: @escaping () -> Void,
        memoryApproval: InboxMemoryApprovalHandler? = nil,
        openItemID: String? = nil
    ) {
        // Own the model in `@State` so DashboardView body re-evals that rebuild
        // a throwaway `InboxModel(...)` cannot wipe selection mid-click.
        _model = State(initialValue: model)
        self.onOpenSessionLog = onOpenSessionLog
        self.onOpenSettings = onOpenSettings
        self.memoryApproval = memoryApproval
        self.openItemID = openItemID
    }

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(width: 380)
                .frame(minHeight: 0, maxHeight: .infinity)

            Divider().background(DesignSystem.Colors.border)

            detailPane
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .task {
            await model.load(force: true)
            await model.loadTelemetry()
            if let openItemID {
                await model.select(itemID: openItemID)
            }
        }
        .accessibilityIdentifier(OBBAccessibilityID.inboxRoot)
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            header
            filterBar

            if let errorMessage = model.errorMessage {
                errorBanner(errorMessage)
            }

            Divider().background(DesignSystem.Colors.borderSubtle)

            if model.isLoading {
                loadingState
            } else if model.visibleRows.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(paneBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text("INBOX")
                    .font(DesignSystem.Typography.tiny)
                    .tracking(1.4)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.ember)

                Spacer()

                if model.unreadCount > 0 {
                    Button {
                        Task { await model.markEverythingRead() }
                    } label: {
                        Text("Mark all read")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Mark every open item as read")
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text(headlineText)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                if model.attentionCount > 0 {
                    attentionPill
                }
            }

            if let subtitle = subtitleText {
                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.top, DesignSystem.Spacing.lg)
        .padding(.bottom, DesignSystem.Spacing.md)
    }

    private var headlineText: String {
        let count = model.unreadCount
        if count == 0 { return "All caught up" }
        return "\(count) new item\(count == 1 ? "" : "s")"
    }

    /// Honest status line: says when the last analysis ran and whether it cost
    /// anything, so the feature never feels like a black box.
    private var subtitleText: String? {
        guard let run = model.latestRun else {
            return "Waiting for the first analysis."
        }
        let when = Self.relativeFormatter.localizedString(for: run.startedAt, relativeTo: Date())
        switch run.gateResult {
        case .skippedUnchanged, .skippedDisabled:
            return "Last checked \(when) — nothing had changed."
        case .localChanged, .remotePhase, .forced:
            let cost = run.costUSD > 0 ? String(format: " · $%.3f", run.costUSD) : " · no model calls"
            return "Last analyzed \(when)\(cost)"
        case .failed:
            return "The last analysis did not complete."
        }
    }

    private var attentionPill: some View {
        Text("\(model.attentionCount) need\(model.attentionCount == 1 ? "s" : "") attention")
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.amber)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xxs)
            .background(
                Capsule().fill(DesignSystem.Colors.amber.opacity(0.16))
                    .overlay(Capsule().stroke(DesignSystem.Colors.amber.opacity(0.40), lineWidth: 1))
            )
    }

    private var filterBar: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(InboxModel.Filter.allCases) { filter in
                filterChip(filter)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.bottom, DesignSystem.Spacing.md)
    }

    private func filterChip(_ filter: InboxModel.Filter) -> some View {
        let isActive = model.filter == filter
        return Button {
            withAnimation(DesignSystem.Animation.snappy) { model.filter = filter }
        } label: {
            Text(filter.title)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(isActive ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(
                    Capsule()
                        .fill(isActive ? DesignSystem.Colors.ember.opacity(0.18) : Color.clear)
                        .overlay(
                            Capsule().stroke(
                                isActive
                                    ? DesignSystem.Colors.ember.opacity(0.45)
                                    : DesignSystem.Colors.borderSubtle,
                                lineWidth: 1
                            )
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(OBBAccessibilityID.inboxFilterChip(filter.rawValue))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystem.Colors.warning)
            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.warning.opacity(0.08))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(model.sections, id: \.section.id) { group in
                    Section {
                        ForEach(group.rows) { row in
                            InboxRowView(
                                row: row,
                                isSelected: model.selectedID == row.id,
                                onSelect: { model.select(row.id) },
                                onArchive: { Task { await model.archive(row.id) } },
                                onSnooze: { interval in Task { await model.snooze(row.id, for: interval) } },
                                onToggleRead: { Task { await model.toggleRead(row.id) } }
                            )
                            .padding(.horizontal, DesignSystem.Spacing.md)
                            .padding(.vertical, DesignSystem.Spacing.xs)
                        }
                    } header: {
                        sectionHeader(group.section, count: group.rows.count)
                    }
                }
            }
            .padding(.bottom, DesignSystem.Spacing.lg)
        }
    }

    private func sectionHeader(_ section: InboxModel.Section, count: Int) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Text(section.title.uppercased())
                .font(DesignSystem.Typography.tiny)
                .tracking(1.1)
                .foregroundStyle(
                    section == .attention ? DesignSystem.Colors.amber : DesignSystem.Colors.textMuted
                )
            Text("\(count)")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(.ultraThinMaterial)
    }

    private var loadingState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            ProgressView()
            Text("Reading your inbox…")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        InboxEmptyState(
            icon: model.filter.emptyIcon,
            title: emptyTitle,
            message: emptyMessage,
            actionTitle: model.hasEverRun ? nil : "Open settings",
            action: model.hasEverRun ? nil : onOpenSettings
        )
    }

    private var emptyTitle: String {
        switch model.filter {
        case .active: return model.hasEverRun ? "Nothing needs you" : "The inbox is not running yet"
        case .attention: return "Nothing urgent"
        case .resolved: return "No resolved items yet"
        case .archived: return "Nothing archived"
        }
    }

    private var emptyMessage: String {
        switch model.filter {
        case .active:
            return model.hasEverRun
                ? "OpenBurnBar is watching your sessions, workspaces, and GitHub. Anything worth your attention will show up here."
                : "Turn on the AI Inbox in settings and OpenBurnBar will start summarizing what your agents have been doing, and flag work that looks unfinished."
        case .attention:
            return "No high-priority items right now. That is the good outcome."
        case .resolved:
            return "When something the inbox flagged gets fixed, it moves here with a note about what resolved it."
        case .archived:
            return "Items you archive are kept here rather than deleted."
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let row = model.selectedRow {
            InboxItemDetailView(
                row: row,
                onOpenSessionLog: onOpenSessionLog,
                onArchive: { Task { await model.archive(row.id) } },
                onSnooze: { interval in Task { await model.snooze(row.id, for: interval) } },
                onFeedback: { useful in Task { await model.setFeedback(row.id, useful: useful) } },
                onOpenSettings: onOpenSettings,
                memoryApproval: memoryApproval
            )
            .id(row.id)
        } else {
            InboxEmptyState(
                icon: "sparkles",
                title: "Select an item",
                message: "Each item explains what happened, shows the evidence behind it, and offers the next step."
            )
        }
    }

    @ViewBuilder
    private var paneBackground: some View {
        if liveBackdropActive {
            Rectangle().fill(.ultraThinMaterial)
        } else {
            DesignSystem.Colors.surface.opacity(0.35)
        }
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

// MARK: - Row

/// One inbox item in the list.
///
/// Unread is expressed twice — a 7pt ember dot and a faint ember wash on the
/// card — because the dot alone is easy to miss in a dense list, and the wash
/// alone is too subtle to be a status. Neither relies on color alone: the title
/// weight also changes.
struct InboxRowView: View {
    let row: ControlPlaneStore.AIInboxRow
    let isSelected: Bool
    let onSelect: () -> Void
    let onArchive: () -> Void
    let onSnooze: (TimeInterval) -> Void
    let onToggleRead: () -> Void

    @State private var isHovering = false

    var body: some View {
        // interactive: false — GlassCard(interactive: true) installs a
        // minimumDistance-0 DragGesture that steals the click from this
        // Button (same trap SessionLedgerEntryRow documents/guards).
        Button(action: onSelect) {
            GlassCard(interactive: false) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    topLine
                    titleLine
                    if row.summaryMarkdown.isEmpty == false {
                        Text(Self.plainPreview(row.summaryMarkdown))
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    bottomLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .fill(rowWash)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(
                        isSelected ? DesignSystem.Colors.ember.opacity(0.55) : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(InboxRowButtonStyle())
        .onHover { isHovering = $0 }
        .animation(DesignSystem.Animation.hover, value: isHovering)
        .animation(DesignSystem.Animation.gentle, value: isSelected)
        .contextMenu {
            Button(row.readAt == nil ? "Mark as read" : "Mark as unread", action: onToggleRead)
            Divider()
            Button("Snooze for an hour") { onSnooze(3_600) }
            Button("Snooze until tomorrow") { onSnooze(24 * 3_600) }
            Divider()
            Button("Archive", action: onArchive)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(OBBAccessibilityID.inboxRow(row.id))
    }

    private var topLine: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            if row.isUnread {
                Circle()
                    .fill(DesignSystem.Colors.ember)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }

            Image(systemName: InboxPresentation.icon(for: row.summary.kind))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(InboxPresentation.tint(for: row.summary.kind))

            Text(InboxPresentation.kindLabel(row.summary.kind))
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Spacer(minLength: 0)

            if row.summary.priority <= .p2 {
                OpenBurnBarStatusBadge(
                    title: InboxPresentation.priorityLabel(row.summary.priority),
                    color: InboxPresentation.priorityColor(row.summary.priority)
                )
            }
        }
    }

    private var titleLine: some View {
        Text(row.summary.title)
            .font(DesignSystem.Typography.body)
            .fontWeight(row.isUnread ? .semibold : .regular)
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var bottomLine: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            if let project = row.summary.projectName, project.isEmpty == false {
                Text(project)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
                Text("·").foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Text(InboxView.relativeFormatter.localizedString(for: row.summary.lastSeenAt, relativeTo: Date()))
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            if row.summary.occurrenceCount > 1 {
                Text("· seen \(row.summary.occurrenceCount)×")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer(minLength: 0)

            if row.summary.hasMemoryCandidates {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignSystem.Colors.whimsy)
                    .help("This item proposes something to remember")
            }

            if row.summary.state == .resolved {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignSystem.Colors.success)
            }
        }
    }

    private var rowWash: Color {
        if isSelected { return DesignSystem.Colors.ember.opacity(0.10) }
        if row.isUnread { return DesignSystem.Colors.ember.opacity(0.05) }
        return .clear
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if row.isUnread { parts.append("Unread") }
        parts.append(InboxPresentation.kindLabel(row.summary.kind))
        if row.summary.priority <= .p2 {
            parts.append(InboxPresentation.priorityLabel(row.summary.priority))
        }
        parts.append(row.summary.title)
        return parts.joined(separator: ", ")
    }

    /// Strips markdown so a two-line preview never shows raw `**` or backticks.
    static func plainPreview(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct InboxRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(DesignSystem.Animation.snappy, value: configuration.isPressed)
    }
}

// MARK: - Empty state

struct InboxEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    @State private var glow = false
    /// The empty state is the screen a user sees most — the inbox is quiet by
    /// design — so an infinite pulse here is exactly the kind of persistent
    /// motion Reduce Motion exists to stop. The glow settles to its midpoint
    /// instead of animating.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.ember.opacity(0.18),
                                DesignSystem.Colors.amber.opacity(0.10),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 168, height: 168)
                    .blur(radius: 18)
                    // With Reduce Motion on, the glow never animates, so rest at
                    // the midpoint rather than the dimmed low end of a pulse the
                    // user will never see complete.
                    .scaleEffect(reduceMotion ? 1.0 : (glow ? 1.06 : 0.94))
                    .opacity(reduceMotion ? 0.85 : (glow ? 1 : 0.7))

                Image(systemName: icon)
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)
            }
            .onAppear {
                guard reduceMotion == false else { return }
                // Matches the Memory review empty state so the two inboxes
                // breathe at the same rate.
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    glow = true
                }
            }
            .accessibilityHidden(true)

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text(title)
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text(message)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(Capsule().fill(DesignSystem.Colors.primaryGradient))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignSystem.Spacing.xxl)
    }
}

// MARK: - Presentation vocabulary

/// One place that decides how each item kind looks.
///
/// Centralized so a new detector gets a coherent icon/tint/label by adding one
/// case here — the `ChartKind` registry pattern, applied to the inbox.
enum InboxPresentation {
    static func icon(for kind: BurnBarInboxItemKind) -> String {
        switch kind {
        case .ciWaste: return "flame"
        case .promisedNotLanded: return "questionmark.circle"
        case .uncommittedWork: return "tray.and.arrow.down"
        case .costAnomaly: return "chart.line.uptrend.xyaxis"
        case .stuckPR: return "arrow.triangle.pull"
        case .indexHealth: return "waveform.path.ecg"
        case .brief: return "text.alignleft"
        case .budget: return "gauge.with.dots.needle.67percent"
        case .system: return "info.circle"
        }
    }

    static func tint(for kind: BurnBarInboxItemKind) -> Color {
        switch kind {
        case .ciWaste, .costAnomaly, .budget: return DesignSystem.Colors.amber
        case .promisedNotLanded, .stuckPR: return DesignSystem.Colors.ember
        case .uncommittedWork: return DesignSystem.Colors.whimsy
        case .indexHealth, .system: return DesignSystem.Colors.textMuted
        case .brief: return DesignSystem.Colors.blaze
        }
    }

    static func kindLabel(_ kind: BurnBarInboxItemKind) -> String {
        switch kind {
        case .ciWaste: return "CI waste"
        case .promisedNotLanded: return "Possibly unfinished"
        case .uncommittedWork: return "Uncommitted work"
        case .costAnomaly: return "Spend anomaly"
        case .stuckPR: return "Stalled PR"
        case .indexHealth: return "Index"
        case .brief: return "Brief"
        case .budget: return "Budget"
        case .system: return "Notice"
        }
    }

    static func priorityLabel(_ priority: BurnBarInboxPriority) -> String {
        switch priority {
        case .p1: return "Urgent"
        case .p2: return "Today"
        case .p3: return "Worth knowing"
        case .p4: return "Background"
        }
    }

    static func priorityColor(_ priority: BurnBarInboxPriority) -> Color {
        switch priority {
        case .p1: return DesignSystem.Colors.error
        case .p2: return DesignSystem.Colors.amber
        case .p3: return DesignSystem.Colors.whimsy
        case .p4: return DesignSystem.Colors.textMuted
        }
    }

    static func evidenceIcon(for kind: BurnBarInboxEvidence.Kind) -> String {
        switch kind {
        case .conversation: return "text.bubble"
        case .pullRequest: return "arrow.triangle.pull"
        case .issue: return "exclamationmark.circle"
        case .workflowRun: return "gearshape.2"
        case .commit: return "checkmark.seal"
        case .file: return "folder"
        case .usage: return "dollarsign.circle"
        case .metric: return "chart.bar"
        }
    }

    static func actionIcon(for kind: BurnBarInboxAction.Kind) -> String {
        switch kind {
        case .openURL: return "arrow.up.forward.square"
        case .resumeConversation: return "arrow.clockwise"
        case .openSessionLog: return "text.bubble"
        case .openProject: return "folder"
        case .openSettings: return "gearshape"
        case .runCommand: return "terminal"
        }
    }
}
