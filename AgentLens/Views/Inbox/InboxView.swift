import AppKit
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
    @State var model: InboxModel
    let onOpenSessionLog: (String) -> Void
    let onOpenSettings: () -> Void
    /// Nil when no memory store is available; the detail view then shows the
    /// proposal read-only rather than offering an approve button that cannot work.
    var memoryApproval: InboxMemoryApprovalHandler?
    /// Item to open on appear, set when a notification deep link routed here.
    var openItemID: String?

    @Environment(\.dashboardLiveBackdropActive) private var liveBackdropActive

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
                ? "Quiet desks are the point. BurnBar is watching sessions, worktrees, and GitHub — the next story will land here."
                : "Flip on the AI Inbox in settings and BurnBar starts turning agent work into short, visual stories."
        case .attention:
            return "Nothing urgent. Enjoy the calm."
        case .resolved:
            return "Closed stories land here — with a note about how they ended."
        case .archived:
            return "Archived beats stay here if you want them later."
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

    private var kindTint: Color { InboxPresentation.tint(for: row.summary.kind) }
    private var cast: [InboxPresentation.CastMember] { InboxPresentation.cast(for: row, limit: 4) }

    var body: some View {
        // Non-interactive plate: an interactive GlassCard installs a
        // minimumDistance-0 DragGesture that steals the click from this
        // Button (same trap SessionLedgerEntryRow documents/guards).
        Button(action: onSelect) {
            GlassCard(interactive: false) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    InboxKindEmblem(
                        kind: row.summary.kind,
                        size: 44,
                        isEmphasized: isSelected || row.isUnread
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        topLine
                        titleLine
                        Text(InboxPresentation.listSummary(for: row))
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        bottomLine
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(rowWash)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(
                        isSelected ? kindTint.opacity(0.55) : Color.clear,
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

            Text(InboxPresentation.kindLabel(row.summary.kind))
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(kindTint)

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
        HStack(spacing: DesignSystem.Spacing.sm) {
            InboxCastStrip(members: cast, size: 18)

            Spacer(minLength: 0)

            if let project = row.summary.projectName, project.isEmpty == false {
                Text(project)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
            }

            Text(InboxView.relativeFormatter.localizedString(for: row.summary.lastSeenAt, relativeTo: Date()))
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

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
        if isSelected { return kindTint.opacity(0.12) }
        if isHovering { return kindTint.opacity(0.06) }
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

// MARK: - Story marks

/// Kind glyph in a tinted glass disc — the visual hero of every inbox beat.
struct InboxKindEmblem: View {
    let kind: BurnBarInboxItemKind
    var size: CGFloat = 44
    var isEmphasized: Bool = false

    private var tint: Color { InboxPresentation.tint(for: kind) }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(isEmphasized ? 0.42 : 0.28), tint.opacity(0.08)],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: size
                    )
                )
            Circle()
                .strokeBorder(tint.opacity(isEmphasized ? 0.55 : 0.28), lineWidth: 1)
            Image(systemName: InboxPresentation.icon(for: kind))
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: size, height: size)
        .shadow(color: tint.opacity(isEmphasized ? 0.35 : 0.12), radius: isEmphasized ? 10 : 4, y: 2)
        .accessibilityHidden(true)
    }
}

/// Overlapping cast chips — provider logos, GitHub, evidence glyphs.
struct InboxCastStrip: View {
    let members: [InboxPresentation.CastMember]
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: -size * 0.28) {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                InboxCastChip(member: member, size: size)
                    .zIndex(Double(members.count - index))
            }
        }
        .accessibilityHidden(true)
    }
}

struct InboxCastChip: View {
    let member: InboxPresentation.CastMember
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle()
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.92))
            mark
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(DesignSystem.Colors.borderSubtle, lineWidth: 0.75))
        .shadow(color: Color.black.opacity(0.12), radius: 2, y: 1)
    }

    @ViewBuilder
    private var mark: some View {
        switch member {
        case .provider(let provider):
            ProviderLogoView(provider: provider, size: size * 0.72, useFallbackColor: false)
        case .github:
            if NSImage(named: "GitHubLogo") != nil {
                Image("GitHubLogo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.18)
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
        case .burnbar:
            AppLogoView(size: size * 0.72)
        case .evidence(let kind):
            Image(systemName: InboxPresentation.evidenceIcon(for: kind))
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(InboxPresentation.evidenceTint(for: kind))
        }
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

/// One place that decides how each item kind looks *and* reads.
///
/// Centralized so a new detector gets a coherent icon/tint/label/story beat by
/// adding one case here — the `ChartKind` registry pattern, applied to the inbox.
enum InboxPresentation {
    /// Visual cast member on a row/detail strip — provider logo, GitHub, or
    /// an evidence-kind glyph. Ordered for left-to-right storytelling.
    enum CastMember: Hashable, Identifiable {
        case provider(AgentProvider)
        case github
        case evidence(BurnBarInboxEvidence.Kind)
        case burnbar

        var id: String {
            switch self {
            case .provider(let p): return "provider:\(p.rawValue)"
            case .github: return "github"
            case .evidence(let k): return "evidence:\(k.rawValue)"
            case .burnbar: return "burnbar"
            }
        }
    }

    static func icon(for kind: BurnBarInboxItemKind) -> String {
        switch kind {
        case .ciWaste: return "flame.fill"
        case .promisedNotLanded: return "flag.fill"
        case .uncommittedWork: return "tray.full.fill"
        case .unpushedCommits: return "arrow.up.circle.fill"
        case .pushedNotMerged: return "arrow.triangle.merge"
        case .costAnomaly: return "chart.line.uptrend.xyaxis"
        case .stuckPR: return "arrow.triangle.pull"
        case .indexHealth: return "waveform.path.ecg"
        case .brief: return "newspaper.fill"
        case .budget: return "gauge.with.dots.needle.67percent"
        case .system: return "sparkles"
        }
    }

    static func tint(for kind: BurnBarInboxItemKind) -> Color {
        switch kind {
        case .ciWaste, .costAnomaly, .budget: return DesignSystem.Colors.amber
        case .promisedNotLanded, .stuckPR, .pushedNotMerged: return DesignSystem.Colors.ember
        case .uncommittedWork, .unpushedCommits: return DesignSystem.Colors.whimsy
        case .indexHealth, .system: return DesignSystem.Colors.textMuted
        case .brief: return DesignSystem.Colors.blaze
        }
    }

    static func kindLabel(_ kind: BurnBarInboxItemKind) -> String {
        switch kind {
        case .ciWaste: return "CI waste"
        case .promisedNotLanded: return "Possibly unfinished"
        case .uncommittedWork: return "Uncommitted work"
        case .unpushedCommits: return "Unpushed commits"
        case .pushedNotMerged: return "Pushed, not merged"
        case .costAnomaly: return "Spend anomaly"
        case .stuckPR: return "Stalled PR"
        case .indexHealth: return "Index"
        case .brief: return "Brief"
        case .budget: return "Budget"
        case .system: return "Notice"
        }
    }

    /// One-line beat under the title — the story, not the taxonomy.
    static func storyBeat(for kind: BurnBarInboxItemKind) -> String {
        switch kind {
        case .ciWaste: return "Pipelines spinning without teaching you anything."
        case .promisedNotLanded: return "Something was promised. Main never saw it."
        case .uncommittedWork: return "A worktree went quiet with changes still on disk."
        case .unpushedCommits: return "Commits are local — the remote never saw them."
        case .pushedNotMerged: return "The branch is out there, but nothing merged."
        case .costAnomaly: return "Spend jumped off the trailing baseline."
        case .stuckPR: return "A pull request stopped moving."
        case .indexHealth: return "The local index needs a little care."
        case .brief: return "Here’s what your agents have been up to."
        case .budget: return "The daily ceiling was hit — synthesis cooled down."
        case .system: return "A quiet note from BurnBar."
        }
    }

    /// Soft atmosphere wash behind the detail hero.
    static func atmosphere(for kind: BurnBarInboxItemKind) -> LinearGradient {
        let tint = tint(for: kind)
        return LinearGradient(
            colors: [
                tint.opacity(0.28),
                tint.opacity(0.08),
                Color.clear
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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
        case .conversation: return "text.bubble.fill"
        case .pullRequest: return "arrow.triangle.pull"
        case .issue: return "exclamationmark.circle.fill"
        case .workflowRun: return "gearshape.2.fill"
        case .commit: return "checkmark.seal.fill"
        case .file: return "doc.fill"
        case .usage: return "dollarsign.circle.fill"
        case .metric: return "chart.bar.fill"
        }
    }

    static func evidenceTint(for kind: BurnBarInboxEvidence.Kind) -> Color {
        switch kind {
        case .conversation: return DesignSystem.Colors.blaze
        case .pullRequest, .issue, .commit, .workflowRun: return DesignSystem.Colors.textPrimary
        case .file: return DesignSystem.Colors.whimsy
        case .usage, .metric: return DesignSystem.Colors.amber
        }
    }

    static func actionIcon(for kind: BurnBarInboxAction.Kind) -> String {
        switch kind {
        case .openURL: return "arrow.up.forward.square"
        case .resumeConversation: return "arrow.clockwise"
        case .openSessionLog: return "text.bubble"
        case .openProject: return "folder.fill"
        case .openSettings: return "gearshape"
        case .runCommand: return "terminal"
        }
    }

    /// Cast strip for a row/detail — providers from provenance, GitHub when
    /// evidence points at it, then distinct evidence kinds, capped for glance.
    static func cast(for row: ControlPlaneStore.AIInboxRow, limit: Int = 5) -> [CastMember] {
        var members: [CastMember] = []
        var seen = Set<String>()

        func append(_ member: CastMember) {
            guard members.count < limit, seen.insert(member.id).inserted else { return }
            members.append(member)
        }

        for provider in providers(fromProvenance: row.summary.modelProvenance) {
            append(.provider(provider))
        }

        let urls = row.payload.evidence.compactMap(\.url) + row.payload.actions.map(\.value)
        if urls.contains(where: { $0.localizedCaseInsensitiveContains("github.com") }) {
            append(.github)
        }

        // Project-local stories always get the BurnBar mark.
        if row.summary.projectName?.isEmpty == false {
            append(.burnbar)
        }

        for evidence in row.payload.evidence {
            append(.evidence(evidence.kind))
        }

        if members.isEmpty {
            append(.evidence(.metric))
        }
        return members
    }

    /// Maps `anthropic:claude-…+openai:gpt-…` provenance into AgentProviders.
    static func providers(fromProvenance provenance: String) -> [AgentProvider] {
        guard provenance.isEmpty == false, provenance != "local-rules" else { return [] }
        var result: [AgentProvider] = []
        var seen = Set<AgentProvider>()
        for component in provenance.split(separator: "+") {
            let token = component.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
            guard let provider = provider(forProvenanceToken: token), seen.insert(provider).inserted else { continue }
            result.append(provider)
        }
        return result
    }

    static func provider(forProvenanceToken token: String) -> AgentProvider? {
        switch token {
        case "anthropic", "claude": return .claudeCode
        case "openai", "chatgpt": return .openAI
        case "codex": return .codex
        case "google", "gemini": return .geminiCLI
        case "xai", "grok": return .xAI
        case "deepseek": return .deepSeek
        case "cursor": return .cursor
        case "copilot", "github": return .copilot
        case "ollama": return .ollama
        case "minimax": return .minimax
        case "kimi", "moonshot": return .kimi
        case "zai", "zhipu": return .zai
        case "factory", "droid": return .factory
        case "hermes": return .hermes
        case "openclaw": return .openClaw
        case "opencode": return .openCode
        case "windsurf": return .windsurf
        case "warp": return .warp
        case "openburnbar", "burnbar": return .openBurnBar
        default: return nil
        }
    }

    /// Prefer the model beat; fall back to the kind’s stock story line.
    static func listSummary(for row: ControlPlaneStore.AIInboxRow) -> String {
        let preview = InboxRowView.plainPreview(row.summaryMarkdown)
        if preview.isEmpty == false { return preview }
        return storyBeat(for: row.summary.kind)
    }
}
