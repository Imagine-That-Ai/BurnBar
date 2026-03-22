import SwiftUI
import Charts

struct DashboardView: View {
    @Bindable var dataStore: DataStore
    @State private var selectedProvider: AgentProvider?
    @State private var selectedTimeRange: TimeRange = .today
    @State private var showingSettings = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header with time Range Selector
                headerView
                
                // Provider Tabs
                providerTabsView
                
                // Content
                contentView
            }
            .frame(minWidth: 900, minHeight: 600)
            .background(ThemeManager.AppColors.darkBackground)
            .sheet(isPresented: $showingSettings) {
                SettingsView(settingsManager: SettingsManager.shared)
            }
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 20) {
            // Title & Total
            VStack(alignment: .leading, spacing: 4) {
                Text("AgentLens")
                    .font(ThemeManager.Typography.display)
                    .foregroundStyle(ThemeManager.AppGradients.primary)
                
                Text("Token Usage Dashboard")
                    .font(ThemeManager.Typography.body)
                    .foregroundStyle(ThemeManager.AppColors.textSecondary)
            }
            
            Spacer()
            
            // Time Range Picker
            Picker("Time Range", selection: $selectedTimeRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.displayName).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            
            // Total Cost Display
            VStack(alignment: .trailing, spacing: 4) {
                Text(formatCost(totalCostForTimeRange))
                    .font(ThemeManager.Typography.monoDisplay)
                    .foregroundStyle(ThemeManager.AppGradients.primary)
                
                Text(selectedTimeRange.displayName)
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.AppColors.textSecondary)
            }
            .frame(width: 160)
            
            // Settings Button
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ThemeManager.AppColors.textSecondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(ThemeManager.AppColors.cardBackground)
    }
    
    // MARK: - Provider Tabs
    
    private var providerTabsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // All Providers Tab
                ProviderTab(
                    provider: nil,
                    isSelected: selectedProvider == nil,
                    totalCost: dataStore.totalCostToday
                ) {
                    selectedProvider = nil
                }
                
                // Individual Provider Tabs
                ForEach(dataStore.providerSummaries) { summary in
                    ProviderTab(
                        provider: summary.provider,
                        isSelected: selectedProvider == summary.provider,
                        totalCost: summary.totalCost
                    ) {
                        selectedProvider = summary.provider
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(ThemeManager.AppColors.darkBackground)
    }
    
    // MARK: - Content
    
    @ViewBuilder
    private var contentView: some View {
        if let provider = selectedProvider {
            ProviderDashboardView(
                provider: provider,
                dataStore: dataStore,
                timeRange: selectedTimeRange
            )
        } else {
            allProvidersView
        }
    }
    
    private var allProvidersView: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16)
            ], spacing: 16) {
                ForEach(dataStore.providerSummaries) { summary in
                    ProviderCard(
                        summary: summary,
                        theme: ProviderTheme.theme(for: summary.provider)
                    )
                    .onTapGesture {
                        selectedProvider = summary.provider
                    }
                }
            }
            .padding(16)
        }
    }
    
    // MARK: - Computed Properties
    
    private var totalCostForTimeRange: Double {
        guard let range = selectedTimeRange.dateRange() else {
            return dataStore.totalCostAllTime
        }
        
        return dataStore.usages
            .filter { range.contains($0.startTime) }
            .reduce(0) { $0 + $1.cost }
    }
    
    // MARK: - Helpers
    
    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        } else if cost < 1.0 {
            return String(format: "$%.3f", cost)
        } else {
            return String(format: "$%.2f", cost)
        }
    }
}

// MARK: - Provider Tab

private struct ProviderTab: View {
    let provider: AgentProvider?
    let isSelected: Bool
    let totalCost: Double
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let provider = provider {
                    Image(systemName: provider.iconName)
                        .font(.system(size: 14, weight: .medium))
                    
                    Text(provider.displayName)
                        .font(ThemeManager.Typography.body)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 14, weight: .medium))
                    
                    Text("All")
                        .font(ThemeManager.Typography.body)
                }
                
                Text(formatCost(totalCost))
                    .font(ThemeManager.Typography.monoCaption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? theme.primaryColor.opacity(0.2) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? theme.primaryColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var theme: ProviderTheme {
        provider.map { ProviderTheme.theme(for: $0) } ?? ProviderTheme.theme(for: .factory)
    }
    
    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        } else {
            return String(format: "$%.2f", cost)
        }
    }
}

// MARK: - Provider Card

private struct ProviderCard: View {
    let summary: ProviderSummary
    let theme: ProviderTheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: summary.provider.iconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.primaryColor)
                
                Text(summary.provider.displayName)
                    .font(ThemeManager.Typography.headline)
                    .foregroundStyle(theme.textColor)
                
                Spacer()
            }
            
            // Cost
            Text(summary.formattedCost)
                .font(ThemeManager.Typography.monoDisplay)
                .foregroundStyle(theme.gradient)
            
            // Stats Grid
            HStack(spacing: 16) {
                StatItem(
                    label: "Sessions",
                    value: "\(summary.sessionCount)"
                )
                
                StatItem(
                    label: "Input",
                    value: formatTokens(summary.totalInputTokens)
                )
                
                StatItem(
                    label: "Output",
                    value: formatTokens(summary.totalOutputTokens)
                )
            }
            
            // Model Breakdown (mini chart)
            if !summary.modelBreakdown.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Models")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                    
                    HStack(spacing: 4) {
                        ForEach(Array(summary.modelBreakdown.prefix(4).enumerated()), id: \.element.id) { index, model in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(theme.chartColors[index % theme.chartColors.count])
                                .frame(width: max(8, CGFloat(model.percentage) * 0.6))
                                .frame(height: 20)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.lg)
                .fill(theme.secondaryBackgroundColor)
                .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.lg)
                .stroke(theme.primaryColor.opacity(0.2), lineWidth: 1)
        )
    }
    
    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        } else {
            return "\(tokens)"
        }
    }
}

// MARK: - Stat Item

private struct StatItem: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(.secondary)
            
            Text(value)
                .font(ThemeManager.Typography.monoCaption)
        }
    }
}

#Preview {
    DashboardView(dataStore: DataStore())
}
