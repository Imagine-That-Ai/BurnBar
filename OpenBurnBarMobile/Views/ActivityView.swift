import SwiftUI
import OpenBurnBarCore

struct ActivityView: View {
    @State private var store = ActivityStore()
    @State private var showFilters = false

    var body: some View {
        List {
            if store.usages.isEmpty && store.isLoading {
                loadingSection
            } else if store.usages.isEmpty {
                EmptyStateView(
                    icon: "list.bullet.rectangle",
                    title: "No Activity",
                    message: "Your usage history will appear here once data is synced."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(store.usages) { usage in
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
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .background(MobileTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Activity")
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
            FilterSheet(store: store)
        }
        .navigationDestination(for: TokenUsage.self) { usage in
            SessionDetailView(usage: usage)
        }
    }

    private var loadingSection: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            SkeletonView(height: 72, cornerRadius: MobileTheme.Radius.md)
            SkeletonView(height: 72, cornerRadius: MobileTheme.Radius.md)
            SkeletonView(height: 72, cornerRadius: MobileTheme.Radius.md)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

// MARK: - Usage Row

struct UsageRow: View {
    let usage: TokenUsage

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(usage.provider.rawValue)
    }

    var body: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            if let providerEnum {
                ProviderBadge(provider: providerEnum, size: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(usage.model)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(providerEnum?.displayName ?? usage.provider.rawValue)
                        .font(MobileTheme.Typography.footnote)
                    Text("·")
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    Text(usage.startTime, style: .date)
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(usage.cost.formatAsCost())
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(usage.totalTokens.formatAsTokens())
                    .font(MobileTheme.Typography.footnote)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(MobileTheme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
        )
    }
}

// MARK: - Filter Sheet

private struct FilterSheet: View {
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

#Preview {
    NavigationStack {
        ActivityView()
    }
}
