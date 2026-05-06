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
                ForEach(groupedByDay, id: \.day) { group in
                    Section {
                        ForEach(group.usages) { usage in
                            NavigationLink(value: usage) {
                                UsageRow(usage: usage)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                            .onAppear {
                                if usage.id == store.usages.last?.id {
                                    Task { await store.loadNext() }
                                }
                            }
                        }
                    } header: {
                        DayHeader(date: group.day)
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
        .background(emberBackground.ignoresSafeArea())
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilters = true } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .refreshable {
            Haptics.success()
            await store.loadInitial()
        }
        .task { await store.loadInitial() }
        .sheet(isPresented: $showFilters) {
            FilterSheet(store: store)
        }
        .navigationDestination(for: TokenUsage.self) { usage in
            SessionDetailView(usage: usage)
        }
    }

    private var emberBackground: some View {
        EmberSurfaceBackground()
    }

    // MARK: - Grouping

    private var groupedByDay: [(day: Date, usages: [TokenUsage])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: store.usages) { usage in
            calendar.startOfDay(for: usage.startTime)
        }
        return grouped.sorted { $0.key > $1.key }.map { (day: $0.key, usages: $0.value) }
    }

    // MARK: - Loading

    private var loadingSection: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            EmberSkeleton(height: 72, cornerRadius: MobileTheme.Radius.md)
            EmberSkeleton(height: 72, cornerRadius: MobileTheme.Radius.md)
            EmberSkeleton(height: 72, cornerRadius: MobileTheme.Radius.md)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

// MARK: - Day Header

private struct DayHeader: View {
    let date: Date

    var body: some View {
        HStack {
            Text(date, style: .date)
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .background(
            EmberSurfaceBackground()
                .opacity(0.5)
        )
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
            // Provider-colored rail
            if let providerEnum {
                Rectangle()
                    .fill(MobileTheme.Colors.primary(for: providerEnum))
                    .frame(width: 3)
                    .clipShape(Capsule())
            }

            if let providerEnum {
                ProviderAvatar(provider: providerEnum, mode: .tile, size: 40)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(usage.model)
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)

                    // Monospaced size badge
                    Text("\(usage.totalTokens.formatAsTokens())")
                        .font(MobileTheme.Typography.monoTiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(MobileTheme.Colors.surfaceElevated)
                        )
                }

                HStack(spacing: 4) {
                    Text(providerEnum?.displayName ?? usage.provider.rawValue)
                        .font(MobileTheme.Typography.footnote)
                    Text("·")
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    relativeTimeChip
                }
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(usage.cost.formatAsCost())
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .contentTransition(.numericText())
                Text(usage.totalTokens.formatAsTokens())
                    .font(MobileTheme.Typography.footnote)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            UnifiedGlassCard {
                EmptyView()
            }
            .padding(-MobileTheme.Spacing.md)
        )
    }

    private var relativeTimeChip: some View {
        Text(usage.startTime, style: .relative)
            .font(MobileTheme.Typography.footnote)
            .foregroundStyle(MobileTheme.Colors.textMuted)
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
                        HStack {
                            ProviderAvatar(provider: provider, mode: .plain, size: 20)
                            Text(provider.displayName)
                        }
                        .tag(provider as AgentProvider?)
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
