import SwiftUI
import OpenBurnBarCore

// MARK: - Session Logs View

struct SessionLogsView: View {
    @State private var store = ActivityStore()
    @State private var searchText = ""
    @State private var selectedUsage: TokenUsage?
    @State private var selectedCloudConversation: CloudConversationSearchRow?
    @State private var cloudConversationBody: String?
    @State private var cloudConversationError: String?
    @State private var isLoadingCloudConversation = false
    @State private var showFilters = false

    var filteredUsages: [TokenUsage] {
        guard !searchText.isEmpty else { return store.usages }
        let lower = searchText.lowercased()
        return store.usages.filter {
            $0.model.lowercased().contains(lower) ||
            $0.projectName.lowercased().contains(lower) ||
            $0.provider.rawValue.lowercased().contains(lower) ||
            $0.sessionId.lowercased().contains(lower) ||
            String(format: "%.4f", $0.cost).contains(lower) ||
            $0.sourceDeviceName?.lowercased().contains(lower) ?? false
        }
    }

    var body: some View {
        NavigationSplitView {
            // MARK: List Pane
            List(selection: Binding(
                get: { selectedUsage },
                set: { selectedUsage = $0 }
            )) {
                let hasCloudHits = !store.cloudSearchHits.isEmpty
                let hasPrivateSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2

                if store.isLoading && store.usages.isEmpty && !hasCloudHits {
                    Section {
                        ForEach(0..<5, id: \.self) { _ in
                            EmberSkeleton(height: 72, cornerRadius: MobileTheme.Radius.md)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                } else if store.usages.isEmpty && !store.isSearching {
                    Section {
                        EmptyStateView(
                            icon: "doc.text.magnifyingglass",
                            title: "No Sessions",
                            message: "Your conversation history will appear here once data is synced from your Mac."
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } else if filteredUsages.isEmpty && !searchText.isEmpty && !hasCloudHits && !store.isSearching {
                    Section {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "No Results",
                            message: "Try a different model, provider, session ID, device, or private transcript search term."
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } else {
                    if hasCloudHits {
                        Section("Encrypted transcript matches") {
                            ForEach(store.cloudSearchHits) { hit in
                                Button { selectCloudConversation(hit) } label: {
                                    CloudConversationSearchResultRow(hit: hit)
                                }
                                .buttonStyle(.plain)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                        }
                    }

                    if !filteredUsages.isEmpty {
                        Section {
                            ForEach(filteredUsages) { usage in
                                NavigationLink(value: usage) {
                                    UsageRow(usage: usage)
                                }
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .onAppear {
                                    if usage.id == store.usages.last?.id {
                                        Task { await store.loadNext() }
                                    }
                                }
                            }
                        } header: {
                            if hasCloudHits {
                                Text("Usage rows")
                            }
                        }
                    }

                    if store.isSearching && hasPrivateSearch {
                        ProgressView()
                            .tint(MobileTheme.ember)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else if store.isLoading {
                        MiningPickLoader(.inline)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(VisibilityAwareEmberSurfaceBackground().ignoresSafeArea())
            .navigationTitle("Session Logs")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .refreshable { await store.loadInitial() }
            .task { await store.loadInitial() }
            .task(id: searchText) {
                await store.updateSearch(query: searchText)
            }
            .sheet(isPresented: $showFilters) {
                SessionLogFilterSheet(store: store)
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
        } detail: {
            // MARK: Detail Pane
            if let selected = selectedUsage {
                SessionDetailView(usage: selected)
            } else {
                EmptyStateView(
                    icon: "arrow.left",
                    title: "Select a Session",
                    message: "Tap a session from the list to view details."
                )
                .background(VisibilityAwareEmberSurfaceBackground().ignoresSafeArea())
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func selectCloudConversation(_ hit: CloudConversationSearchRow) {
        cloudConversationBody = nil
        cloudConversationError = nil
        isLoadingCloudConversation = true
        selectedCloudConversation = hit
    }

    private func loadCloudConversation(_ hit: CloudConversationSearchRow) async {
        guard selectedCloudConversation?.id == hit.id else { return }
        cloudConversationBody = nil
        cloudConversationError = nil
        isLoadingCloudConversation = true
        defer { isLoadingCloudConversation = false }
        do {
            cloudConversationBody = try await store.loadCloudConversationBody(for: hit)
        } catch {
            cloudConversationError = error.localizedDescription
        }
    }
}

// MARK: - Filter Sheet

private struct SessionLogFilterSheet: View {
    let store: ActivityStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Provider", selection: .init(
                    get: { store.filterProvider },
                    set: { store.filterProvider = $0 }
                )) {
                    Text("Any").tag(nil as AgentProvider?)
                    ForEach(AgentProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider as AgentProvider?)
                    }
                }
                DatePicker("From", selection: .init(
                    get: { store.filterStartDate ?? Date() },
                    set: { store.filterStartDate = $0 }
                ), displayedComponents: .date)
                DatePicker("To", selection: .init(
                    get: { store.filterEndDate ?? Date() },
                    set: { store.filterEndDate = $0 }
                ), displayedComponents: .date)
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        Task {
                            await store.applyFilters()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
