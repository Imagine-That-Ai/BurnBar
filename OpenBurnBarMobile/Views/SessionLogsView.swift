import SwiftUI
import OpenBurnBarCore

// MARK: - Session Logs View

struct SessionLogsView: View {
    @State private var store = ActivityStore()
    @State private var searchText = ""
    @State private var selectedUsage: TokenUsage?
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
                if store.isLoading && store.usages.isEmpty {
                    Section {
                        ForEach(0..<5, id: \.self) { _ in
                            EmberSkeleton(height: 72, cornerRadius: MobileTheme.Radius.md)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                } else if store.usages.isEmpty {
                    Section {
                        EmptyStateView(
                            icon: "doc.text.magnifyingglass",
                            title: "No Sessions",
                            message: "Your conversation history will appear here once data is synced from your Mac."
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } else if filteredUsages.isEmpty && !searchText.isEmpty {
                    Section {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "No Results",
                            message: "Try a different search term — you can search by model, project, provider, session ID, cost, or device name."
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } else {
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
                    if store.isLoading {
                        MiningPickLoader(.inline)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(EmberSurfaceBackground().ignoresSafeArea())
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
            .sheet(isPresented: $showFilters) {
                SessionLogFilterSheet(store: store)
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
                .background(EmberSurfaceBackground().ignoresSafeArea())
            }
        }
        .navigationSplitViewStyle(.balanced)
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
