import SwiftUI

struct SessionDetailView: View {
    let session: TokenUsage
    let theme: ProviderTheme
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                Image(systemName: session.provider.iconName)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(theme.primaryColor)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.projectName)
                        .font(ThemeManager.Typography.title)
                        .foregroundStyle(theme.textColor)
                    
                    Text(session.model)
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                }
                
                Spacer()
                
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryTextColor)
            }
            
            Divider()
            
            // Stats Grid
            HStack(spacing: 24) {
                StatCard(
                    title: "Input",
                    value: formatTokens(session.inputTokens),
                    color: theme.chartColors[0]
                )
                
                StatCard(
                    title: "Output",
                    value: formatTokens(session.outputTokens),
                    color: theme.chartColors[1]
                )
                
                StatCard(
                    title: "Cache Read",
                    value: formatTokens(session.cacheReadTokens),
                    color: theme.chartColors[2]
                )
                
                StatCard(
                    title: "Cache Write",
                    value: formatTokens(session.cacheCreationTokens),
                    color: theme.chartColors[3]
                )
            }
            
            Divider()
            
            // Cost & Duration
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Cost")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                    
                    Text(formatCost(session.cost))
                        .font(ThemeManager.Typography.monoDisplay)
                        .foregroundStyle(theme.gradient)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Duration")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                    
                    Text(session.formattedDuration)
                        .font(ThemeManager.Typography.monoBody)
                        .foregroundStyle(theme.textColor)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.lg)
                    .fill(theme.secondaryBackgroundColor)
            )
            
            // Timestamps
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Started:")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                    
                    Text(formatDateTime(session.startTime))
                        .font(ThemeManager.Typography.monoCaption)
                        .foregroundStyle(theme.textColor)
                }
                
                HStack {
                    Text("Ended:")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                    
                    Text(formatDateTime(session.endTime))
                        .font(ThemeManager.Typography.monoCaption)
                        .foregroundStyle(theme.textColor)
                }
            }
            
            Spacer()
        }
        .padding(24)
        .frame(width: 500, height: 400)
        .background(theme.backgroundColor)
    }
    
    // MARK: - Helpers
    
    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        } else {
            return "\(tokens)"
        }
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
    
    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(.secondary)
            
            Text(value)
                .font(ThemeManager.Typography.monoBody)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.md)
                .fill(color.opacity(0.1))
        )
    }
}
