import AppKit
import Foundation
import OpenBurnBarCore
import SwiftUI

// MARK: - Receipt Drawer View

struct ReceiptDrawerView: View {
    @Bindable var dataStore: DataStore
    var onClose: (() -> Void)? = nil

    @State private var filter = ReceiptFilter()
    @State private var receipts: [ReceiptRecord] = []
    @State private var summary = ReceiptAggregateSummary()
    @State private var selectedReceiptID: String? = nil
    @State private var isLoading = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var quickFilterSelection: QuickFilterFacet = .all
    @Environment(\.colorScheme) private var colorScheme

    init(dataStore: DataStore, initialReceiptId: String? = nil, onClose: (() -> Void)? = nil) {
        self.dataStore = dataStore
        self._selectedReceiptID = State(initialValue: initialReceiptId)
        self.onClose = onClose
    }

    private var selectedReceipt: ReceiptRecord? {
        if let id = selectedReceiptID {
            return receipts.first(where: { $0.id == id })
        }
        return receipts.first
    }

    private var drawerBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.09, green: 0.09, blue: 0.10)
            : Color(red: 0.96, green: 0.96, blue: 0.97)
    }

    public var body: some View {
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
        .frame(minWidth: 780, minHeight: 560)
        .background(drawerBackground)
        .task {
            await reloadReceipts()
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
                        }
                    }
                }
            }
            .padding(10)
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
                    Text(accomplishmentPreview(for: r))
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

    private func accomplishmentPreview(for r: ReceiptRecord) -> String {
        if let first = r.actualAccomplishments.first, !first.isEmpty {
            return "☑ \(first)"
        }
        if !r.promptSummary.isEmpty {
            return r.promptSummary
        }
        return "Session completed in \(r.projectName)"
    }

    private func brandColorFor(_ provider: AgentProvider) -> Color {
        switch provider {
        case .claudeCode:
            return Color(red: 0.85, green: 0.45, blue: 0.25) // Anthropic Terracotta
        case .codex:
            return Color(red: 0.15, green: 0.68, blue: 0.55) // OpenAI Emerald
        case .cursor:
            return Color(red: 0.25, green: 0.55, blue: 0.95) // Cursor Blue
        case .xAI:
            return Color(red: 0.92, green: 0.32, blue: 0.32) // Grok Blaze
        case .muse:
            return Color(red: 0.02, green: 0.41, blue: 0.88) // Meta blue
        case .aider:
            return Color(red: 0.45, green: 0.75, blue: 0.35) // Mint
        default:
            return Color.orange
        }
    }

    // MARK: - Right Column Inspector

    private var receiptInspectorView: some View {
        ScrollView {
            VStack {
                if let receipt = selectedReceipt {
                    ReceiptDetailCardView(
                        receipt: receipt,
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

            Text("As your coding agents finish CLI sessions, itemized receipts with real accomplishments, costs, and quality reviews will print here.")
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
            if selectedReceiptID == nil || !receipts.contains(where: { $0.id == selectedReceiptID }) {
                selectedReceiptID = receipts.first?.id
            }
        } catch {
            AppLogger.dataStore.error("Failed to load receipts", metadata: ["error": "\(error)"])
        }
    }

    private func resetAllFilters() {
        filter.reset()
        quickFilterSelection = .all
        scheduleSearch()
    }
}
