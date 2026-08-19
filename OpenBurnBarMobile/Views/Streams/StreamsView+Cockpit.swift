import SwiftUI
import Charts
import OpenBurnBarCore

// The conversation cockpit section: KPI header, facet bar, conversation rows, detail + filter sheets.
// Extracted from StreamsView.swift (god-file decomposition) — same module, verbatim.

//
// The cockpit transforms Streams into a faceted database over every backed-up
// agent conversation. KPI header (server aggregates) → facet bar (providers,
// model, sort, saved queries) → dense decrypted result list → full-transcript
// reader. Gated behind Cloud entitlement with a teaser veil for free users so
// the value is visible before purchase.
struct ConversationCockpitSection: View {
    let store: ConversationCockpitStore
    let searchText: String
    let streamSearchHits: [StreamSearchHit]
    let cloudSearchHits: [CloudConversationSearchRow]
    let isSearching: Bool
    var searchFailed: Bool = false
    let isEntitled: Bool
    let bottomPadding: CGFloat
    let onSelectRow: (CockpitConversationRow) -> Void
    let onSelectCloudHit: (CloudConversationSearchRow) -> Void
    let onOpenFilters: () -> Void
    let onSaveQuery: () -> Void
    let onOpenStore: () -> Void
    var onRetrySearch: () -> Void = {}

    var body: some View {
        if isEntitled {
            entitledBody
        } else {
            lockedBody
        }
    }

    // MARK: Locked teaser

    private var lockedBody: some View {
        LockedFeatureVeil(
            headline: "Every conversation, queryable.",
            detail: "A private cockpit over every Codex, Claude, Droid, and CLI-agent session — faceted search, cost and token rollups, and full encrypted transcripts. Included with OpenBurnBar Cloud.",
            ctaLabel: "Open Cloud",
            icon: "rectangle.3.group.fill",
            action: onOpenStore
        ) {
            CockpitTeaserBackground()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Entitled cockpit

    private var filteredRows: [CockpitConversationRow] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return store.rows }
        return store.rows.filter { row in
            (row.title?.lowercased().contains(trimmed) ?? false)
                || (row.preview?.lowercased().contains(trimmed) ?? false)
                || (row.model?.lowercased().contains(trimmed) ?? false)
                || (row.provider?.lowercased().contains(trimmed) ?? false)
        }
    }

    private var searchResultMode: StreamsSearchResultMode {
        StreamsSearchResultState(
            query: searchText,
            isSearching: isSearching,
            cloudConversationHitCount: cloudSearchHits.count,
            streamHitCount: streamSearchHits.count,
            searchFailed: searchFailed
        ).mode
    }

    private var entitledBody: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                CockpitKPIHeader(aggregates: store.aggregates, rows: store.rows)
                CockpitFacetBar(
                    store: store,
                    onOpenFilters: onOpenFilters,
                    onSaveQuery: onSaveQuery
                )

                if store.vaultLocked {
                    vaultNotice
                }

                content
            }
            .padding(.horizontal, AuroraDesign.Layout.cardInset)
            .padding(.top, 4)
            .padding(.bottom, bottomPadding)
        }
        .task(id: store.filterSignature) {
            await store.runQuery(reset: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        if searchResultMode != .inactive {
            remoteSearchContent
        } else if store.isLoading && store.rows.isEmpty {
            VStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { _ in
                    AuroraLoadingShimmer(height: 86, cornerRadius: 16)
                }
            }
            .padding(.top, 4)
        } else if let error = store.error, store.rows.isEmpty {
            AuroraStatePane(
                kind: .error,
                icon: "exclamationmark.triangle",
                title: "Query failed",
                message: error,
                ctaLabel: "Try Again",
                onCTA: { Task { await store.runQuery(reset: true) } }
            )
            .frame(minHeight: 300)
        } else if filteredRows.isEmpty {
            AuroraStatePane(
                kind: .empty,
                icon: hasNarrowingInput ? "magnifyingglass" : "rectangle.3.group",
                title: hasNarrowingInput ? "No matches" : "No conversations yet",
                message: hasNarrowingInput
                    ? "Adjust or clear the filters to widen your search."
                    : "Turn on conversation backup on your Mac and every session will appear here — fully searchable, end-to-end encrypted."
            )
            .frame(minHeight: 300)
        } else {
            ForEach(filteredRows) { row in
                Button { onSelectRow(row) } label: {
                    CockpitConversationRowView(row: row)
                }
                .buttonStyle(.plain)
                .onAppear { store.loadNextPageIfNeeded(currentRow: row) }
            }
            if store.isPaginating {
                paginationProgress
            } else if store.hasMore {
                loadMoreButton
            }
        }
    }

    @ViewBuilder
    private var remoteSearchContent: some View {
        switch searchResultMode {
        case .inactive:
            EmptyView()
        case .cloudConversationHits:
            ForEach(cloudSearchHits) { hit in
                Button { onSelectCloudHit(hit) } label: {
                    CloudConversationSearchResultRow(hit: hit)
                }
                .buttonStyle(.plain)
            }
        case .streamHits:
            ForEach(streamSearchHits) { hit in
                NavigationLink(value: hit.usage) {
                    StreamSearchResultRow(hit: hit)
                }
                .buttonStyle(.plain)
            }
        case .searching:
            ProgressView()
                .tint(MobileTheme.ember)
                .frame(maxWidth: .infinity, minHeight: 260)
                .padding(.vertical, 24)
        case .failed:
            AuroraStatePane(
                kind: .error,
                icon: "exclamationmark.icloud.fill",
                title: "Search failed",
                message: "Could not search sessions. Try again.",
                ctaLabel: "Try Again",
                onCTA: onRetrySearch
            )
            .frame(minHeight: 300)
        case .empty:
            AuroraStatePane(
                kind: .empty,
                icon: "magnifyingglass",
                title: "No matches",
                message: "Try a different model, provider, or private transcript search term."
            )
            .frame(minHeight: 300)
        }
    }

    private var paginationProgress: some View {
        ProgressView()
            .tint(MobileTheme.ember)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    private var loadMoreButton: some View {
        Button {
            Task { await store.loadNextPage() }
        } label: {
            Label("Load more", systemImage: "arrow.down.circle")
                .font(MobileTheme.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.ember)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private var hasNarrowingInput: Bool {
        store.hasActiveFilters || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var vaultNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.rotation")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MobileTheme.warning)
            Text("Titles stay sealed until this device receives the vault key — facets, filters, and totals still work.")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MobileTheme.warning.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(MobileTheme.warning.opacity(0.35), lineWidth: 0.75)
                )
        )
    }
}

struct CockpitTeaserBackground: View {
    var body: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            HStack(spacing: MobileTheme.Spacing.md) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .fill(MobileTheme.Colors.surface)
                        .frame(height: 76)
                }
            }
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(MobileTheme.Colors.surface.opacity(0.7))
                    .frame(height: 70)
            }
            Spacer(minLength: 0)
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MobileTheme.Colors.background)
    }
}

struct CockpitKPIHeader: View {
    let aggregates: ConversationQueryAggregates?
    let rows: [CockpitConversationRow]

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                kpiTile(title: "Conversations", value: conversationsText, icon: "bubble.left.and.bubble.right.fill", tint: MobileTheme.ember)
                kpiTile(title: "Total cost", value: costText, icon: "dollarsign.circle.fill", tint: MobileTheme.Colors.primary(for: .codex))
                kpiTile(title: "Tokens", value: tokensText, icon: "number.circle.fill", tint: MobileTheme.Colors.primary(for: .claudeCode))
            }
            if providerTokenMix.count > 1 {
                tokenMixChart
            }
        }
    }

    private func kpiTile(title: String, value: String, icon: String, tint: Color) -> some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16, interactive: false, padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(title)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var conversationsText: String {
        if let count = aggregates?.count { return count.formatted(.number.grouping(.automatic)) }
        return rows.count.formatted(.number.grouping(.automatic))
    }

    private var costText: String {
        (aggregates?.totalCostUSD ?? rows.reduce(0) { $0 + $1.costUSD }).formatAsCost()
    }

    private var tokensText: String {
        (aggregates?.totalTokens ?? rows.reduce(0) { $0 + $1.totalTokens }).formatAsTokenVolume()
    }

    private struct ProviderTokenSlice: Identifiable {
        let provider: String
        let tokens: Int
        var id: String { provider }
    }

    private var providerTokenMix: [ProviderTokenSlice] {
        var totals: [String: Int] = [:]
        for row in rows {
            guard let provider = row.provider, !provider.isEmpty else { continue }
            totals[provider, default: 0] += row.totalTokens
        }
        return totals
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map { ProviderTokenSlice(provider: $0.key, tokens: $0.value) }
    }

    private var tokenMixChart: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16, interactive: false, padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("TOKEN MIX · LOADED")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(1.1)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Chart(providerTokenMix) { item in
                    BarMark(
                        x: .value("Tokens", item.tokens),
                        y: .value("Provider", providerLabel(item.provider))
                    )
                    .foregroundStyle(providerColor(item.provider))
                    .cornerRadius(4)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(item.tokens.formatAsTokenVolume())
                            .font(MobileTheme.Typography.monoTiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
                .chartXAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: CGFloat(providerTokenMix.count) * 30 + 6)
                .accessibilityLabel("Token mix by provider for loaded conversations")
            }
        }
    }

    private func providerLabel(_ token: String) -> String {
        AgentProvider.fromPersistedToken(token)?.displayName ?? token.capitalized
    }

    private func providerColor(_ token: String) -> Color {
        AgentProvider.fromPersistedToken(token).map { MobileTheme.Colors.primary(for: $0) } ?? MobileTheme.ember
    }
}

struct CockpitFacetBar: View {
    let store: ConversationCockpitStore
    let onOpenFilters: () -> Void
    let onSaveQuery: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 8) {
            // Main Tray Card
            VStack(spacing: 0) {
                collapsedBar

                if isExpanded {
                    expandedPanel
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(MobileTheme.Colors.surface.opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(MobileTheme.Colors.borderSubtle.opacity(0.7), lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 3)
            .padding(.vertical, 2)

            if !store.savedQueries.isEmpty {
                savedQueryRail
            }
        }
    }

    private var collapsedBar: some View {
        HStack(spacing: 0) {
            // Expand / Collapse Trigger
            Button {
                HapticBus.toggle()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isExpanded ? MobileTheme.ember : MobileTheme.Colors.textSecondary)
                    Text(isExpanded ? "Collapse" : "Sort & Filter")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.bold)
                        .foregroundStyle(isExpanded ? MobileTheme.ember : MobileTheme.Colors.textPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(isExpanded ? MobileTheme.ember.opacity(0.12) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .padding(.vertical, 6)

            // Vertical Separator
            Rectangle()
                .fill(MobileTheme.Colors.borderSubtle.opacity(0.5))
                .frame(width: 1, height: 22)
                .padding(.horizontal, 8)

            // Scrollable Quick Filters
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Sort Chip (compact)
                    Button {
                        HapticBus.toggle()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isExpanded = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: store.sortField.systemImage)
                                .font(.system(size: 10, weight: .semibold))
                            Text(store.sortField.label)
                                .font(MobileTheme.Typography.tiny)
                                .fontWeight(.semibold)
                            Image(systemName: store.sortDirection.systemImage)
                                .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(MobileTheme.ember)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(MobileTheme.ember.opacity(0.12))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(MobileTheme.ember.opacity(0.5), lineWidth: 0.75)
                        )
                    }
                    .buttonStyle(.plain)

                    // Model Chip (if selected)
                    if let model = store.selectedModel {
                        Button {
                            HapticBus.toggle()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                isExpanded = true
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "cpu")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(model)
                                    .font(MobileTheme.Typography.tiny)
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(MobileTheme.ember)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(MobileTheme.ember.opacity(0.12))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(MobileTheme.ember.opacity(0.5), lineWidth: 0.75)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // Quick Provider Toggles
                    if !store.discoveredProviders.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(store.discoveredProviders, id: \.self) { provider in
                                let active = store.selectedProviders.contains(provider)
                                Button {
                                    HapticBus.chipChange()
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                        store.toggleProvider(provider)
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        if let p = AgentProvider.fromPersistedToken(provider) {
                                            ProviderAvatar(provider: p, mode: .plain, size: 12)
                                        }
                                        Text(providerDisplayName(provider))
                                            .font(MobileTheme.Typography.tiny)
                                            .fontWeight(.semibold)
                                    }
                                    .foregroundStyle(active ? MobileTheme.ember : MobileTheme.Colors.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(active ? MobileTheme.ember.opacity(0.15) : MobileTheme.Colors.surfaceElevated.opacity(0.6))
                                    )
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(active ? MobileTheme.ember.opacity(0.5) : MobileTheme.Colors.borderSubtle.opacity(0.5), lineWidth: 0.75)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.trailing, 12)
            }
            .scrollClipDisabled()
        }
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
                .background(MobileTheme.Colors.borderSubtle.opacity(0.4))
                .padding(.horizontal, 12)

            // SORT BY SECTION
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("SORT BY")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.bold)
                        .tracking(1.2)
                        .foregroundStyle(MobileTheme.Colors.textMuted)

                    Spacer()

                    // Direction Selector
                    HStack(spacing: 2) {
                        Button {
                            HapticBus.chipChange()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                store.sortDirection = .desc
                            }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 10, weight: .bold))
                                .padding(6)
                                .background(store.sortDirection == .desc ? MobileTheme.ember : Color.clear)
                                .foregroundStyle(store.sortDirection == .desc ? Color.white : MobileTheme.Colors.textSecondary)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            HapticBus.chipChange()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                store.sortDirection = .asc
                            }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 10, weight: .bold))
                                .padding(6)
                                .background(store.sortDirection == .asc ? MobileTheme.ember : Color.clear)
                                .foregroundStyle(store.sortDirection == .asc ? Color.white : MobileTheme.Colors.textSecondary)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(2)
                    .background(MobileTheme.Colors.surfaceElevated.opacity(0.8))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(MobileTheme.Colors.borderSubtle.opacity(0.5), lineWidth: 0.5)
                    )
                }
                .padding(.horizontal, 14)

                // Sort Options Grid (3 columns)
                let columns = [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ]

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(ConversationSortField.allCases) { field in
                        let active = store.sortField == field
                        Button {
                            HapticBus.chipChange()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                store.sortField = field
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: field.systemImage)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(field.label)
                                    .font(.system(size: 10, weight: .bold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(active ? MobileTheme.ember.opacity(0.15) : MobileTheme.Colors.surfaceElevated.opacity(0.6))
                            .foregroundStyle(active ? MobileTheme.ember : MobileTheme.Colors.textSecondary)
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(active ? MobileTheme.ember.opacity(0.6) : MobileTheme.Colors.borderSubtle.opacity(0.4), lineWidth: 0.75)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }

            // PROVIDERS SECTION
            if !store.discoveredProviders.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PROVIDERS")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.bold)
                        .tracking(1.2)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .padding(.horizontal, 14)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.discoveredProviders, id: \.self) { provider in
                                let active = store.selectedProviders.contains(provider)
                                let providerEnum = AgentProvider.fromPersistedToken(provider)
                                Button {
                                    HapticBus.chipChange()
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                        store.toggleProvider(provider)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        if let p = providerEnum {
                                            ProviderAvatar(provider: p, mode: .plain, size: 14)
                                        }
                                        Text(providerDisplayName(provider))
                                            .font(.system(size: 11, weight: .bold))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(active ? MobileTheme.ember.opacity(0.15) : MobileTheme.Colors.surfaceElevated.opacity(0.6))
                                    .foregroundStyle(active ? MobileTheme.ember : MobileTheme.Colors.textSecondary)
                                    .cornerRadius(10)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(active ? MobileTheme.ember.opacity(0.6) : MobileTheme.Colors.borderSubtle.opacity(0.4), lineWidth: 0.75)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .scrollClipDisabled()
                }
            }

            // MODELS SECTION
            if !store.discoveredModels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MODEL")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.bold)
                        .tracking(1.2)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .padding(.horizontal, 14)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // Any model option
                            let isAnyActive = store.selectedModel == nil
                            Button {
                                HapticBus.chipChange()
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                    store.selectedModel = nil
                                }
                            } label: {
                                Text("Any model")
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(isAnyActive ? MobileTheme.ember.opacity(0.15) : MobileTheme.Colors.surfaceElevated.opacity(0.6))
                                    .foregroundStyle(isAnyActive ? MobileTheme.ember : MobileTheme.Colors.textSecondary)
                                    .cornerRadius(10)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(isAnyActive ? MobileTheme.ember.opacity(0.6) : MobileTheme.Colors.borderSubtle.opacity(0.4), lineWidth: 0.75)
                                    )
                            }
                            .buttonStyle(.plain)

                            ForEach(store.discoveredModels, id: \.self) { model in
                                let active = store.selectedModel == model
                                Button {
                                    HapticBus.chipChange()
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                        store.selectedModel = model
                                    }
                                } label: {
                                    Text(model)
                                        .font(.system(size: 11, weight: .bold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(active ? MobileTheme.ember.opacity(0.15) : MobileTheme.Colors.surfaceElevated.opacity(0.6))
                                        .foregroundStyle(active ? MobileTheme.ember : MobileTheme.Colors.textSecondary)
                                        .cornerRadius(10)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(active ? MobileTheme.ember.opacity(0.6) : MobileTheme.Colors.borderSubtle.opacity(0.4), lineWidth: 0.75)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .scrollClipDisabled()
                }
            }

            // ACTIONS BAR
            VStack(spacing: 0) {
                Divider()
                    .background(MobileTheme.Colors.borderSubtle.opacity(0.4))
                    .padding(.bottom, 10)

                HStack(spacing: 10) {
                    // Advanced Filters Sheet
                    Button {
                        HapticBus.sheetOpen()
                        onOpenFilters()
                    } label: {
                        Label("Advanced", systemImage: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(MobileTheme.Colors.surfaceElevated.opacity(0.7))
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)

                    // Save Query
                    Button {
                        HapticBus.sheetOpen()
                        onSaveQuery()
                    } label: {
                        Label("Save Query", systemImage: "bookmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(MobileTheme.Colors.surfaceElevated.opacity(0.7))
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)

                    // Clear button
                    if store.hasActiveFilters {
                        Button {
                            HapticBus.destructive()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                store.clearFilters()
                            }
                        } label: {
                            Label("Clear", systemImage: "xmark.circle")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(MobileTheme.warning)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(MobileTheme.warning.opacity(0.12))
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    // Done collapsing button
                    Button {
                        HapticBus.toggle()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isExpanded = false
                        }
                    } label: {
                        Text("Done")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(MobileTheme.ember)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(MobileTheme.ember.opacity(0.12))
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 12)
        }
    }

    private var savedQueryRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.savedQueries) { query in
                    Button {
                        HapticBus.chipChange()
                        store.applySavedQuery(query)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(query.name)
                                .font(MobileTheme.Typography.tiny)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                        }
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(MobileTheme.Colors.surface.opacity(0.6))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(MobileTheme.Colors.borderSubtle.opacity(0.6), lineWidth: 0.75)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            HapticBus.destructive()
                            store.deleteSavedQuery(query)
                        } label: {
                            Label("Delete saved query", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func providerDisplayName(_ token: String) -> String {
        AgentProvider.fromPersistedToken(token)?.displayName ?? token.capitalized
    }
}

struct CockpitConversationRowView: View {
    let row: CockpitConversationRow

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16, interactive: true, padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                header
                if let preview = row.preview, !preview.isEmpty {
                    Text(preview)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                metaLine
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let provider = row.providerEnum {
                ProviderAuroraAvatar(provider: provider, size: 36, animated: false, glassInCard: true)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(MobileTheme.ember.opacity(0.16))
                        .frame(width: 36, height: 36)
                    Image(systemName: "lock.doc")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(MobileTheme.ember)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if !row.hasDecryptedTitle {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    Text(row.displayTitle)
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                }
                subtitle
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.costUSD.formatAsCost())
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(row.totalTokens.formatAsTokens())
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
    }

    private var subtitle: some View {
        HStack(spacing: 4) {
            if let model = row.model, !model.isEmpty {
                Text(model).lineLimit(1)
            }
            if let date = row.updatedAt ?? row.startTime {
                Text("·").foregroundStyle(MobileTheme.Colors.textMuted)
                Text(date, format: .relative(presentation: .named))
                    .lineLimit(1)
            }
        }
        .font(MobileTheme.Typography.tiny)
        .foregroundStyle(MobileTheme.Colors.textMuted)
    }

    @ViewBuilder
    private var metaLine: some View {
        if row.messageCount > 0 || (row.durationSeconds ?? 0) > 0 || !row.toolTags.isEmpty {
            HStack(spacing: 8) {
                if row.messageCount > 0 {
                    Label("\(row.messageCount)", systemImage: "bubble.left.and.bubble.right")
                }
                if let duration = row.durationSeconds, duration > 0 {
                    Label(Self.formatDuration(duration), systemImage: "clock")
                }
                ForEach(row.toolTags.prefix(3), id: \.self) { tag in
                    Text(tag)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(MobileTheme.Colors.surface.opacity(0.7))
                        )
                }
                Spacer(minLength: 0)
            }
            .font(MobileTheme.Typography.monoTiny)
            .foregroundStyle(MobileTheme.Colors.textMuted)
        }
    }

    static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        return remMinutes == 0 ? "\(hours)h" : "\(hours)h \(remMinutes)m"
    }
}

struct CockpitConversationDetailSheet: View {
    let store: ConversationCockpitStore
    let row: CockpitConversationRow

    @Environment(\.dismiss) private var dismiss
    @State private var transcript: String?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    facetGrid
                    Divider().overlay(MobileTheme.Colors.borderSubtle)
                    transcriptSection
                }
                .padding(AuroraDesign.Layout.cardInset)
            }
            .background(AuroraBackdrop())
            .navigationTitle("Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                if let exportURL {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: exportURL, preview: SharePreview(row.displayTitle)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .task(id: row.id) { await load() }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let provider = row.providerEnum {
                    ProviderAuroraAvatar(provider: provider, size: 40, animated: false)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayTitle)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var facetGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            facetCell("Cost", row.costUSD.formatAsCost(), "dollarsign.circle")
            facetCell("Tokens", row.totalTokens.formatAsTokens(), "number")
            if row.inputTokens > 0 || row.outputTokens > 0 {
                facetCell("In · Out", "\(row.inputTokens.formatAsTokens()) · \(row.outputTokens.formatAsTokens())", "arrow.left.arrow.right")
            }
            if row.messageCount > 0 {
                facetCell("Messages", "\(row.messageCount)", "bubble.left.and.bubble.right")
            }
            if let model = row.model, !model.isEmpty {
                facetCell("Model", model, "cpu")
            }
            if let duration = row.durationSeconds, duration > 0 {
                facetCell("Duration", CockpitConversationRowView.formatDuration(duration), "clock")
            }
            if let date = row.startTime ?? row.updatedAt {
                facetCell("Started", date.formatted(date: .abbreviated, time: .shortened), "calendar")
            }
            if let source = row.sourceType, !source.isEmpty {
                facetCell("Source", source.capitalized, "shippingbox")
            }
        }
    }

    private func facetCell(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MobileTheme.ember)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Text(value)
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(MobileTheme.Colors.borderSubtle.opacity(0.5), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if isLoading {
            VStack(spacing: 10) {
                ForEach(0..<5, id: \.self) { _ in
                    AuroraLoadingShimmer(height: 18, cornerRadius: 6)
                }
            }
            .padding(.top, 4)
        } else if let loadError {
            AuroraStatePane(
                kind: .error,
                icon: "exclamationmark.lock",
                title: "Could not open transcript",
                message: loadError,
                ctaLabel: "Try Again",
                onCTA: { Task { await load() } }
            )
            .frame(minHeight: 200)
        } else if let transcript, !transcript.isEmpty {
            Text(transcript)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(row.preview ?? "No transcript available.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let body = try await store.loadTranscript(for: row)
            transcript = body
            exportURL = try? writeExportFile(body: body)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Builds a shareable Markdown document (metadata header + transcript),
    /// mirroring the Mac bundle export, and writes it to a temp `.md` file so
    /// the share sheet presents a named document instead of raw text.
    private func writeExportFile(body: String) throws -> URL {
        let markdown = makeExportMarkdown(body: body)
        let slug = Self.slug(from: row.displayTitle)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenBurnBar-\(slug).md")
        try markdown.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    private func makeExportMarkdown(body: String) -> String {
        var lines: [String] = ["# \(row.displayTitle)", "", "| Property | Value |", "|----------|-------|"]
        lines.append("| Provider | \(row.providerEnum?.displayName ?? row.provider ?? "—") |")
        if let model = row.model, !model.isEmpty { lines.append("| Model | \(model) |") }
        if let start = row.startTime {
            lines.append("| Started | \(start.formatted(date: .abbreviated, time: .shortened)) |")
        }
        if row.messageCount > 0 { lines.append("| Messages | \(row.messageCount) |") }
        if row.totalTokens > 0 { lines.append("| Tokens | \(row.totalTokens.formatAsTokens()) |") }
        if row.costUSD > 0 { lines.append("| Cost | \(row.costUSD.formatAsCost()) |") }
        lines.append("")
        lines.append("## Transcript")
        lines.append("")
        lines.append(body.isEmpty ? "_No transcript body was available._" : body)
        return lines.joined(separator: "\n")
    }

    private static func slug(from text: String) -> String {
        let mapped = text.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "conversation" : String(trimmed.prefix(60))
    }
}

struct CockpitFilterSheet: View {
    let store: ConversationCockpitStore

    @Environment(\.dismiss) private var dismiss
    @State private var useDateRange = false
    @State private var fromDate = Date()
    @State private var toDate = Date()
    @State private var cacheLimitMegabytes = CloudTranscriptCacheSettings.shared.maxMegabytes
    @State private var cacheSnapshot = CloudTranscriptCacheSnapshot(
        usageBytes: 0,
        maxBytes: CloudTranscriptCacheSettings.shared.maxBytes
    )
    @State private var isCachingLoadedTranscripts = false
    @State private var cacheStatus: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Filter by start date", isOn: $useDateRange.animation())
                    if useDateRange {
                        DatePicker("From", selection: $fromDate, displayedComponents: .date)
                        DatePicker("To", selection: $toDate, in: fromDate..., displayedComponents: .date)
                    }
                } header: {
                    Text("Date range")
                } footer: {
                    Text("Date filtering sorts by start time. Other sort fields apply once the date filter is cleared.")
                }
                Section {
                    Stepper(value: $cacheLimitMegabytes, in: 0...CloudTranscriptCacheSettings.maximumMegabytes, step: 50) {
                        HStack(spacing: 10) {
                            Image(systemName: "internaldrive")
                                .foregroundStyle(MobileTheme.ember)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cache limit")
                                Text(cacheLimitLabel)
                                    .font(MobileTheme.Typography.tiny)
                                    .foregroundStyle(MobileTheme.Colors.textMuted)
                            }
                        }
                    }

                    HStack {
                        Label("Used", systemImage: "chart.pie")
                        Spacer()
                        Text(cacheUsageLabel)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .monospacedDigit()
                    }

                    Button {
                        Task { await cacheLoadedTranscripts() }
                    } label: {
                        Label(
                            isCachingLoadedTranscripts ? "Downloading" : "Download loaded",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .disabled(isCachingLoadedTranscripts || store.rows.isEmpty || cacheSnapshot.isDisabled)

                    Button(role: .destructive) {
                        Task {
                            try? await CloudTranscriptCache.shared.clear()
                            cacheStatus = "Cache cleared"
                            await refreshCacheSnapshot()
                        }
                    } label: {
                        Label("Clear cache", systemImage: "trash")
                    }
                    .disabled(cacheSnapshot.usageBytes == 0)

                    if let cacheStatus {
                        Text(cacheStatus)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                } header: {
                    Text("Transcript cache")
                } footer: {
                    Text("Encrypted on this device. Default 250 MB.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AuroraBackdrop(density: .subtle).ignoresSafeArea())
            .navigationTitle("Cockpit Filters")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: hydrate)
            .task { await refreshCacheSnapshot() }
            .onChange(of: cacheLimitMegabytes) { _, newValue in
                CloudTranscriptCacheSettings.shared.maxMegabytes = newValue
                Task {
                    await CloudTranscriptCache.shared.trimToLimit()
                    await refreshCacheSnapshot()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") { apply() }
                        .buttonStyle(.aurora(.primary))
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        store.clearFilters()
                        dismiss()
                    }
                    .foregroundStyle(MobileTheme.warning)
                }
            }
        }
    }

    private func hydrate() {
        useDateRange = store.dateFrom != nil || store.dateTo != nil
        fromDate = store.dateFrom ?? Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        toDate = store.dateTo ?? Date()
        cacheLimitMegabytes = CloudTranscriptCacheSettings.shared.maxMegabytes
    }

    private func apply() {
        if useDateRange {
            store.dateFrom = Calendar.current.startOfDay(for: fromDate)
            store.dateTo = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: toDate) ?? toDate
        } else {
            store.dateFrom = nil
            store.dateTo = nil
        }
        dismiss()
    }

    private var cacheLimitLabel: String {
        if cacheLimitMegabytes <= 0 { return "Off" }
        return CloudTranscriptCacheSettings.formatBytes(
            Int64(cacheLimitMegabytes) * CloudTranscriptCacheSettings.bytesPerMegabyte
        )
    }

    private var cacheUsageLabel: String {
        if cacheSnapshot.isDisabled {
            return "\(CloudTranscriptCacheSettings.formatBytes(cacheSnapshot.usageBytes)) / Off"
        }
        return "\(CloudTranscriptCacheSettings.formatBytes(cacheSnapshot.usageBytes)) / \(CloudTranscriptCacheSettings.formatBytes(cacheSnapshot.maxBytes))"
    }

    private func refreshCacheSnapshot() async {
        cacheSnapshot = await CloudTranscriptCache.shared.snapshot()
    }

    private func cacheLoadedTranscripts() async {
        guard !isCachingLoadedTranscripts else { return }
        isCachingLoadedTranscripts = true
        cacheStatus = nil
        defer { isCachingLoadedTranscripts = false }

        let result = await store.cacheLoadedTranscripts()
        await refreshCacheSnapshot()
        var parts: [String] = []
        if result.available > 0 { parts.append("\(result.available) available offline") }
        if result.skipped > 0 { parts.append("\(result.skipped) missing body") }
        if result.failed > 0 { parts.append("\(result.failed) failed") }
        if result.limitReached { parts.append("limit reached") }
        cacheStatus = parts.isEmpty ? "No loaded conversations to cache" : parts.joined(separator: " · ")
    }
}
