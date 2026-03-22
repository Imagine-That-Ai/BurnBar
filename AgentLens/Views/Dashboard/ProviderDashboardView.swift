import SwiftUI

struct ProviderDashboardView: View {
    let provider: AgentProvider
    let dataStore: DataStore
    let timeRange: TimeRange
    
    @State private var showingSessionDetail = false
    @State private var selectedSession: TokenUsage?
    
    private var theme: ProviderTheme {
        ProviderTheme.theme(for: provider)
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header with close button
                headerView
                
                // Token Breakdown Chart
                TokenBreakdownChart(usages: usages, theme: theme)
                    .padding(.horizontal, 24)
                
                // Daily Trend Chart
                DailyTrendChart(usages: usages, theme: theme)
                    .padding(.horizontal, 24)
                
                // Recent Sessions
                recentSessionsView
            }
            .padding(.bottom, 24)
        }
        .background(theme.backgroundColor)
        .sheet(item: $selectedSession) { session in
            SessionDetailView(session: session, theme: theme)
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            // Provider Icon
            Image(systemName: provider.iconName)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(theme.primaryColor)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.displayName)
                    .font(ThemeManager.Typography.title)
                    .foregroundStyle(theme.textColor)
                
                Text("\(usages.count) sessions")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(theme.secondaryTextColor)
            }
            
            Spacer()
            
            // Total Cost Badge
            VStack(alignment: .trailing, spacing: 4) {
                Text(totalCost)
                    .font(ThemeManager.Typography.monoDisplay)
                    .foregroundStyle(theme.gradient)
                
                Text("total")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(theme.secondaryTextColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.primaryColor.opacity(0.15))
            )
        }
        .padding(.bottom, 16)
    }
    
    // MARK: - Recent Sessions
    
    private var recentSessionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Sessions")
                .font(ThemeManager.Typography.headline)
                .foregroundStyle(theme.textColor)
            
            if usages.isEmpty {
                Text("No sessions recorded")
                    .font(ThemeManager.Typography.body)
                    .foregroundStyle(theme.secondaryTextColor)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(usages.prefix(10)) { usage in
                        SessionRow(usage: usage, theme: theme)
                            .onTapGesture {
                                selectedSession = usage
                                showingSessionDetail = true
                            }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.lg)
                .fill(theme.secondaryBackgroundColor)
        )
    }
    
    // MARK: - Computed Properties
    
    private var usages: [TokenUsage] {
        if let range = timeRange.dateRange() {
            return dataStore.usages(for: provider, in: range)
        } else {
            return dataStore.usages(for: provider)
        }
    }
    
    private var totalCost: String {
        let total = usages.reduce(0) { $0 + $1.cost }
        return formatCost(total)
    }
    
    // MARK: - Helpers
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        } else if cost < 1.0 {
            return String(format: "$%.2f", cost)
        } else {
            return String(format: "$%.2f", cost)
        }
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let usage: TokenUsage
    let theme: ProviderTheme
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(formatTime(usage.startTime))
                    .font(ThemeManager.Typography.monoCaption)
                    .foregroundStyle(theme.primaryColor)
                
                Text(usage.projectName)
                    .font(ThemeManager.Typography.body)
                    .foregroundStyle(theme.textColor)
                    .lineLimit(1)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 4) {
                Text(formatCost(usage.cost))
                    .font(ThemeManager.Typography.monoBody)
                    .foregroundStyle(theme.textColor)
                
                Text(usage.model)
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(theme.secondaryTextColor)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.md)
                .fill(theme.backgroundColor)
        )
        .contentShape(Rectangle())
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        } else if cost < 1.0 {
            return String(format: "$%.2f", cost)
        } else {
            return String(format: "$%.2f", cost)
        }
    }
}

#Preview {
    ProviderDashboardView(
        provider: .factory,
        dataStore: DataStore(),
        timeRange: .today
    )
}
