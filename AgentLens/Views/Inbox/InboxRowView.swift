import AppKit
import OpenBurnBarKernel
import SwiftUI

// MARK: - Row callbacks

/// The row's outbound edges, bundled so the row stays a value with one
/// dependency rather than a fourteen-argument call site.
struct InboxRowActions {
    var click: (InboxModel.SelectionIntent) -> Void
    var toggleRead: () -> Void
    var togglePin: () -> Void
    var toggleSaved: () -> Void
    var setTag: (InboxColorTag?) -> Void
    var setCategory: (String?) -> Void
    var newCategory: () -> Void
    var snooze: (TimeInterval) -> Void
    var archive: () -> Void
    var delete: () -> Void
    var nudge: (Int) -> Void
    var dropRow: (String) -> Void
}

// MARK: - Row

/// One inbox item in the list.
///
/// Unread is expressed twice — a 7pt ember dot and a faint ember wash on the
/// card — because the dot alone is easy to miss in a dense list, and the wash
/// alone is too subtle to be a status. Neither relies on color alone: the title
/// weight also changes. The same rule governs the management state added on top:
/// a colour tag always shows its name, a pin always shows its glyph, and a
/// checked row draws a checkmark rather than only a tinted border.
struct InboxRowView: View {
    let row: ControlPlaneStore.AIInboxRow
    let entry: InboxShelfEntry?
    /// Open in the detail pane.
    let isOpen: Bool
    /// Part of a multi-selection.
    let isChecked: Bool
    /// Whether any multi-selection exists at all — the checkbox column only
    /// appears once the user is actually selecting.
    let hasSelection: Bool
    let allowsDrag: Bool
    let allowsReorder: Bool
    let isDropTarget: Bool
    let categoryChoices: [String]
    let actions: InboxRowActions
    let ink: BackdropInk
    let onDropTargeted: (Bool) -> Void

    @State private var isHovering = false

    private var pinned: Bool { entry?.pinned == true }
    private var saved: Bool { entry?.isSaved == true }
    private var colorTag: InboxColorTag? { entry?.colorTag }
    private var category: String? { entry?.category }

    var body: some View {
        card
            .buttonStyle(InboxRowButtonStyle())
            .onHover { isHovering = $0 }
            .animation(DesignSystem.Animation.hover, value: isHovering)
            .animation(DesignSystem.Animation.gentle, value: isOpen)
            .animation(DesignSystem.Animation.gentle, value: isChecked)
            .modifier(
                InboxRowDragAndDrop(
                    id: row.id,
                    title: row.summary.title,
                    allowsDrag: allowsDrag,
                    allowsReorder: allowsReorder,
                    onDrop: actions.dropRow,
                    onTargeted: onDropTargeted
                )
            )
            .contextMenu { contextMenu }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityActions { accessibilityActionList }
            .accessibilityIdentifier(OBBAccessibilityID.inboxRow(row.id))
    }

    private var card: some View {
        // interactive: false — GlassCard(interactive: true) installs a
        // minimumDistance-0 DragGesture that steals the click from this
        // Button (same trap SessionLedgerEntryRow documents/guards).
        Button {
            actions.click(InboxView.selectionIntent(for: NSEvent.modifierFlags))
        } label: {
            GlassCard(interactive: false) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    if hasSelection {
                        checkbox
                    }
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        topLine
                        titleLine
                        if row.summaryMarkdown.isEmpty == false {
                            Text(Self.plainPreview(row.summaryMarkdown))
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(ink.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if colorTag != nil || category != nil {
                            tagLine
                        }
                        bottomLine
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .fill(rowWash)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
        }
    }

    private var checkbox: some View {
        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(isChecked ? DesignSystem.Colors.ember : ink.hairline)
            .padding(.top, 1)
            .accessibilityHidden(true)
    }

    private var topLine: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            if row.isUnread {
                Circle()
                    .fill(DesignSystem.Colors.ember)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }

            if pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
                    .help("Pinned to the top")
            }

            if saved {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
                    .help("Saved")
            }

            Image(systemName: InboxPresentation.icon(for: row.summary.kind))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(InboxPresentation.tint(for: row.summary.kind))

            Text(InboxPresentation.kindLabel(row.summary.kind))
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(ink.subtle)

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
            .foregroundStyle(ink.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Tag and category chips. Both always carry their **name**: the colour is
    /// the fast index, never the message.
    private var tagLine: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            if let colorTag {
                chip(
                    text: colorTag.displayName,
                    systemImage: colorTag.symbolName,
                    tint: InboxPresentation.color(for: colorTag)
                )
            }
            if let category {
                chip(text: category, systemImage: "folder", tint: DesignSystem.Colors.whimsy)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 8, weight: .semibold))
            Text(text).font(DesignSystem.Typography.tiny).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, DesignSystem.Spacing.xs)
        .padding(.vertical, 1)
        .background(
            Capsule()
                .fill(tint.opacity(0.14))
                .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 1))
        )
    }

    private var bottomLine: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            if let project = row.summary.projectName, project.isEmpty == false {
                Text(project)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(ink.subtle)
                    .lineLimit(1)
                Text("·").foregroundStyle(ink.subtle)
            }

            Text(InboxView.relativeFormatter.localizedString(for: row.summary.lastSeenAt, relativeTo: Date()))
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(ink.subtle)

            if row.summary.occurrenceCount > 1 {
                Text("· seen \(InboxMetricInspector.groupedCount(Double(row.summary.occurrenceCount)))×")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(ink.subtle)
                    // The full story lives in the detail pane; the list still
                    // owes a hover answer rather than a bare number.
                    .help(InboxOccurrenceInspector.summarize(summary: row.summary).explanation)
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

    // MARK: Menus

    @ViewBuilder
    private var contextMenu: some View {
        Button(row.readAt == nil ? "Mark as read" : "Mark as unread", action: actions.toggleRead)
        Divider()
        Button(pinned ? "Unpin" : "Pin to top", action: actions.togglePin)
        Button(saved ? "Remove from Saved" : "Save", action: actions.toggleSaved)
        Menu("Tag") {
            Button("No tag") { actions.setTag(nil) }
            Divider()
            ForEach(InboxColorTag.allCases) { tag in
                Button {
                    actions.setTag(tag)
                } label: {
                    Label(tag.displayName, systemImage: tag.symbolName)
                }
            }
        }
        Menu("File into") {
            Button("No category") { actions.setCategory(nil) }
            Divider()
            ForEach(categoryChoices, id: \.self) { name in
                Button(name) { actions.setCategory(name) }
            }
            Divider()
            Button("New category…", action: actions.newCategory)
        }
        if allowsReorder {
            Divider()
            Button("Move up") { actions.nudge(-1) }
            Button("Move down") { actions.nudge(1) }
        }
        Divider()
        Button("Snooze for an hour") { actions.snooze(3_600) }
        Button("Snooze until tomorrow") { actions.snooze(24 * 3_600) }
        Divider()
        Button("Archive", action: actions.archive)
        Button("Delete", role: .destructive, action: actions.delete)
    }

    /// The context menu, flattened. A submenu is not reachable from the
    /// VoiceOver actions rotor, so tags and categories are listed outright.
    @ViewBuilder
    private var accessibilityActionList: some View {
        // Multi-select is otherwise a command-click and a shift-click, neither
        // of which exists without a mouse.
        Button(isChecked ? "Remove from selection" : "Add to selection") { actions.click(.toggle) }
        Button("Extend selection to here") { actions.click(.extend) }
        Button(row.readAt == nil ? "Mark as read" : "Mark as unread", action: actions.toggleRead)
        Button(pinned ? "Unpin" : "Pin to top", action: actions.togglePin)
        Button(saved ? "Remove from Saved" : "Save", action: actions.toggleSaved)
        Button("Clear tag") { actions.setTag(nil) }
        ForEach(InboxColorTag.allCases) { tag in
            Button("Tag: \(tag.displayName)") { actions.setTag(tag) }
        }
        Button("Clear category") { actions.setCategory(nil) }
        ForEach(categoryChoices, id: \.self) { name in
            Button("File into \(name)") { actions.setCategory(name) }
        }
        if allowsReorder {
            Button("Move up") { actions.nudge(-1) }
            Button("Move down") { actions.nudge(1) }
        }
        Button("Snooze for an hour") { actions.snooze(3_600) }
        Button("Archive", action: actions.archive)
        Button("Delete", action: actions.delete)
    }

    // MARK: Styling

    private var rowWash: Color {
        if isChecked { return DesignSystem.Colors.ember.opacity(0.14) }
        if isOpen { return DesignSystem.Colors.ember.opacity(0.10) }
        if row.isUnread { return DesignSystem.Colors.ember.opacity(0.05) }
        return .clear
    }

    private var borderColor: Color {
        if isDropTarget { return DesignSystem.Colors.whimsy.opacity(0.85) }
        if isChecked { return DesignSystem.Colors.ember.opacity(0.75) }
        if isOpen { return DesignSystem.Colors.ember.opacity(0.55) }
        return .clear
    }

    private var borderWidth: CGFloat {
        isDropTarget ? 2 : 1.5
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if isChecked { parts.append("Selected") }
        if row.isUnread { parts.append("Unread") }
        if pinned { parts.append("Pinned") }
        if saved { parts.append("Saved") }
        parts.append(InboxPresentation.kindLabel(row.summary.kind))
        if row.summary.priority <= .p2 {
            parts.append(InboxPresentation.priorityLabel(row.summary.priority))
        }
        parts.append(row.summary.title)
        if let colorTag { parts.append("tagged \(colorTag.displayName)") }
        if let category { parts.append("filed under \(category)") }
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

/// Drag/drop attached conditionally.
///
/// Kept in a modifier so the row body has one shape regardless of mode: adding
/// `.draggable` unconditionally would put a drag gesture on every row in every
/// mode, and this surface has already been bitten once by a gesture stealing a
/// click out of the row button.
private struct InboxRowDragAndDrop: ViewModifier {
    let id: String
    let title: String
    let allowsDrag: Bool
    let allowsReorder: Bool
    let onDrop: (String) -> Void
    let onTargeted: (Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if allowsDrag {
            draggable(content)
        } else {
            content
        }
    }

    @ViewBuilder
    private func draggable(_ content: Content) -> some View {
        let dragged = content.draggable(id) {
            Text(title)
                .font(DesignSystem.Typography.tiny)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(DesignSystem.Colors.surface))
        }
        if allowsReorder {
            dragged
                .dropDestination(for: String.self) { items, _ in
                    onTargeted(false)
                    guard let dragged = items.first, dragged != id else { return false }
                    onDrop(dragged)
                    return true
                } isTargeted: { onTargeted($0) }
        } else {
            dragged
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

// MARK: - Auto refresh

/// Re-reads the inbox when the host says daemon-written rows may have changed.
///
/// Applied only when `name` is non-nil, so surfaces that should stay frozen
/// while being read (the focused `.inbox` route) opt out by passing nil.
///
/// The reload is deliberately `load()` and not `load(force: true)`: `load`
/// short-circuits on an unchanged change marker, so a tick where nothing
/// happened costs one aggregate query and leaves the list — and the user's
/// scroll position and selection — completely untouched. Forcing would re-sort
/// under their cursor every cadence pass.
struct InboxAutoRefresh: ViewModifier {
    let name: Notification.Name?
    let reload: () async -> Void

    func body(content: Content) -> some View {
        if let name {
            content.onReceive(NotificationCenter.default.publisher(for: name)) { _ in
                Task { await reload() }
            }
        } else {
            content
        }
    }
}

// MARK: - Empty state

struct InboxEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    /// Text roles for a host drawn over a live backdrop.
    ///
    /// `nil` keeps the historical behavior (flat `DesignSystem` tokens) so the
    /// focused `.inbox` route is untouched. Home passes its resolved ink,
    /// because on the dashboard canvas `textSecondary` over a live backdrop is
    /// the exact failure `BackdropInk` exists to prevent.
    var ink: BackdropInk?

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
                    .foregroundStyle(ink?.primary ?? DesignSystem.Colors.textPrimary)

                Text(message)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(ink?.secondary ?? DesignSystem.Colors.textSecondary)
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

    /// Colours for the shelf's colour tags, drawn from the design system rather
    /// than invented. Each is paired with a name and a glyph at every call site
    /// — see `InboxRowView.tagLine` — so the hue is never load-bearing.
    static func color(for tag: InboxColorTag) -> Color {
        switch tag {
        case .urgent: return DesignSystem.Colors.error
        case .followUp: return DesignSystem.Colors.ember
        case .watching: return DesignSystem.Colors.amber
        case .idea: return DesignSystem.Colors.whimsy
        case .done: return DesignSystem.Colors.success
        case .onIce: return DesignSystem.Colors.frost
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

    /// What this kind of item means. Surfaced on hover so the chip is a label
    /// that can answer for itself rather than a piece of jargon.
    static func kindExplanation(_ kind: BurnBarInboxItemKind) -> String {
        switch kind {
        case .ciWaste: return "A CI pattern that keeps burning machine time without producing signal."
        case .promisedNotLanded: return "An agent said it would do something that never reached main."
        case .uncommittedWork: return "A workspace with uncommitted changes whose session has gone quiet."
        case .costAnomaly: return "Spend that deviates sharply from the trailing baseline."
        case .stuckPR: return "An open pull request that has stopped moving."
        case .indexHealth: return "The local index itself is stale or degraded."
        case .brief: return "The periodic narrative synthesis — what has been going on lately."
        case .budget: return "The daily analysis budget was reached, so synthesis fell back to rules."
        case .system: return "A capability notice from OpenBurnBar itself, not a finding about your work."
        }
    }

    /// What a priority band commits to, in plain words.
    static func priorityExplanation(_ priority: BurnBarInboxPriority) -> String {
        switch priority {
        case .p1: return "Urgent — the only band allowed to raise a notification."
        case .p2: return "Worth handling today, but it will not interrupt you."
        case .p3: return "Worth knowing. It sits in the list until you get to it."
        case .p4: return "Background context. Nothing here is asking for action."
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
