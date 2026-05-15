import SwiftUI
import OpenBurnBarCore

// MARK: - Streams View
//
// Unified surface for sessions, activity, and projects. A chip rail at the
// top switches between segments; each renders a Aurora-tuned list backed by
// existing stores plus the new ProjectsStore.

struct StreamsView: View {
    @State private var activity = ActivityStore()
    @State private var projects = ProjectsStore()
    @State private var segment: Segment = .sessions
    @State private var searchText = ""
    @State private var showFilters = false
    @State private var selectedCloudConversation: CloudConversationSearchRow?
    @State private var cloudConversationBody: String?
    @State private var cloudConversationError: String?
    @State private var isLoadingCloudConversation = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private static let iPhoneNavigationTrayClearance: CGFloat = 112

    enum Segment: String, CaseIterable, Identifiable, Hashable {
        case sessions, projects, activity
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .sessions: return "doc.text.magnifyingglass"
            case .projects: return "folder.fill.badge.gearshape"
            case .activity: return "list.bullet.rectangle"
            }
        }
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()
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
                    case .sessions: sessionsList
                    case .projects: projectsList
                    case .activity: activityList
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .navigationTitle("Streams")
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
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions, models, projects")
        .task(id: searchText) {
            await activity.updateSearch(query: searchText)
        }
        .task {
            await activity.loadInitial()
            await projects.load()
        }
        .refreshable {
            HapticBus.refreshStarted()
            switch segment {
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
                isLoading: isLoadingCloudConversation
            )
            .task(id: hit.id) {
                await loadCloudConversation(hit)
            }
        }
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
                } else if filteredUsages.isEmpty {
                    AuroraStatePane(
                        kind: .empty,
                        icon: searchText.isEmpty ? "doc.text.magnifyingglass" : "magnifyingglass",
                        title: searchText.isEmpty ? "No sessions yet" : "No matches",
                        message: searchText.isEmpty
                            ? "Sessions will appear here as soon as your Mac syncs."
                            : "Try a different model, provider, project, or enable searchable stream backup on your Mac for full transcript search."
                    )
                    .frame(minHeight: 320)
                } else if shouldShowCloudConversationResults {
                    ForEach(activity.cloudSearchHits) { hit in
                        Button {
                            selectedCloudConversation = hit
                            cloudConversationBody = nil
                            cloudConversationError = nil
                        } label: {
                            CloudConversationSearchResultRow(hit: hit)
                        }
                        .buttonStyle(.plain)
                    }
                } else if shouldShowCloudSearchResults {
                    ForEach(activity.searchHits) { hit in
                        NavigationLink(value: hit.usage) {
                            StreamSearchResultRow(hit: hit)
                        }
                        .buttonStyle(.plain)
                    }
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
                            DayHeader(date: group.day)
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

    private var listBottomPadding: CGFloat {
        horizontalSizeClass == .compact
            ? Self.iPhoneNavigationTrayClearance
            : MobileTheme.Spacing.xxl
    }

    private var shouldShowCloudSearchResults: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !activity.searchHits.isEmpty
    }

    private var shouldShowCloudConversationResults: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !activity.cloudSearchHits.isEmpty
    }

    private var sessionSkeleton: some View {
        VStack(spacing: 10) {
            ForEach(0..<6, id: \.self) { _ in
                AuroraLoadingShimmer(height: 76, cornerRadius: 14)
            }
        }
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
                            DayHeader(date: group.day)
                        }
                    }
                }
            }
            .padding(.horizontal, AuroraDesign.Layout.cardInset)
            .padding(.bottom, listBottomPadding)
        }
    }
}

// MARK: - Day Header

private struct DayHeader: View {
    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(date, format: .dateTime.weekday(.wide).month().day())
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.2)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            MercuryDivider()
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

// MARK: - Aurora Session Row

private struct AuroraSessionRow: View {
    let usage: TokenUsage

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(usage.provider.rawValue)
    }

    private var providerColor: Color {
        providerEnum.map { MobileTheme.Colors.primary(for: $0) } ?? MobileTheme.ember
    }

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 14, interactive: true, padding: 12) {
            HStack(spacing: 12) {
                providerRail
                if let providerEnum {
                    ProviderAuroraAvatar(provider: providerEnum, size: 40, animated: false)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(usage.model)
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(usage.projectName.isEmpty ? (providerEnum?.displayName ?? "Session") : usage.projectName)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .lineLimit(1)
                        Text("·")
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        Text(ActivityStore.activityDate(for: usage), style: .relative)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(usage.cost.formatAsCost())
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .contentTransition(.numericText())
                    Text(usage.totalTokens.formatAsTokens())
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .contentTransition(.numericText())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
    }

    private var providerRail: some View {
        Capsule()
            .fill(providerColor)
            .frame(width: 3, height: 36)
            .shadow(color: providerColor.opacity(0.5), radius: 4)
    }
}

private struct StreamSearchResultRow: View {
    let hit: StreamSearchHit

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 14, interactive: true, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                AuroraSessionRow(usage: hit.usage)
                Text(hit.snippet)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .padding(.leading, 15)
                    .accessibilityLabel("Search match")
            }
        }
    }
}

private struct CloudConversationSearchResultRow: View {
    let hit: CloudConversationSearchRow

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 14, interactive: true, padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.doc")
                        .foregroundStyle(MobileTheme.ember)
                    Text(hit.title.isEmpty ? "Encrypted session" : hit.title)
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int(hit.score * 100))%")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Text(hit.snippet)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if let provider = hit.provider, !provider.isEmpty {
                        Text(provider)
                    }
                    if let project = hit.projectName, !project.isEmpty {
                        Text(project)
                    }
                }
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
    }
}

private struct CloudConversationDetailSheet: View {
    let hit: CloudConversationSearchRow
    let decryptedBody: String?
    let error: String?
    let isLoading: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(hit.title.isEmpty ? "Encrypted session" : hit.title, systemImage: "lock.doc")
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text([hit.provider, hit.projectName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }

                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else if let error {
                        AuroraStatePane(kind: .error, icon: "exclamationmark.lock", title: "Could not decrypt", message: error)
                            .frame(minHeight: 220)
                    } else {
                        Text(decryptedBody ?? hit.snippet)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(AuroraDesign.Layout.cardInset)
            }
            .background(AuroraBackdrop())
            .navigationTitle("Session Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Activity Compact Row

private struct ActivityCompactRow: View {
    let usage: TokenUsage

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(usage.provider.rawValue)
    }

    var body: some View {
        HStack(spacing: 10) {
            if let providerEnum {
                Circle()
                    .fill(MobileTheme.Colors.primary(for: providerEnum))
                    .frame(width: 8, height: 8)
            }
            Text(ActivityStore.activityDate(for: usage), format: .dateTime.hour().minute())
                .font(MobileTheme.Typography.monoTiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .frame(width: 56, alignment: .leading)
            Text(usage.model)
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .lineLimit(1)
            Spacer()
            Text(usage.cost.formatAsCost())
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .contentTransition(.numericText())
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(MobileTheme.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Project Card

private struct ProjectCard: View {
    let project: ProjectSummary

    var providerColor: Color {
        project.dominantProvider.map { MobileTheme.Colors.primary(for: $0) } ?? MobileTheme.ember
    }

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16, interactive: true) {
            HStack(alignment: .top, spacing: 14) {
                folderIcon
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.projectName)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(project.sessions) sessions")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        if let model = project.topModel {
                            Text("·")
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                            Text(model)
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    if !project.dailyTokens.isEmpty {
                        EmberSparkline(values: project.sortedDailyPoints.map(\.value), lineWidth: 1.5, fillOpacity: 0.18)
                            .frame(height: 28)
                            .padding(.top, 4)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(project.totalCost.formatAsCost())
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.bold)
                        .foregroundStyle(providerColor)
                        .contentTransition(.numericText())
                    Text(project.totalTokens.formatAsTokenVolume())
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .contentTransition(.numericText())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
    }

    private var folderIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(providerColor.opacity(0.18))
                .frame(width: 44, height: 44)
            Image(systemName: "folder.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(providerColor)
                .symbolEffect(.bounce, value: project.totalCost)
        }
    }
}

// MARK: - Filter Sheet

private struct StreamsFilterSheet: View {
    let store: ActivityStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Provider", selection: Binding(
                        get: { store.filterProvider },
                        set: { store.filterProvider = $0 }
                    )) {
                        Text("Any").tag(nil as AgentProvider?)
                        ForEach(AgentProvider.allCases) { provider in
                            HStack {
                                ProviderAvatar(provider: provider, mode: .plain, size: 18)
                                Text(provider.displayName)
                            }
                            .tag(provider as AgentProvider?)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section("Date Range") {
                    DatePicker("From", selection: Binding(
                        get: { store.filterStartDate ?? Date() },
                        set: { store.filterStartDate = $0 }
                    ), displayedComponents: .date)
                    DatePicker("To", selection: Binding(
                        get: { store.filterEndDate ?? Date() },
                        set: { store.filterEndDate = $0 }
                    ), displayedComponents: .date)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AuroraBackdrop(density: .subtle).ignoresSafeArea())
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        Task {
                            await store.applyFilters()
                            dismiss()
                        }
                    }
                    .buttonStyle(.aurora(.primary))
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        store.filterProvider = nil
                        store.filterStartDate = nil
                        store.filterEndDate = nil
                        Task {
                            await store.applyFilters()
                            dismiss()
                        }
                    }
                    .foregroundStyle(MobileTheme.warning)
                }
            }
        }
    }
}
