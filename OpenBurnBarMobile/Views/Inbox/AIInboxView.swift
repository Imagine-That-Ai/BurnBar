import SwiftUI
import OpenBurnBarKernel

// MARK: - AI Inbox list (compact / iPhone)
//
// The list half of the surface: header, filter rail, ranked sections. Carries no
// navigation chrome of its own — no title, no search field, no toolbar — because
// it is embedded inside a host that already owns those (`StreamsView`'s chip
// rail and search field), and a second `.searchable` in the same stack would
// fight the first.
//
// `AIInboxSplitLayout` is the only thing that decides between one column and
// two, so iPhone and iPad share this exact list.
//
// Behavior matches the Mac surface (`AgentLens/Views/Inbox/InboxView.swift`):
// same four filters, same three sections, same ranking, same optimistic
// actions. The ordering and the copy live in `AIInboxStore` and
// `AIInboxPresentation`, so the two platforms cannot drift apart by someone
// editing one view.

/// Typed push destination so the inbox detail never collides with the
/// `TokenUsage` route the surrounding stack already publishes.
struct AIInboxDetailRoute: Hashable {
    let itemID: String
}

struct AIInboxView: View {
    @Bindable var store: AIInboxStore

    /// How a tapped row opens. Compact pushes onto the host's stack; the iPad
    /// two-column layout selects into its own detail column.
    enum SelectionMode {
        case push
        case inline
    }

    var selectionMode: SelectionMode = .push

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar

            if let lastError = store.lastError {
                errorBanner(lastError)
            }

            content
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: MobileTheme.Spacing.sm) {
                Text(headlineText)
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                if store.attentionCount > 0 {
                    attentionPill
                }

                Spacer(minLength: 0)

                if store.unreadCount > 0 {
                    Button {
                        HapticBus.toggle()
                        Task { await store.markEverythingRead() }
                    } label: {
                        Text("Mark all read")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.ember)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inbox.markAllRead")
                }
            }

            if let subtitle = subtitleText {
                Text(subtitle)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AuroraDesign.Layout.cardInset)
        .padding(.bottom, MobileTheme.Spacing.sm)
    }

    private var attentionPill: some View {
        Text("\(store.attentionCount) need\(store.attentionCount == 1 ? "s" : "") attention")
            .font(MobileTheme.Typography.tiny)
            .foregroundStyle(MobileTheme.amber)
            .padding(.horizontal, MobileTheme.Spacing.sm)
            .padding(.vertical, MobileTheme.Spacing.xxs)
            .background(
                Capsule(style: .continuous)
                    .fill(MobileTheme.amber.opacity(0.16))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(MobileTheme.amber.opacity(0.40), lineWidth: 1)
                    )
            )
    }

    private var headlineText: String {
        let count = store.unreadCount
        if count == 0 { return "All caught up" }
        return "\(count) new item\(count == 1 ? "" : "s")"
    }

    /// Says where the items came from and when.
    ///
    /// The inbox is written by another machine, so provenance is load-bearing
    /// rather than decoration: without it an empty list is indistinguishable
    /// from a broken one.
    private var subtitleText: String? {
        guard store.hasLoadedOnce, let refreshed = store.lastRefreshedAt else { return nil }
        return "Synced from your Mac \(MissionConsoleFormatting.relativeTime(refreshed))"
    }

    // MARK: - Filters

    private var filterBar: some View {
        AuroraChipRail(
            items: AIInboxStore.Filter.allCases,
            selection: $store.filter,
            label: { $0.title },
            icon: { $0.emptyIcon }
        )
        .padding(.bottom, MobileTheme.Spacing.sm)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(MobileTheme.warning)
            Text(message)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AuroraDesign.Layout.cardInset)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .background(MobileTheme.warning.opacity(0.08))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.isLoading && !store.hasLoadedOnce {
            loadingState
        } else if store.visibleItems.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(store.sections, id: \.section.id) { group in
                Section {
                    ForEach(group.items) { item in
                        row(for: item)
                            .listRowInsets(EdgeInsets(
                                top: MobileTheme.Spacing.xxs,
                                leading: AuroraDesign.Layout.cardInset,
                                bottom: MobileTheme.Spacing.xxs,
                                trailing: AuroraDesign.Layout.cardInset
                            ))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    sectionHeader(group.section, count: group.items.count)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .trackEasterEggScroll(tag: "inbox")
    }

    /// Builds one List row.
    ///
    /// The triage gestures are attached HERE rather than inside `AIInboxRow`:
    /// `swipeActions` and `contextMenu` only bind when applied to the row a List
    /// owns, and inside a `NavigationLink` label the swipe silently never fires.
    @ViewBuilder
    private func row(for item: AIInboxStore.Item) -> some View {
        let rowView = AIInboxRow(item: item, isSelected: store.selectedID == item.id)

        Group {
            switch selectionMode {
            case .push:
                // `NavigationLink` owns the push; the simultaneous gesture is
                // what marks the item read, because the link's own action is
                // not exposed.
                NavigationLink(value: AIInboxDetailRoute(itemID: item.id)) {
                    rowView
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    Task { await store.select(item.id) }
                })
            case .inline:
                Button {
                    Task { await store.select(item.id) }
                } label: {
                    rowView
                }
                .buttonStyle(.plain)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await store.archive(item.id) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            Button {
                Task { await store.snooze(item.id, for: 3_600) }
            } label: {
                Label("Snooze", systemImage: "clock")
            }
            .tint(MobileTheme.amber)
        }
        .contextMenu {
            Button(item.isUnread ? "Mark as read" : "Mark as unread") {
                Task { await store.toggleRead(item.id) }
            }
            Button("Snooze for an hour") { Task { await store.snooze(item.id, for: 3_600) } }
            Button("Snooze until tomorrow") { Task { await store.snooze(item.id, for: 24 * 3_600) } }
            Button("Archive", role: .destructive) { Task { await store.archive(item.id) } }
        }
    }

    private func sectionHeader(_ section: AIInboxStore.Section, count: Int) -> some View {
        HStack(spacing: MobileTheme.Spacing.xs) {
            Text(section.title.uppercased())
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.1)
                .foregroundStyle(section == .attention ? MobileTheme.amber : MobileTheme.Colors.textMuted)
            Text("\(count)")
                .font(MobileTheme.Typography.monoTiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.vertical, MobileTheme.Spacing.xxs)
        .listRowInsets(EdgeInsets(
            top: MobileTheme.Spacing.xs,
            leading: AuroraDesign.Layout.cardInset,
            bottom: MobileTheme.Spacing.xxs,
            trailing: AuroraDesign.Layout.cardInset
        ))
    }

    private var loadingState: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            ForEach(0..<5, id: \.self) { _ in
                AuroraLoadingShimmer(height: 92, cornerRadius: AuroraDesign.Shape.standardCorner)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AuroraDesign.Layout.cardInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        AuroraStatePane(
            kind: .empty,
            icon: store.filter.emptyIcon,
            title: emptyTitle,
            message: emptyMessage
        )
        .padding(.horizontal, AuroraDesign.Layout.cardInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isSearching: Bool {
        store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var emptyTitle: String {
        if isSearching { return "No matches" }
        switch store.filter {
        case .active: return store.hasEverReceivedAnItem ? "Nothing needs you" : "Nothing here yet"
        case .attention: return "Nothing urgent"
        case .resolved: return "No resolved items yet"
        case .archived: return "Nothing archived"
        }
    }

    private var emptyMessage: String {
        if isSearching {
            return "No inbox item mentions that. Try a project name or a phrase from the title."
        }
        switch store.filter {
        case .active:
            return store.hasEverReceivedAnItem
                ? "Your Mac is watching your sessions, workspaces, and GitHub. Anything worth your attention shows up here."
                : "The AI Inbox runs on your Mac and syncs here. Turn it on in OpenBurnBar on macOS and findings arrive even while the Mac is asleep."
        case .attention:
            return "No high-priority items right now. That is the good outcome."
        case .resolved:
            return "When something the inbox flagged gets fixed, it moves here with a note about what resolved it."
        case .archived:
            return "Items you archive are kept here rather than deleted."
        }
    }
}
