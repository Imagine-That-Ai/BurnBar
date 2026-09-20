import SwiftUI

// MARK: - Command Deck Palette
//
// A ⌘K command palette that unifies section navigation and session search.
// Presented as a sheet from DashboardView. Keyboard-first: ↑/↓ to move
// selection, Enter to activate, Esc to close.

struct CommandDeckPalette: View {
    var activeChatBackend: ChatBackendID?
    var searchService: SearchService?
    var onNavigate: (DashboardMainRoute) -> Void
    var onSessionJump: (ConversationJumpTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var sessionResults: [SearchResult] = []
    @State private var sessionResultsQuery: String = ""
    @State private var recentSessions: [ConversationRecord] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @AppStorage("burnRailSearch.recents.v1") private var recentsJSON: String = "[]"

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.4)
            resultsList
        }
        .frame(width: 520, height: 420)
        .background(DesignSystem.Colors.background)
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onAppear {
            inputFocused = true
            loadRecents()
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            TextField("", text: $query, prompt: Text("Jump to section or search sessions…")
                .foregroundStyle(DesignSystem.Colors.textMuted))
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .focused($inputFocused)
                .submitLabel(.go)
                .onSubmit(activateSelected)
                .onChange(of: query) { _, _ in
                    handleQueryChange()
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    inputFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DesignSystem.Colors.surface.opacity(0.5))
    }

    // MARK: - Results

    /// `primarySections` plus the Control Deck. The deck is not — and must not
    /// be — a primary section (that array is positional and drives ⌘1–⌘8), so
    /// it needs an explicit entry here or ⌘K could never reach it.
    ///
    /// The deck also matches on the search keywords of every control it hosts,
    /// so typing "accessibility", "snippet", or "daemon" finds the page that
    /// actually carries those controls.
    private var searchableSections: [DashboardMainRoute] {
        // Home leads and the deck + fleet + receipts trail, all outside
        // `primarySections` — that array is positional and drives ⌘1–⌘8, so
        // none of them can live in it. The palette is the browsable index,
        // so it carries them.
        [.home] + DashboardMainRoute.primarySections + [.controlDeck, .fleet, .receipts]
    }

    private var filteredSections: [DashboardMainRoute] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else {
            return searchableSections
        }
        return searchableSections.filter { route in
            let title = route.title(activeChatBackend: activeChatBackend).lowercased()
            let subtitle = route.subtitle(activeChatBackend: activeChatBackend).lowercased()
            if title.contains(q) || subtitle.contains(q) || matchesSubsequence(q, in: title) {
                return true
            }
            guard route == .controlDeck else { return false }
            return ControlKind.visibleKinds.contains { kind in
                kind.title.lowercased().contains(q)
                    || kind.searchKeywords.contains { $0.contains(q) }
            }
        }
    }

    private var displaySessions: [SearchResult] {
        if !trimmedQuery.isEmpty {
            return sessionResultsQuery == trimmedQuery ? sessionResults : []
        }
        return recentSessions.map { conversation in
            SearchResult(
                conversation: conversation,
                snippet: conversation.lastAssistantMessage.isEmpty
                    ? conversation.inferredTaskTitle
                    : String(conversation.lastAssistantMessage.prefix(120)),
                rank: 0
            )
        }
    }

    private var hasSessions: Bool { !displaySessions.isEmpty }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !filteredSections.isEmpty {
                        sectionHeader("Go to")
                        ForEach(Array(filteredSections.enumerated()), id: \.element) { index, route in
                            let flatIndex = index
                            paletteRow(
                                flatIndex: flatIndex,
                                isSelected: selectedIndex == flatIndex,
                                icon: route.systemImage(activeChatBackend: activeChatBackend),
                                iconColor: route.accent(activeChatBackend: activeChatBackend),
                                title: route.title(activeChatBackend: activeChatBackend),
                                subtitle: route.subtitle(activeChatBackend: activeChatBackend),
                                shortcut: route.primarySectionIndex,
                                action: { activate(route) }
                            )
                            .id(flatIndex)
                        }
                    }

                    if hasSessions {
                        sectionHeader(trimmedQuery.isEmpty ? "Recent Sessions" : "Sessions")
                        let sessionOffset = filteredSections.count
                        ForEach(Array(displaySessions.enumerated()), id: \.element.id) { index, result in
                            let flatIndex = sessionOffset + index
                            paletteRow(
                                flatIndex: flatIndex,
                                isSelected: selectedIndex == flatIndex,
                                icon: "text.bubble",
                                iconColor: DesignSystem.Colors.ember,
                                title: result.conversation.inferredTaskTitle,
                                subtitle: "\(result.conversation.provider.displayName) · \(result.conversation.projectName)",
                                shortcut: nil,
                                action: { activateSession(result) }
                            )
                            .id(flatIndex)
                        }
                    }

                    if filteredSections.isEmpty && !hasSessions && !trimmedQuery.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 24, weight: .thin))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                            Text(trimmedQuery.isEmpty ? "" : "No results for \"\(trimmedQuery)\"")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(DesignSystem.Animation.snappy) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .tracking(1.0)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func paletteRow(
        flatIndex: Int,
        isSelected: Bool,
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        shortcut: Int?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if let shortcut {
                    Text("\u{2318}\(shortcut)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? DesignSystem.Colors.ember.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                selectedIndex = flatIndex
            }
        }
    }

    // MARK: - Actions

    private func activate(_ route: DashboardMainRoute) {
        onNavigate(route)
        dismiss()
    }

    private func activateSession(_ result: SearchResult) {
        let target = ConversationJumpTarget(
            conversation: result.conversation,
            snippet: result.snippet,
            startOffset: result.startOffset,
            endOffset: result.endOffset,
            source: .retrieval
        )
        pushRecent(query: result.conversation.inferredTaskTitle)
        onSessionJump(target)
        dismiss()
    }

    private func activateSelected() {
        let sections = filteredSections
        let sessions = displaySessions
        let total = sections.count + sessions.count
        guard selectedIndex >= 0, selectedIndex < total else {
            if let first = sections.first { activate(first) }
            return
        }
        if selectedIndex < sections.count {
            activate(sections[selectedIndex])
        } else {
            let sessionIdx = selectedIndex - sections.count
            if sessionIdx < sessions.count {
                activateSession(sessions[sessionIdx])
            }
        }
    }

    private func moveSelection(by delta: Int) {
        let sections = filteredSections
        let sessions = displaySessions
        let total = sections.count + sessions.count
        guard total > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), total - 1)
    }

    // MARK: - Search debounce

    private func handleQueryChange() {
        selectedIndex = 0
        searchTask?.cancel()

        let q = trimmedQuery
        guard !q.isEmpty else {
            sessionResults = []
            sessionResultsQuery = ""
            isSearching = false
            return
        }

        sessionResults = []
        sessionResultsQuery = q
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            let results: [SearchResult]
            if let searchService {
                results = await searchService.search(query: q)
            } else {
                results = []
            }

            await MainActor.run {
                guard !Task.isCancelled, trimmedQuery == q else { return }
                sessionResults = Array(results.prefix(10))
                sessionResultsQuery = q
                isSearching = false
            }
        }
    }

    // MARK: - Recents

    private func loadRecents() {
        guard let searchService else { return }
        Task {
            let recents = await searchService.recentConversations(limit: 6)
            await MainActor.run {
                recentSessions = recents
            }
        }
    }

    private var recents: [String] {
        guard let data = recentsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return list
    }

    private func pushRecent(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = recents.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        next.insert(trimmed, at: 0)
        if next.count > 6 { next.removeLast(next.count - 6) }
        if let data = try? JSONEncoder().encode(next),
           let json = String(data: data, encoding: .utf8) {
            recentsJSON = json
        }
    }

    // MARK: - Subsequence match

    private func matchesSubsequence(_ pattern: String, in text: String) -> Bool {
        var pi = pattern.startIndex
        var ti = text.startIndex
        while pi < pattern.endIndex && ti < text.endIndex {
            if pattern[pi] == text[ti] {
                pi = pattern.index(after: pi)
            }
            ti = text.index(after: ti)
        }
        return pi == pattern.endIndex
    }
}
