import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Streams View
//
// Unified surface for the conversation cockpit, sessions, activity, and
// projects. A chip rail at the top switches between segments; each renders an
// Aurora-tuned list backed by existing stores plus the cockpit + ProjectsStore.

//
// Unified surface for the conversation cockpit, sessions, activity, and
// projects. A chip rail at the top switches between segments; each renders an
// Aurora-tuned list backed by existing stores plus the cockpit + ProjectsStore.
struct StreamsView: View {
    /// Hoisted by the tab roots so the Firestore listeners survive a tab swap
    /// (the roots' `contentForSelection` switch destroys this view tree on every
    /// change). See `AIInboxStore.loadIfNeeded`.
    let inbox: AIInboxStore

    @State private var activity = ActivityStore()
    @State private var projects = ProjectsStore()
    @State private var cockpit = ConversationCockpitStore()
    @State private var segment: Segment = .inbox
    @State private var searchText = ""
    @State private var showFilters = false
    @State private var selectedCloudConversation: CloudConversationSearchRow?
    @State private var cloudConversationBody: String?
    @State private var cloudConversationError: String?
    @State private var isLoadingCloudConversation = false
    @State private var selectedCockpitRow: CockpitConversationRow?
    @State private var showCockpitFilters = false
    @State private var showSaveQuery = false
    @State private var saveQueryName = ""
    @State private var showCloudStore = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.cloudSubscriptionStore) private var cloudStore

    private static let iPhoneNavigationTrayClearance: CGFloat = 112

    private var isCloudEntitled: Bool { cloudStore?.isActive ?? false }

    enum Segment: String, CaseIterable, Identifiable, Hashable {
        /// First on purpose: the AI Inbox is the only segment that tells you
        /// something you did not already know to look for, so it is what Streams
        /// opens on.
        case inbox
        case cockpit, sessions, projects, activity
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .inbox: return "tray.full.fill"
            case .cockpit: return "rectangle.3.group.fill"
            case .sessions: return "doc.text.magnifyingglass"
            case .projects: return "folder.fill.badge.gearshape"
            case .activity: return "list.bullet.rectangle"
            }
        }
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(visibility: streamsBackgroundVisibility)
            VStack(spacing: 0) {
                AuroraChipRail(
                    items: Segment.allCases,
                    selection: $segment,
                    label: { $0.label },
                    icon: { $0.icon }
                )
                .padding(.bottom, 6)

                Group {
                    switch segment {
                    case .inbox: inboxSurface
                    case .cockpit: cockpitList
                    case .sessions: sessionsList
                    case .projects: projectsList
                    case .activity: activityList
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .trackEasterEggScroll(tag: "streams")
            }
        }
        .navigationTitle("Streams")
        .accessibilityIdentifier("screen.streams")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilters = true } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(MobileTheme.ember)
                        .symbolEffect(.bounce, value: showFilters)
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: searchPrompt)
        .task(id: searchText) {
            await activity.updateSearch(query: searchText)
        }
        .navigationDestination(for: AIInboxDetailRoute.self) { route in
            inboxDetail(for: route)
        }
        // A `burnbar://inbox` deep link lands on Streams, which may be sitting on
        // any segment. Without this the push would open the tab and leave the
        // user on Cockpit, one tap short of the thing they were notified about.
        .onChange(of: inbox.focusRequestToken) { _, _ in
            segment = .inbox
        }
        .task {
            await activity.loadInitial()
            await projects.load()
        }
        .refreshable {
            HapticBus.refreshStarted()
            switch segment {
            // The inbox is listener-backed: a snapshot is already the newest
            // state, so pull-to-refresh re-arms the listener rather than
            // pretending to fetch.
            case .inbox: inbox.loadIfNeeded()
            case .cockpit: await cockpit.runQuery(reset: true)
            case .sessions, .activity: await activity.refresh()
            case .projects: await projects.refresh()
            }
            HapticBus.refreshFinished()
        }
        .sheet(isPresented: $showFilters) {
            StreamsFilterSheet(store: activity)
                .presentationDetents([.medium])
        }
        .sheet(item: $selectedCloudConversation) { hit in
            CloudConversationDetailSheet(
                hit: hit,
                decryptedBody: cloudConversationBody,
                error: cloudConversationError,
                isLoading: isLoadingCloudConversation,
                onRetry: { Task { await loadCloudConversation(hit) } }
            )
            .task(id: hit.id) {
                await loadCloudConversation(hit)
            }
        }
        .sheet(item: $selectedCockpitRow) { row in
            CockpitConversationDetailSheet(store: cockpit, row: row)
        }
        .sheet(isPresented: $showCockpitFilters) {
            CockpitFilterSheet(store: cockpit)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showCloudStore) {
            NavigationStack {
                CloudStoreView(onClose: { showCloudStore = false })
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert("Save query", isPresented: $showSaveQuery) {
            TextField("Name", text: $saveQueryName)
            Button("Save") {
                cockpit.saveCurrentQuery(named: saveQueryName)
                saveQueryName = ""
            }
            Button("Cancel", role: .cancel) { saveQueryName = "" }
        } message: {
            Text("Recall this provider, model, date, and sort combination from the saved-query rail.")
        }
    }

    private var streamsBackgroundVisibility: MobileBackgroundVisibility {
        isPresentingModal ? MobileBackgroundVisibility.obscured : MobileBackgroundVisibility.prominent
    }

    private var isPresentingModal: Bool {
        showFilters
            || selectedCloudConversation != nil
            || selectedCockpitRow != nil
            || showCockpitFilters
            || showCloudStore
    }

    // MARK: - AI Inbox

    /// The Mac's AI Inbox, mirrored. `AIInboxSplitLayout` resolves one column or
    /// two from the width it is handed, so this is the same expression on an
    /// iPhone, a Slide Over, and a full-width iPad.
    private var inboxSurface: some View {
        AIInboxSplitLayout(store: inbox)
            .padding(.bottom, listBottomPadding)
            // Streams already owns a search field; feeding it through rather
            // than adding a second `.searchable` keeps one search box on screen.
            .onChange(of: searchText, initial: true) { _, query in
                inbox.searchQuery = query
            }
            .task { inbox.loadIfNeeded() }
    }

    /// The compact detail push. Resolved from the live store rather than
    /// captured at push time so an archive or a feedback tap redraws the screen
    /// the user is looking at.
    private func inboxDetail(for route: AIInboxDetailRoute) -> some View {
        AIInboxDetailScreen(store: inbox, itemID: route.itemID)
    }

    // MARK: - Cockpit

    @ViewBuilder
    private var cockpitList: some View {
        ConversationCockpitSection(
            store: cockpit,
            searchText: searchText,
            streamSearchHits: activity.searchHits,
            cloudSearchHits: activity.cloudSearchHits,
            isSearching: activity.isSearching,
            isEntitled: isCloudEntitled,
            bottomPadding: listBottomPadding,
            onSelectRow: { selectedCockpitRow = $0 },
            onSelectCloudHit: selectCloudConversation,
            onOpenFilters: { showCockpitFilters = true },
            onSaveQuery: { showSaveQuery = true },
            onOpenStore: { showCloudStore = true }
        )
    }

    // MARK: - Filtered Data

    private var filteredUsages: [TokenUsage] {
        guard !searchText.isEmpty else { return activity.usages }
        let q = searchText.lowercased()
        return activity.usages.filter {
            $0.model.lowercased().contains(q) ||
            $0.projectName.lowercased().contains(q) ||
            $0.provider.rawValue.lowercased().contains(q) ||
            $0.sessionId.lowercased().contains(q) ||
            ($0.sourceDeviceName?.lowercased().contains(q) ?? false)
        }
    }

    private var filteredRawActivity: [TokenUsage] {
        let source = activity.rawUsages.isEmpty ? activity.usages : activity.rawUsages
        guard !searchText.isEmpty else { return source }
        let q = searchText.lowercased()
        return source.filter {
            $0.model.lowercased().contains(q) ||
            $0.projectName.lowercased().contains(q) ||
            $0.provider.rawValue.lowercased().contains(q) ||
            $0.sessionId.lowercased().contains(q) ||
            ($0.sourceDeviceName?.lowercased().contains(q) ?? false)
        }
    }

    private var filteredProjects: [ProjectSummary] {
        guard !searchText.isEmpty else { return projects.summaries }
        let q = searchText.lowercased()
        return projects.summaries.filter {
            $0.projectName.lowercased().contains(q) ||
            ($0.topModel?.lowercased().contains(q) ?? false)
        }
    }

    // MARK: - Sessions

    private var sessionsList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if activity.isLoading && activity.usages.isEmpty {
                    sessionSkeleton
                } else if searchResultMode == .cloudConversationHits {
                    ForEach(activity.cloudSearchHits) { hit in
                        Button { selectCloudConversation(hit) } label: {
                            CloudConversationSearchResultRow(hit: hit)
                        }
                        .buttonStyle(.plain)
                    }
                } else if searchResultMode == .streamHits {
                    ForEach(activity.searchHits) { hit in
                        NavigationLink(value: hit.usage) {
                            StreamSearchResultRow(hit: hit)
                        }
                        .buttonStyle(.plain)
                    }
                } else if searchResultMode == .searching {
                    ProgressView()
                        .tint(MobileTheme.ember)
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .padding(.vertical, 28)
                } else if let loadError = activity.error, activity.usages.isEmpty {
                    AuroraStatePane(
                        kind: .error,
                        icon: "exclamationmark.icloud.fill",
                        title: activity.searchFailed ? "Search failed" : "Couldn't load streams",
                        message: loadError,
                        ctaLabel: "Try Again",
                        onCTA: { Task { await activity.refresh() } }
                    )
                    .frame(minHeight: 320)
                } else if searchResultMode == .empty || filteredUsages.isEmpty {
                    let hasSearch = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    AuroraStatePane(
                        kind: .empty,
                        icon: hasSearch ? "magnifyingglass" : "doc.text.magnifyingglass",
                        title: hasSearch ? "No matches" : "No sessions yet",
                        message: hasSearch
                            ? "Try a different model, provider, or private transcript search term."
                            : "Sessions will appear here as soon as your Mac syncs."
                    )
                    .frame(minHeight: 320)
                } else {
                    ForEach(groupedByDay, id: \.day) { group in
                        Section {
                            VStack(spacing: 8) {
                                ForEach(group.usages) { usage in
                                    NavigationLink(value: usage) {
                                        AuroraSessionRow(usage: usage)
                                    }
                                    .buttonStyle(.plain)
                                    .onAppear {
                                        if usage.id == activity.usages.last?.id {
                                            Task { await activity.loadNext() }
                                        }
                                    }
                                }
                            }
                        } header: {
                            StreamsDayHeader(date: group.day)
                        }
                    }
                    if activity.isLoading {
                        ProgressView()
                            .padding()
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, AuroraDesign.Layout.cardInset)
            .padding(.bottom, listBottomPadding)
        }
    }

    private var groupedByDay: [(day: Date, usages: [TokenUsage])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredUsages) { calendar.startOfDay(for: ActivityStore.activityDate(for: $0)) }
        return grouped.sorted { $0.key > $1.key }.map { (day: $0.key, usages: $0.value) }
    }

    private var groupedRawActivityByDay: [(day: Date, usages: [TokenUsage])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredRawActivity) { calendar.startOfDay(for: ActivityStore.activityDate(for: $0)) }
        return grouped.sorted { $0.key > $1.key }.map { (day: $0.key, usages: $0.value) }
    }

    /// The search field is shared across segments, so the prompt names what the
    /// current one actually searches.
    private var searchPrompt: String {
        segment == .inbox
            ? "Search the inbox"
            : "Search sessions, models, projects"
    }

    private var listBottomPadding: CGFloat {
        horizontalSizeClass == .compact
            ? Self.iPhoneNavigationTrayClearance
            : MobileTheme.Spacing.xxl
    }

    private var searchResultMode: StreamsSearchResultMode {
        StreamsSearchResultState(
            query: searchText,
            isSearching: activity.isSearching,
            cloudConversationHitCount: activity.cloudSearchHits.count,
            streamHitCount: activity.searchHits.count,
            searchFailed: activity.searchFailed
        ).mode
    }

    private var sessionSkeleton: some View {
        VStack(spacing: 10) {
            ForEach(0..<6, id: \.self) { _ in
                AuroraLoadingShimmer(height: 76, cornerRadius: 14)
            }
        }
    }

    private func selectCloudConversation(_ hit: CloudConversationSearchRow) {
        selectedCloudConversation = hit
        cloudConversationBody = nil
        cloudConversationError = nil
    }

    private func loadCloudConversation(_ hit: CloudConversationSearchRow) async {
        isLoadingCloudConversation = true
        cloudConversationError = nil
        defer { isLoadingCloudConversation = false }
        do {
            cloudConversationBody = try await activity.loadCloudConversationBody(for: hit)
        } catch {
            cloudConversationError = error.localizedDescription
        }
    }

    // MARK: - Projects

    private var projectsList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if projects.isLoading && projects.summaries.isEmpty {
                    sessionSkeleton
                } else if filteredProjects.isEmpty {
                    AuroraStatePane(
                        kind: .empty,
                        icon: "folder.fill.badge.questionmark",
                        title: "No projects yet",
                        message: "Projects are inferred from session metadata. They'll show up here as soon as you start working."
                    )
                    .frame(minHeight: 320)
                } else {
                    ForEach(filteredProjects) { project in
                        NavigationLink {
                            ProjectDetailView(project: project, store: projects)
                        } label: {
                            ProjectCard(project: project)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, AuroraDesign.Layout.cardInset)
            .padding(.bottom, listBottomPadding)
        }
    }

    // MARK: - Activity

    private var activityList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if activity.isLoading && activity.rawUsages.isEmpty && activity.usages.isEmpty {
                    sessionSkeleton
                } else if filteredRawActivity.isEmpty {
                    AuroraStatePane(
                        kind: .empty,
                        icon: "list.bullet.rectangle",
                        title: "No activity",
                        message: "Your usage will populate this timeline."
                    )
                    .frame(minHeight: 280)
                } else {
                    ForEach(groupedRawActivityByDay, id: \.day) { group in
                        Section {
                            VStack(spacing: 8) {
                                ForEach(group.usages) { usage in
                                    NavigationLink(value: usage) {
                                        ActivityCompactRow(usage: usage)
                                    }
                                    .buttonStyle(.plain)
                                    .onAppear {
                                        if usage.id == activity.rawUsages.last?.id {
                                            Task { await activity.loadNext() }
                                        }
                                    }
                                }
                            }
                        } header: {
                            StreamsDayHeader(date: group.day)
                        }
                    }
                }
            }
            .padding(.horizontal, AuroraDesign.Layout.cardInset)
            .padding(.bottom, listBottomPadding)
        }
    }
}
