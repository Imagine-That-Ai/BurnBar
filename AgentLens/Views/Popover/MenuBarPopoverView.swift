import SwiftUI

struct MenuBarPopoverView: View {
    @Environment(\.dismiss) private var dismiss
    let dataStore: DataStore
    let onOpenDashboard: () -> Void
    let onOpenSettings: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Today's Summary
            todaySummaryView
                .padding(16)
            
            Divider()
            
            // Provider Breakdown
            providerBreakdownView
                .padding(16)
            
            Divider()
            
            // Actions
            actionButtons
                .padding(12)
        }
        .frame(width: 320)
        .background(ThemeManager.AppColors.darkBackground)
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Image(systemName: "cpu.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ThemeManager.AppColors.coral)
            
            Text("AgentLens")
                .font(ThemeManager.Typography.headline)
                .foregroundStyle(ThemeManager.AppColors.textPrimary)
            
            Spacer()
            
            Text("Today")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.AppColors.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(ThemeManager.AppColors.cardBackground)
    }
    
    // MARK: - Today's Summary
    
    private var todaySummaryView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Total Cost Today
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatCost(dataStore.totalCostToday))
                    .font(ThemeManager.Typography.monoDisplay)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [ThemeManager.AppColors.coral, ThemeManager.AppColors.purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                
                Text("today")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.AppColors.textSecondary)
                
                Spacer()
            }
            
            // Quick Stats
            HStack(spacing: 16) {
                QuickStat(
                    label: "This Week",
                    value: formatCost(dataStore.totalCostThisWeek)
                )
                
                QuickStat(
                    label: "This Month",
                    value: formatCost(dataStore.totalCostThisMonth)
                )
            }
            
            // Top Provider Today
            if let topProvider = dataStore.topProviderToday() {
                HStack(spacing: 8) {
                    Image(systemName: topProvider.provider.iconName)
                        .font(.system(size: 12))
                        .foregroundStyle(ProviderTheme.theme(for: topProvider.provider).primaryColor)
                    
                    Text("Top: \(topProvider.provider.displayName)")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.AppColors.textSecondary)
                    
                    Spacer()
                    
                    Text(formatCost(topProvider.cost))
                        .font(ThemeManager.Typography.monoCaption)
                        .foregroundStyle(ThemeManager.AppColors.textPrimary)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ProviderTheme.theme(for: topProvider.provider).primaryColor.opacity(0.1))
                )
            }
        }
    }
    
    // MARK: - Provider Breakdown
    
    private var providerBreakdownView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Providers Today")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.AppColors.textSecondary)
            
            let summaries = dataStore.providerSummaries.filter { summary in
                Calendar.current.isDateInToday(
                    dataStore.usages(for: summary.provider).first?.startTime ?? .distantPast
                )
            }
            
            if summaries.isEmpty {
                Text("No activity today")
                    .font(ThemeManager.Typography.body)
                    .foregroundStyle(ThemeManager.AppColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(summaries.prefix(4)) { summary in
                    ProviderRow(
                        summary: summary,
                        theme: ProviderTheme.theme(for: summary.provider)
                    )
                }
            }
        }
    }
    
    // MARK: - Action Buttons
    
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
                onOpenDashboard()
            } label: {
                Label("Dashboard", systemImage: "chart.bar.fill")
                    .font(ThemeManager.Typography.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(ThemeManager.AppColors.purple)
            
            Button {
                dismiss()
                onOpenSettings()
            } label: {
                Label("Settings", systemImage: "gearshape.fill")
                    .font(ThemeManager.Typography.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(ThemeManager.AppColors.border)
        }
    }
    
    // MARK: - Helpers
    
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

// MARK: - Quick Stat

private struct QuickStat: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.AppColors.textSecondary)
            
            Text(value)
                .font(ThemeManager.Typography.monoCaption)
                .foregroundStyle(ThemeManager.AppColors.textPrimary)
        }
    }
}

// MARK: - Provider Row

private struct ProviderRow: View {
    let summary: ProviderSummary
    let theme: ProviderTheme
    
    var body: some View {
        HStack(spacing: 10) {
            // Provider Icon
            Image(systemName: summary.provider.iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.primaryColor)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.primaryColor.opacity(0.15))
                )
            
            // Provider Name & Session Count
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.provider.displayName)
                    .font(ThemeManager.Typography.body)
                    .foregroundStyle(ThemeManager.AppColors.textPrimary)
                
                Text("\(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s")")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.AppColors.textSecondary)
            }
            
            Spacer()
            
            // Cost
            Text(summary.formattedCost)
                .font(ThemeManager.Typography.monoBody)
                .foregroundStyle(theme.primaryColor)
        }
    }
}

#Preview {
    MenuBarPopoverView(
        dataStore: DataStore(),
        onOpenDashboard: {},
        onOpenSettings: {}
    )
}
