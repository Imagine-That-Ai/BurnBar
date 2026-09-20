import AppKit
import Foundation
import OpenBurnBarKernel
import SwiftUI

// MARK: - Receipt Drawer View

struct ReceiptDrawerView: View {
    @Bindable var dataStore: DataStore
    var focusedReceiptID: String?
    var focusedLens: ReceiptLens?
    var focusToken: UUID
    var onClose: (() -> Void)?
    var onFocusedReceiptConsumed: (() -> Void)?

    @State private var filter = ReceiptFilter()
    @State private var receipts: [ReceiptRecord] = []
    @State private var summary = ReceiptAggregateSummary()
    @State private var selectedReceiptID: String?
    @State private var pinnedReceiptID: String?
    @State private var isLoading = false
    @State private var searchTask: Task<Void, Never>?
    @State private var quickFilterSelection: QuickFilterFacet = .all
    @State private var conversationOverlays: [String: ReceiptConversationOverlay] = [:]
    @State private var didHydrateChat = false
    @State private var inspectorLensOverride: ReceiptLens?
    @Environment(\.colorScheme) private var colorScheme

    init(
        dataStore: DataStore,
        initialReceiptId: String? = nil,
        initialLens: ReceiptLens? = nil,
        focusToken: UUID = UUID(),
        onClose: (() -> Void)? = nil,
        onFocusedReceiptConsumed: (() -> Void)? = nil
    ) {
        self.dataStore = dataStore
        self.focusedReceiptID = initialReceiptId
        self.focusedLens = initialLens
        self.focusToken = focusToken
        self.onClose = onClose
        self.onFocusedReceiptConsumed = onFocusedReceiptConsumed
        self._selectedReceiptID = State(initialValue: initialReceiptId)
        self._pinnedReceiptID = State(initialValue: initialReceiptId)
        self._inspectorLensOverride = State(initialValue: initialLens)
    }

    private var selectedReceipt: ReceiptRecord? {
        if let id = selectedReceiptID,
           let match = receipts.first(where: { $0.id == id }) {
            return match
        }
        return receipts.first
    }

    private var drawerBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.09, green: 0.09, blue: 0.10)
            : Color(red: 0.96, green: 0.96, blue: 0.97)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Register Tape Aggregate Header
            ReceiptRegisterTapeHeader(
                summary: summary,
                receipts: receipts,
                hasActiveFilters: filter.hasActiveFilters,
                onClearFilters: resetAllFilters
            )

            // Search Bar & Filter Strip
            filterToolbar

            Divider()
                .opacity(0.3)

            // Main Split: Receipt Stacks List & Selected Receipt Inspector
            if isLoading && receipts.isEmpty {
                loadingView
            } else if receipts.isEmpty {
                emptyView
            } else {
                contentSplitView
            }
        }
        // No hard minimum here: `OpenBurnBarWindowManager` already applies
        // `.frame(minWidth: 840, minHeight: 600)` at both window call sites, and as
        // a dashboard section this view must compress like every sibling route
        // rather than overflow the 1040x650 dashboard window minimum.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(drawerBackground)
        .task {
            if !didHydrateChat {
                _ = try? await dataStore.hydrateReceiptChatSummaries()
                didHydrateChat = true
            }
            await applyFocusedReceipt(focusedReceiptID)
            await reloadReceipts()
        }
        .onChange(of: focusedReceiptID) { _, newID in
            Task { await applyFocusedReceipt(newID) }
        }
        .onChange(of: focusToken) { _, _ in
            inspectorLensOverride = focusedLens
            Task { await applyFocusedReceipt(focusedReceiptID) }
        }
    }

    // MARK: - Filter Toolbar

    private var filterToolbar: some View {
        VStack(spacing: 8) {
            // Search Input Row
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))

                    TextField("Search prompt, files, model, or 'spend:>1.00'…", text: $filter.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: filter.searchQuery) { _, _ in
                            scheduleSearch()
                        }

                    if !filter.searchQuery.isEmpty {
                        Button {
                            filter.searchQuery = ""
                            scheduleSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

                // Grouping Picker
                Picker("Group", selection: $filter.grouping) {
                    ForEach(ReceiptGroupingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Receipt Drawer")
                }
            }

            // Facet Filter Chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    facetChip(title: "All Receipts", facet: .all)
                    facetChip(title: "Spend > $0.50", facet: .costOver50c)
                    facetChip(title: "High Cache (>80%)", facet: .highCache)
                    facetChip(title: "Graded A/A+", facet: .gradedHigh)
                    facetChip(title: "Starred ★", facet: .starredOnly)
                    facetChip(title: "Today", facet: .today)
                    facetChip(title: "Past 7 Days", facet: .past7Days)
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func facetChip(title: String, facet: QuickFilterFacet) -> some View {
        let isSelected = (quickFilterSelection == facet)
        return Button {
            if isSelected {
                quickFilterSelection = .all
                applyFacetFilter(.all)
            } else {
                quickFilterSelection = facet
                applyFacetFilter(facet)
            }
            scheduleSearch()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isSelected ? Color.orange : Color.primary.opacity(0.05))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Split Content

    private var contentSplitView: some View {
        HSplitView {
            // Left Column: Stacks of Receipts (Ticket Stub Style)
            receiptsListView
                .frame(minWidth: 330, idealWidth: 380, maxWidth: 460)

            // Right Column: Active Receipt Inspector Card
            receiptInspectorView
                .frame(minWidth: 400, maxWidth: .infinity)
        }
    }

    private var receiptsListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(groupedReceiptSections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(section.title.uppercased())
                                    .font(.system(size: 9.5, weight: .black, design: .monospaced))
                                    .tracking(0.8)
                                    .foregroundStyle(.secondary)

                                Text("(\(section.receipts.count))")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 8)

                            ForEach(section.receipts) { r in
                                receiptRowItem(r)
                                    .id(r.id)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .onChange(of: selectedReceiptID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Perforated Ticket Stub Row

    private func receiptRowItem(_ r: ReceiptRecord) -> some View {
        let isSelected = (selectedReceipt?.id == r.id)
        let brandColor = brandColorFor(r.provider)

        return Button {
            selectedReceiptID = r.id
        } label: {
            HStack(spacing: 0) {
                // Left Brand Color Notch
                Rectangle()
                    .fill(brandColor)
                    .frame(width: 4)

                // Ticket Stub Body
                VStack(alignment: .leading, spacing: 5) {
                    // Line 1: Harness + Project + Time + Grade + Star
                    HStack(spacing: 6) {
                        Text(r.harness.uppercased())
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(brandColor.opacity(0.15))
                            .foregroundStyle(brandColor)
                            .clipShape(RoundedRectangle(cornerRadius: 2.5))

                        Text(r.projectName)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Text(r.timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Spacer()

                        if let review = r.qualityReview {
                            Text(review.grade)
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 2.5))
                        }

                        if r.isStarred {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.yellow)
                        }

                        Text(r.formattedCost)
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundStyle(.primary)
                    }

                    // Line 2: Accomplishment Punchline or Prompt Goal
                    Text(ReceiptChatBridge.listPreview(receipt: r, overlay: overlay(for: r)))
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    // Line 3: Metric Badges Strip
                    HStack(spacing: 6) {
                        chip(icon: "clock", text: r.formattedDuration)
                        chip(icon: "number", text: r.formattedTokens)

                        if r.cacheHitPercentage > 0 {
                            chip(icon: "arrow.triangle.2.circlepath", text: String(format: "%.0f%%c", r.cacheHitPercentage))
                        }

                        if let git = r.gitStats, git.filesChanged > 0 {
                            chip(icon: "arrow.triangle.branch", text: "+\(git.insertions)/-\(git.deletions)")
                        }

                        Spacer()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.orange.opacity(0.10) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.orange.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: isSelected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 7.5))
            Text(text)
                .font(.system(size: 9, design: .monospaced))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func brandColorFor(_ provider: AgentProvider) -> Color {
        ReceiptHarnessInk.color(for: provider)
    }

    // MARK: - Right Column Inspector

    private var receiptInspectorView: some View {
        ScrollView {
            VStack {
                if let receipt = selectedReceipt {
                    ReceiptDetailCardView(
                        receipt: receipt,
                        overlay: overlay(for: receipt),
                        dataStore: dataStore,
                        requestedLens: inspectorLensOverride,
                        lensRequestToken: focusToken,
                        onToggleStar: { newStarred in
                            Task {
                                try? await dataStore.setReceiptStarred(receiptId: receipt.id, isStarred: newStarred)
                                if let idx = receipts.firstIndex(where: { $0.id == receipt.id }) {
                                    receipts[idx].isStarred = newStarred
                                }
                            }
                        },
                        onUpdateReview: { newReview in
                            Task {
                                try? await dataStore.updateReceiptQualityReview(receiptId: receipt.id, review: newReview)
                                if let idx = receipts.firstIndex(where: { $0.id == receipt.id }) {
                                    receipts[idx].qualityReview = newReview
                                }
                            }
                        }
                    )
                    // No `.id(receipt.id)` here on purpose: it would rebuild the
                    // subtree on every selection, making the card's and the slip's
                    // `onChange(of: receipt.id)` resets unreachable *and* throwing
                    // away the lens the user picked. The resets are the mechanism.
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                } else {
                    Text("Select a receipt to view")
                        .foregroundStyle(.secondary)
                        .padding(.top, 60)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading receipts register…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: "scroll.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange.opacity(0.8))

            Text("No Receipts in Register")
                .font(.system(size: 14, weight: .bold, design: .rounded))

            Text("As your coding agents finish CLI sessions, itemized receipts with the chat summary, transcript, cost, and git proof will print here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if filter.hasActiveFilters {
                Button("Reset Filters") {
                    resetAllFilters()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Section Grouping Logic

    private struct GroupedSection {
        let title: String
        let receipts: [ReceiptRecord]
    }

    private var groupedReceiptSections: [GroupedSection] {
        switch filter.grouping {
        case .date:
            let calendar = Calendar.current
            let groups = Dictionary(grouping: receipts) { r -> String in
                if calendar.isDateInToday(r.timestamp) {
                    return "Today"
                } else if calendar.isDateInYesterday(r.timestamp) {
                    return "Yesterday"
                } else {
                    return r.timestamp.formatted(date: .abbreviated, time: .omitted)
                }
            }
            return groups.map { GroupedSection(title: $0.key, receipts: $0.value) }
                .sorted { s1, s2 in
                    if s1.title == "Today" { return true }
                    if s2.title == "Today" { return false }
                    if s1.title == "Yesterday" { return true }
                    if s2.title == "Yesterday" { return false }
                    return s1.title > s2.title
                }
        case .project:
            let groups = Dictionary(grouping: receipts, by: { $0.projectName })
            return groups.map { GroupedSection(title: $0.key, receipts: $0.value) }
                .sorted { $0.title < $1.title }
        case .harness:
            let groups = Dictionary(grouping: receipts, by: { $0.harness })
            return groups.map { GroupedSection(title: $0.key, receipts: $0.value) }
                .sorted { $0.title < $1.title }
        case .provider:
            let groups = Dictionary(grouping: receipts, by: { $0.provider.displayName })
            return groups.map { GroupedSection(title: $0.key, receipts: $0.value) }
                .sorted { $0.title < $1.title }
        case .model:
            let groups = Dictionary(grouping: receipts, by: { $0.modelName })
            return groups.map { GroupedSection(title: $0.key, receipts: $0.value) }
                .sorted { $0.title < $1.title }
        }
    }

    // MARK: - Filter and Search Operations

    private enum QuickFilterFacet {
        case all
        case costOver50c
        case highCache
        case gradedHigh
        case starredOnly
        case today
        case past7Days
    }

    private func applyFacetFilter(_ facet: QuickFilterFacet) {
        let calendar = Calendar.current
        let now = Date()

        switch facet {
        case .all:
            filter.minCost = nil
            filter.minCachePercentage = nil
            filter.isStarredOnly = false
            filter.dateRange = nil
        case .costOver50c:
            filter.minCost = 0.50
            filter.minCachePercentage = nil
            filter.isStarredOnly = false
            filter.dateRange = nil
        case .highCache:
            filter.minCost = nil
            filter.minCachePercentage = 80.0
            filter.isStarredOnly = false
            filter.dateRange = nil
        case .gradedHigh:
            filter.minCost = nil
            filter.minCachePercentage = nil
            filter.isStarredOnly = false
            filter.dateRange = nil
        case .starredOnly:
            filter.minCost = nil
            filter.minCachePercentage = nil
            filter.isStarredOnly = true
            filter.dateRange = nil
        case .today:
            let startOfToday = calendar.startOfDay(for: now)
            filter.dateRange = startOfToday...now
            filter.minCost = nil
            filter.minCachePercentage = nil
            filter.isStarredOnly = false
        case .past7Days:
            let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
            filter.dateRange = sevenDaysAgo...now
            filter.minCost = nil
            filter.minCachePercentage = nil
            filter.isStarredOnly = false
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await reloadReceipts()
        }
    }

    private func reloadReceipts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await dataStore.fetchReceipts(filter: filter, limit: 250)
            let stats = try await dataStore.calculateReceiptAggregateSummary(filter: filter)

            if quickFilterSelection == .gradedHigh {
                receipts = fetched.filter { r in
                    guard let review = r.qualityReview else { return false }
                    return review.grade == "A+" || review.grade == "A"
                }
            } else {
                receipts = fetched
            }

            summary = stats
            conversationOverlays = (try? await dataStore.fetchReceiptConversationOverlays(
                sessionIDs: receipts.map(\.sessionId)
            )) ?? [:]
            if let pinned = pinnedReceiptID {
                await ensureReceiptVisible(pinned)
                selectedReceiptID = pinned
            } else if selectedReceiptID == nil || !receipts.contains(where: { $0.id == selectedReceiptID }) {
                selectedReceiptID = receipts.first?.id
            }
        } catch {
            AppLogger.dataStore.error("Failed to load receipts", metadata: ["error": "\(error)"])
        }
    }

    private func overlay(for receipt: ReceiptRecord) -> ReceiptConversationOverlay? {
        ReceiptConversationOverlay.lookup(receipt.sessionId, in: conversationOverlays)
    }

    private func applyFocusedReceipt(_ id: String?) async {
        guard let id, !id.isEmpty else { return }
        pinnedReceiptID = id
        selectedReceiptID = id
        await ensureReceiptVisible(id)
        onFocusedReceiptConsumed?()
    }

    private func ensureReceiptVisible(_ id: String) async {
        if receipts.contains(where: { $0.id == id }) { return }
        guard let extra = try? await dataStore.fetchReceipt(id: id) else { return }
        receipts = ReceiptRegisterFocus.inserting(extra, into: receipts)
        if conversationOverlays[extra.sessionId] == nil,
           let extraOverlays = try? await dataStore.fetchReceiptConversationOverlays(
            sessionIDs: [extra.sessionId]
           ) {
            conversationOverlays.merge(extraOverlays) { _, new in new }
        }
    }

    private func resetAllFilters() {
        filter.reset()
        quickFilterSelection = .all
        scheduleSearch()
    }
}

/// Pure merge so a notification-tapped slip stays selected even when the
/// current filter or 250-row window would have dropped it.
enum ReceiptRegisterFocus: Sendable {
    static func inserting(_ receipt: ReceiptRecord, into receipts: [ReceiptRecord]) -> [ReceiptRecord] {
        if receipts.contains(where: { $0.id == receipt.id }) { return receipts }
        return [receipt] + receipts
    }
}
