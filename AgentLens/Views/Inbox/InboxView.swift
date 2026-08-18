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
///
/// Management (pin, tag, category, order, save, delete, bulk) follows the mail
/// client contract: **every gesture has a keyboard and VoiceOver equivalent.**
/// Drag-and-drop and context menus are unreachable without a mouse, so the same
/// verbs appear in the actions menu (with shortcuts) and in
/// `.accessibilityActions` on each row — the `ControlDeckGrid` precedent.
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
    @Environment(\.backdropReadabilityProfile) private var backdropProfile

    /// Non-nil while a bulk delete is waiting for confirmation.
    @State private var pendingDelete: [String]?
    @State private var isNamingCategory = false
    @State private var categoryDraft = ""
    /// The row a drag is currently hovering, for the reorder insertion hint.
    @State private var dropTargetID: String?
    /// The category chip a drag is currently hovering.
    @State private var dropTargetCategory: String?

    /// How the inbox splits its space.
    ///
    /// The focused `.inbox` route uses `listAndDetail`. The Home surface's
    /// `triage` mode uses `listOnly`, because at the narrow width band Home's
    /// detail pane is only ~448pt — half-useless for reading, and the wrong
    /// shape for clearing thirty items. In `listOnly`, opening an item
    /// navigates to the focused route rather than presenting a sheet: one
    /// route, no new modal.
    enum PaneStyle: Equatable {
        case listAndDetail
        case listOnly
    }

    let paneStyle: PaneStyle
    /// Posted by the host when daemon-written rows may have changed.
    ///
    /// `nil` on surfaces that should stay frozen while being read — the focused
    /// route passes nil so a re-sort never happens under the user's cursor
    /// mid-read. Home passes the shared cadence notification.
    let refreshNotification: Notification.Name?
    /// Invoked in `listOnly` when a row is activated, so the host can navigate
    /// to the focused inbox instead of opening a detail pane that isn't there.
    let onActivateItem: ((String) -> Void)?

    init(
        model: InboxModel,
        onOpenSessionLog: @escaping (String) -> Void,
        onOpenSettings: @escaping () -> Void,
        memoryApproval: InboxMemoryApprovalHandler? = nil,
        openItemID: String? = nil,
        paneStyle: PaneStyle = .listAndDetail,
        refreshNotification: Notification.Name? = nil,
        onActivateItem: ((String) -> Void)? = nil
    ) {
        // Own the model in `@State` so DashboardView body re-evals that rebuild
        // a throwaway `InboxModel(...)` cannot wipe selection mid-click.
        _model = State(initialValue: model)
        self.onOpenSessionLog = onOpenSessionLog
        self.onOpenSettings = onOpenSettings
        self.memoryApproval = memoryApproval
        self.openItemID = openItemID
        self.paneStyle = paneStyle
        self.refreshNotification = refreshNotification
        self.onActivateItem = onActivateItem
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                listPane
                    .frame(
                        width: paneStyle == .listOnly
                            ? nil
                            : Self.listPaneWidth(forTotalWidth: proxy.size.width)
                    )
                    .frame(
                        minWidth: 0,
                        maxWidth: paneStyle == .listOnly ? .infinity : nil,
                        minHeight: 0,
                        maxHeight: .infinity
                    )

                if paneStyle == .listAndDetail {
                    Divider().background(DesignSystem.Colors.border)

                    detailPane
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
            }
        }
        .modifier(InboxAutoRefresh(name: refreshNotification) { await model.load() })
        .task {
            await model.load(force: true)
            await model.loadTelemetry()
            // Garbage-collect arrangement records for items the inbox no longer
            // has. Done on open rather than on the refresh cadence: it is a full
            // listing and it does not need re-running every thirty seconds.
            await model.pruneShelf()
            if let openItemID {
                await model.select(itemID: openItemID)
            }
        }
        .accessibilityIdentifier(OBBAccessibilityID.inboxRoot)
    }

    /// Text roles resolved for whatever this pane is drawn over.
    ///
    /// Never `DesignSystem.Colors.textMuted`: it measures 3.77:1 against the
    /// app's own `surface` and has never cleared 4.5:1 on any background this
    /// app can draw. It is a hairline token that was being used for body copy.
    private var ink: BackdropInk {
        BackdropInk.resolve(liveBackdropActive: liveBackdropActive, profile: backdropProfile)
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            header
            filterBar
            managementBar

            if model.selection.isEmpty == false {
                selectionBar
            }

            if categoryRailIsVisible {
                categoryRail
            }

            if let undo = model.deleteUndo {
                undoBanner(undo)
            }

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
        .background(keyboardShortcuts)
        .animation(DesignSystem.Animation.gentle, value: model.selection.isEmpty)
        .animation(DesignSystem.Animation.gentle, value: model.deleteUndo)
        .confirmationDialog(
            "Delete \(pendingDelete?.count ?? 0) item\((pendingDelete?.count ?? 0) == 1 ? "" : "s")?",
            isPresented: pendingDeleteBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { confirmPendingDelete() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("They disappear from every tab, including Archived. You can undo this for a few seconds afterwards.")
        }
        .alert("File into a new category", isPresented: $isNamingCategory) {
            TextField("Category name", text: $categoryDraft)
            Button("File") { applyCategoryDraft() }
            Button("Cancel", role: .cancel) { categoryDraft = "" }
        } message: {
            Text("Categories are your own labels. Reuse one from the menu instead of respelling it.")
        }
    }

    private var pendingDeleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { presented in if presented == false { pendingDelete = nil } }
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text("INBOX")
                    .font(DesignSystem.Typography.tiny)
                    .tracking(1.4)
                    .foregroundStyle(ink.subtle)

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
                            .foregroundStyle(ink.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Mark every open item as read")
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text(headlineText)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(ink.primary)

                if model.attentionCount > 0 {
                    attentionPill
                }
            }

            if let subtitle = subtitleText {
                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(ink.subtle)
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
            // "no model calls" read as a normal state and hid the real story:
            // the brief was authored by the rule-based fallback. Say so — and
            // when egress is on, name the budget gate as the likely reason
            // instead of pretending the silence is fine.
            // Do not name a cause the run telemetry cannot actually prove. The
            // analyst is skipped for three different reasons (egress off,
            // budget spent, or an empty evidence pack — nothing indexed in the
            // window), and only the egress one is visible here. Guessing
            // "check budget" sent a reader hunting through settings while the
            // real cause was an index that had not caught up yet.
            let cost: String
            if run.costUSD > 0 {
                cost = String(format: " · $%.3f", run.costUSD)
            } else if run.egressMode.allowsModelCalls {
                cost = " · rule-based brief (no model ran)"
            } else {
                cost = " · rule-based brief (model egress off)"
            }
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(InboxModel.Filter.allCases) { filter in
                    filterChip(filter)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
        }
        // A `ScrollView` claims every axis it is offered; the chips must keep
        // their intrinsic height or the bar swallows the list.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, DesignSystem.Spacing.sm)
    }

    private func filterChip(_ filter: InboxModel.Filter) -> some View {
        let isActive = model.filter == filter
        return Button {
            withAnimation(DesignSystem.Animation.snappy) { model.filter = filter }
        } label: {
            Text(filter.title)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(isActive ? ink.primary : ink.secondary)
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

    // MARK: - Management bar

    /// Sort mode plus the actions menu. Everything in the menu carries its
    /// keyboard shortcut, so the menu doubles as the discoverability surface for
    /// the shortcuts.
    private var managementBar: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            orderingMenu
            Spacer(minLength: 0)
            actionsMenu
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.bottom, DesignSystem.Spacing.sm)
    }

    private var orderingMenu: some View {
        Menu {
            Picker("Order", selection: orderingBinding) {
                ForEach(InboxModel.Ordering.allCases) { ordering in
                    Label(ordering.title, systemImage: ordering.symbolName).tag(ordering)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Image(systemName: model.ordering.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                Text(model.ordering.title)
                    .font(DesignSystem.Typography.tiny)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(ink.secondary)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(
                Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.ordering.explanation)
        .accessibilityIdentifier(OBBAccessibilityID.inboxOrderingMenu)
    }

    private var orderingBinding: Binding<InboxModel.Ordering> {
        Binding(
            get: { model.ordering },
            set: { newValue in
                withAnimation(DesignSystem.Animation.gentle) { model.ordering = newValue }
            }
        )
    }

    /// Every management verb in one place.
    ///
    /// The shortcuts themselves are registered by `keyboardShortcuts` (hidden
    /// always-present buttons) rather than declared on these items: a shortcut
    /// declared *both* here and there would register the same key twice, and a
    /// double-fired toggle is a silent no-op. So this menu names them instead —
    /// which is also the only way the shortcuts are discoverable at all.
    private var actionsMenu: some View {
        Menu {
            Section("Selection") {
                Button("Select all in list") { model.selectAllVisible() }
                Button("Deselect all") { model.clearSelection() }
                    .disabled(model.selection.isEmpty)
            }

            Section(targetSummary) {
                Button(pinTitle) { model.togglePin(model.actionTargets) }
                Button(saveTitle) { model.toggleSaved(model.actionTargets) }
                Menu("Tag") { tagMenuItems(for: model.actionTargets) }
                Menu("File into") { categoryMenuItems(for: model.actionTargets) }
            }

            Section {
                Button("Archive") { Task { await model.archive(ids: model.actionTargets) } }
                Button("Delete", role: .destructive) { requestDelete() }
                if model.deleteUndo != nil {
                    Button("Undo delete") { Task { await model.undoDelete() } }
                }
            }

            if model.ordering.allowsManualReorder {
                Section("Manual order") {
                    Button("Move up") { nudgeFocused(-1) }
                    Button("Move down") { nudgeFocused(1) }
                }
            }

            Section("Keyboard") {
                ForEach(Self.shortcutHints(manualOrdering: model.ordering.allowsManualReorder), id: \.self) { hint in
                    Text(hint)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ink.icon)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Never disabled: "Select all in list" lives in here, so a disabled
        // menu would make selecting anything from the keyboard impossible.
        .help("Manage the selected items")
        .accessibilityLabel("Inbox actions")
        .accessibilityIdentifier(OBBAccessibilityID.inboxActionsMenu)
    }

    private var targetSummary: String {
        let count = model.actionTargets.count
        switch count {
        case 0: return "Nothing selected"
        case 1: return "This item"
        default: return "\(count) selected"
        }
    }

    private var pinTitle: String {
        let targets = model.actionTargets
        let allPinned = targets.isEmpty == false && targets.allSatisfy { model.shelf.isPinned($0) }
        return allPinned ? "Unpin" : "Pin to top"
    }

    private var saveTitle: String {
        let targets = model.actionTargets
        let allSaved = targets.isEmpty == false && targets.allSatisfy { model.shelf.isSaved($0) }
        return allSaved ? "Remove from Saved" : "Save"
    }

    @ViewBuilder
    private func tagMenuItems(for ids: [String]) -> some View {
        Button("No tag") { model.setColorTag(nil, ids: ids) }
        Divider()
        ForEach(InboxColorTag.allCases) { tag in
            Button {
                model.setColorTag(tag, ids: ids)
            } label: {
                Label(tag.displayName, systemImage: tag.symbolName)
            }
        }
    }

    @ViewBuilder
    private func categoryMenuItems(for ids: [String]) -> some View {
        Button("No category") { model.setCategory(nil, ids: ids) }
        Divider()
        ForEach(Self.categoryChoices(presets: InboxCategoryPresets.all, inUse: model.categoriesInUse), id: \.self) { name in
            Button(name) { model.setCategory(name, ids: ids) }
        }
        Divider()
        Button("New category…") { beginNamingCategory() }
    }

    /// The shortcut table, kept beside the buttons that register it in
    /// `keyboardShortcuts` so the two cannot drift apart unnoticed.
    static func shortcutHints(manualOrdering: Bool) -> [String] {
        var hints = [
            "⇧⌘A  Select all in list",
            "⇧⌘D  Deselect all",
            "⇧⌘P  Pin / unpin",
            "⇧⌘S  Save / unsave",
            "⌃⌘A  Archive",
            "⌘⌫  Delete",
            "⌘Z  Undo delete"
        ]
        if manualOrdering {
            hints.append("⌥↑ / ⌥↓  Move up / down")
        }
        return hints
    }

    /// The presets plus anything already in use, de-duplicated
    /// case-insensitively so "Costs" and "costs" never both appear.
    static func categoryChoices(presets: [String], inUse: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in presets + inUse {
            let key = name.lowercased()
            guard seen.contains(key) == false else { continue }
            seen.insert(key)
            result.append(name)
        }
        return result
    }

    // MARK: - Selection bar

    private var selectionBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("\(model.selection.count) selected")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(ink.primary)

            Spacer(minLength: 0)

            bulkButton("Archive", systemImage: "archivebox") {
                Task { await model.archive(ids: model.actionTargets) }
            }
            bulkButton("Delete", systemImage: "trash", tint: DesignSystem.Colors.error) {
                requestDelete()
            }
            bulkButton("Done", systemImage: "xmark") { model.clearSelection() }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(selectionBarBackground)
        .accessibilityIdentifier(OBBAccessibilityID.inboxSelectionBar)
    }

    private func bulkButton(
        _ title: String,
        systemImage: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
                Text(title).font(DesignSystem.Typography.tiny)
            }
            .foregroundStyle(tint ?? ink.secondary)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(
                Capsule().stroke((tint ?? ink.hairline).opacity(0.55), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(model.selection.count) selected items")
    }

    @ViewBuilder
    private var selectionBarBackground: some View {
        if liveBackdropActive {
            ZStack {
                Rectangle().fill(DesignSystem.Colors.surface.opacity(BackdropSubstrate.liveElevated))
                Rectangle().fill(DesignSystem.Colors.ember.opacity(0.08))
            }
        } else {
            DesignSystem.Colors.ember.opacity(0.08)
        }
    }

    // MARK: - Category rail

    /// "File into" targets. A chip is both a button (click to file the current
    /// targets) and a drop destination (drag a row onto it), because moving an
    /// item between categories is what "move" means in an inbox with no folders.
    private var categoryRailIsVisible: Bool {
        model.categoriesInUse.isEmpty == false
    }

    private var categoryRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text("FILE INTO")
                    .font(DesignSystem.Typography.tiny)
                    .tracking(1.0)
                    .foregroundStyle(ink.subtle)

                ForEach(model.categoriesInUse, id: \.self) { category in
                    categoryChip(category)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, DesignSystem.Spacing.sm)
    }

    private func categoryChip(_ category: String) -> some View {
        let isTarget = dropTargetCategory == category
        return Button {
            model.setCategory(category, ids: model.actionTargets)
        } label: {
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Image(systemName: "folder").font(.system(size: 9, weight: .semibold))
                Text(category).font(DesignSystem.Typography.tiny).lineLimit(1)
            }
            .foregroundStyle(isTarget ? ink.primary : ink.secondary)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(
                Capsule()
                    .fill(isTarget ? DesignSystem.Colors.whimsy.opacity(0.18) : Color.clear)
                    .overlay(
                        Capsule().stroke(
                            isTarget ? DesignSystem.Colors.whimsy.opacity(0.7) : DesignSystem.Colors.borderSubtle,
                            lineWidth: 1
                        )
                    )
            )
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { items, _ in
            dropTargetCategory = nil
            let ids = knownRowIDs(in: items)
            guard ids.isEmpty == false else { return false }
            model.setCategory(category, ids: ids)
            return true
        } isTargeted: { targeted in
            dropTargetCategory = targeted ? category : nil
        }
        .help("File the selection into \(category), or drag an item onto it")
        .accessibilityLabel("File selection into \(category)")
        .accessibilityIdentifier(OBBAccessibilityID.inboxCategoryChip(category))
    }

    /// A drop payload is arbitrary text until proven otherwise. Only ids that
    /// name a row the inbox is actually showing are honoured.
    private func knownRowIDs(in items: [String]) -> [String] {
        let known = Set(model.rows.map(\.id))
        return items.filter { known.contains($0) }
    }

    // MARK: - Undo banner

    private func undoBanner(_ undo: InboxModel.DeleteUndo) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink.icon)

            Text(undo.message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(ink.primary)

            Spacer(minLength: 0)

            Button("Undo") { Task { await model.undoDelete() } }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.ember)

            Button {
                model.dismissUndo()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ink.icon)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(undoBannerBackground)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(OBBAccessibilityID.inboxUndoBanner)
    }

    @ViewBuilder
    private var undoBannerBackground: some View {
        if liveBackdropActive {
            ZStack {
                Rectangle().fill(DesignSystem.Colors.surface.opacity(BackdropSubstrate.liveElevated))
                Rectangle().fill(DesignSystem.Colors.blaze.opacity(0.10))
            }
        } else {
            DesignSystem.Colors.blaze.opacity(0.10)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystem.Colors.warning)
            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.warning.opacity(0.08))
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(model.sections, id: \.section.id) { group in
                    Section {
                        ForEach(group.rows) { row in
                            rowView(row)
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

    private func rowView(_ row: ControlPlaneStore.AIInboxRow) -> some View {
        InboxRowView(
            row: row,
            entry: model.shelf.entry(row.id),
            isOpen: model.selectedID == row.id,
            isChecked: model.selection.contains(row.id),
            hasSelection: model.selection.isEmpty == false,
            allowsDrag: allowsDrag,
            allowsReorder: model.ordering.allowsManualReorder,
            isDropTarget: dropTargetID == row.id,
            categoryChoices: Self.categoryChoices(
                presets: InboxCategoryPresets.all,
                inUse: model.categoriesInUse
            ),
            actions: rowActions(for: row.id),
            ink: ink,
            onDropTargeted: { targeted in dropTargetID = targeted ? row.id : nil }
        )
    }

    /// Dragging is only wired up where it means something: manual ordering
    /// (drop onto a row) or a category rail to drop onto. Elsewhere the row
    /// stays a plain button, which keeps clicks crisp — `GlassCard(interactive:)`
    /// already documents how easily a drag gesture steals a click here.
    private var allowsDrag: Bool {
        model.ordering.allowsManualReorder || categoryRailIsVisible
    }

    private func rowActions(for id: String) -> InboxRowActions {
        InboxRowActions(
            click: { intent in
                model.click(id, intent: intent)
                // In `listOnly` there is no detail pane to receive the
                // selection, so a plain click hands off to the focused route.
                // Command/shift clicks are multi-select and stay local.
                if paneStyle == .listOnly, intent == .replace {
                    onActivateItem?(id)
                }
            },
            toggleRead: { Task { await model.toggleRead(id) } },
            togglePin: { model.togglePin(targets(including: id)) },
            toggleSaved: { model.toggleSaved(targets(including: id)) },
            setTag: { tag in model.setColorTag(tag, ids: targets(including: id)) },
            setCategory: { category in model.setCategory(category, ids: targets(including: id)) },
            newCategory: { beginNamingCategory(anchoredTo: id) },
            snooze: { interval in Task { await model.snooze(id, for: interval) } },
            archive: { Task { await model.archive(ids: targets(including: id)) } },
            delete: { requestDelete(ids: targets(including: id)) },
            nudge: { offset in model.nudgeManual(id, offset: offset) },
            dropRow: { draggedID in
                dropTargetID = nil
                guard knownRowIDs(in: [draggedID]).isEmpty == false else { return }
                model.moveManual(draggedID, onto: id)
            }
        )
    }

    /// A row action applies to the whole selection when the row is part of it,
    /// and to just that row otherwise — the mail-client rule.
    private func targets(including id: String) -> [String] {
        guard model.selection.contains(id) else { return [id] }
        return model.actionTargets
    }

    private func sectionHeader(_ section: InboxModel.Section, count: Int) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            if section == .pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
            }

            Text(section.title.uppercased())
                .font(DesignSystem.Typography.tiny)
                .tracking(1.1)
                .foregroundStyle(section == .attention ? DesignSystem.Colors.amber : ink.subtle)

            Text("\(count)")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(ink.subtle)

            Spacer(minLength: 0)

            if section == .manual {
                Text("drag to reorder")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(ink.subtle)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(sectionHeaderBackground)
        .accessibilityIdentifier(OBBAccessibilityID.inboxSectionHeader(section.rawValue))
    }

    @ViewBuilder
    private var sectionHeaderBackground: some View {
        if liveBackdropActive {
            // Glass alone refracts, it does not darken — a pinned header over a
            // live kernel needs the substrate slab under it or the eyebrow type
            // dissolves into whatever the backdrop is painting.
            ZStack {
                Rectangle().fill(DesignSystem.Colors.surface.opacity(BackdropSubstrate.liveElevated))
                Rectangle().fill(.ultraThinMaterial)
            }
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    private var loadingState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            ProgressView()
            Text("Reading your inbox…")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(ink.subtle)
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
        case .saved: return "Nothing saved yet"
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
        case .saved:
            return "Save an item — from its context menu, or ⌘⇧S — and it stays here no matter what the daemon does to it."
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
                memoryApproval: memoryApproval,
                // Fingerprint-keyed on purpose (L1): reselecting the item after
                // a resolve/reopen cycle lands on the same conversation.
                threadFingerprint: row.summary.fingerprint
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

    // MARK: - Keyboard

    /// Zero-size buttons that exist purely to register window-level shortcuts,
    /// the `MacAgentInsightsWorkspace.keyboardShortcuts` idiom. A shortcut
    /// declared only inside a `Menu` body is not registered until the menu is
    /// opened, which would make every one of these mouse-only.
    private var keyboardShortcuts: some View {
        VStack(spacing: 0) {
            shortcutButton("a", modifiers: [.command, .shift]) { model.selectAllVisible() }
            shortcutButton("d", modifiers: [.command, .shift]) { model.clearSelection() }
            shortcutButton("p", modifiers: [.command, .shift]) { model.togglePin(model.actionTargets) }
            shortcutButton("s", modifiers: [.command, .shift]) { model.toggleSaved(model.actionTargets) }
            shortcutButton("a", modifiers: [.command, .control]) {
                Task { await model.archive(ids: model.actionTargets) }
            }
            shortcutButton(.delete, modifiers: .command) { requestDelete() }
            if model.deleteUndo != nil {
                shortcutButton("z", modifiers: .command) { Task { await model.undoDelete() } }
            }
            if model.ordering.allowsManualReorder {
                shortcutButton(.upArrow, modifiers: .option) { nudgeFocused(-1) }
                shortcutButton(.downArrow, modifiers: .option) { nudgeFocused(1) }
            }
        }
    }

    private func shortcutButton(
        _ key: KeyEquivalent,
        modifiers: EventModifiers,
        action: @escaping () -> Void
    ) -> some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func nudgeFocused(_ offset: Int) {
        model.nudgeManual(ids: model.actionTargets, offset: offset)
    }

    // MARK: - Actions

    private func requestDelete() {
        requestDelete(ids: model.actionTargets)
    }

    private func requestDelete(ids: [String]) {
        guard ids.isEmpty == false else { return }
        guard InboxModel.requiresDeleteConfirmation(count: ids.count) else {
            Task { await model.delete(ids) }
            return
        }
        pendingDelete = ids
    }

    private func confirmPendingDelete() {
        let ids = pendingDelete ?? []
        pendingDelete = nil
        guard ids.isEmpty == false else { return }
        Task { await model.delete(ids) }
    }

    private func beginNamingCategory(anchoredTo id: String? = nil) {
        if let id, model.selection.contains(id) == false, model.selection.isEmpty {
            model.click(id, intent: .replace)
        }
        categoryDraft = ""
        isNamingCategory = true
    }

    private func applyCategoryDraft() {
        let name = InboxShelfStore.normalizeCategory(categoryDraft)
        categoryDraft = ""
        guard let name else { return }
        model.setCategory(name, ids: model.actionTargets)
    }

    /// Resolves a click's modifier keys into a selection intent.
    ///
    /// Read from `NSEvent` rather than layered `TapGesture().modifiers(_:)`
    /// gestures: a modified tap fires the plain button action *as well*, so the
    /// gesture approach needs a side-channel flag and races with it.
    static func selectionIntent(for flags: NSEvent.ModifierFlags) -> InboxModel.SelectionIntent {
        if flags.contains(.shift) { return .extend }
        if flags.contains(.command) { return .toggle }
        return .replace
    }

    /// The list keeps a comfortable 380pt on a desk-width window, but yields to
    /// the reading pane as the window narrows — a fixed 380 left the detail pane
    /// unusably thin below ~900pt, which is exactly where the detail layout has
    /// the least room to spare.
    static func listPaneWidth(forTotalWidth total: CGFloat) -> CGFloat {
        guard total > 0 else { return 380 }
        return min(380, max(260, total * 0.32))
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

// MARK: - Ink

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
