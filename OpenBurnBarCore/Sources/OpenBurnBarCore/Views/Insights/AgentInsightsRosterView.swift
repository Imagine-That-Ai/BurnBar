import SwiftUI

/// Roster landing — the screen the Insights tab opens onto.
///
/// Groups every agent in `AgentProvider.allCases` by capability tier so
/// the user can pick which agent's Insights to look at. Each row shows
/// the provider logo, display name, current status, and last-seen
/// summary. Identical layout across iPhone, iPad, macOS.
public struct AgentInsightsRosterView: View {
    public let providers: [AgentProvider]
    public let statusProvider: (AgentProvider) -> AgentInsightsHeader.Status
    public let lastSeenProvider: (AgentProvider) -> Date?
    public let onSelectProvider: (AgentProvider) -> Void
    public var onSelectAggregate: (() -> Void)?

    public init(
        providers: [AgentProvider] = AgentProvider.allCases,
        statusProvider: @escaping (AgentProvider) -> AgentInsightsHeader.Status = { _ in .unconfigured },
        lastSeenProvider: @escaping (AgentProvider) -> Date? = { _ in nil },
        onSelectProvider: @escaping (AgentProvider) -> Void,
        onSelectAggregate: (() -> Void)? = nil
    ) {
        self.providers = providers
        self.statusProvider = statusProvider
        self.lastSeenProvider = lastSeenProvider
        self.onSelectProvider = onSelectProvider
        self.onSelectAggregate = onSelectAggregate
    }

    public var body: some View {
        let groups = groupProviders(providers)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                if onSelectAggregate != nil {
                    aggregateRow
                }
                ForEach(groups, id: \.label) { group in
                    section(group: group)
                }
            }
            .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
            .padding(.vertical, UnifiedDesignSystem.Spacing.lg)
        }
        .background(UnifiedDesignSystem.Colors.background)
    }

    private var aggregateRow: some View {
        Button {
            onSelectAggregate?()
        } label: {
            HStack(spacing: UnifiedDesignSystem.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(UnifiedDesignSystem.Colors.ember.opacity(0.15))
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("All agents")
                        .font(UnifiedDesignSystem.Typography.headline)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    Text("Combined view across every provider")
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(UnifiedDesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                    .fill(UnifiedDesignSystem.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                            .strokeBorder(UnifiedDesignSystem.Colors.ember.opacity(0.2), lineWidth: 0.75)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("All agents aggregate Insights")
    }

    private func section(group: ProviderGroup) -> some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: group.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                Text(group.label)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                Spacer(minLength: 0)
                Text("\(group.providers.count)")
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
            VStack(spacing: 0) {
                ForEach(Array(group.providers.enumerated()), id: \.element.id) { idx, provider in
                    AgentInsightsRosterRow(
                        provider: provider,
                        status: statusProvider(provider),
                        lastSeen: lastSeenProvider(provider),
                        showDivider: idx < group.providers.count - 1,
                        onTap: { onSelectProvider(provider) }
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                    .fill(UnifiedDesignSystem.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                    .strokeBorder(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
    }

    // MARK: - Grouping

    private struct ProviderGroup {
        let label: String
        let symbolName: String
        let providers: [AgentProvider]
    }

    private func groupProviders(_ providers: [AgentProvider]) -> [ProviderGroup] {
        var quotaSignal: [AgentProvider] = []
        var mobileConnectable: [AgentProvider] = []
        var local: [AgentProvider] = []
        var other: [AgentProvider] = []

        for provider in providers {
            if AgentProvider.mobileAccountConnectableProviders.contains(provider) {
                mobileConnectable.append(provider)
            } else if AgentProvider.quotaSignalProviders.contains(provider) {
                quotaSignal.append(provider)
            } else if provider == .ollama || provider == .hermes || provider == .piAgent {
                local.append(provider)
            } else {
                other.append(provider)
            }
        }

        var groups: [ProviderGroup] = []
        if !mobileConnectable.isEmpty {
            groups.append(.init(label: "Connect on mobile", symbolName: "iphone.radiowaves.left.and.right",
                                providers: mobileConnectable))
        }
        if !quotaSignal.isEmpty {
            groups.append(.init(label: "Quota-aware", symbolName: "gauge.with.dots.needle.67percent",
                                providers: quotaSignal))
        }
        if !local.isEmpty {
            groups.append(.init(label: "Local & on-device", symbolName: "lock.shield",
                                providers: local))
        }
        if !other.isEmpty {
            groups.append(.init(label: "Other agents", symbolName: "ellipsis.circle",
                                providers: other))
        }
        return groups
    }
}

private struct AgentInsightsRosterRow: View {
    let provider: AgentProvider
    let status: AgentInsightsHeader.Status
    let lastSeen: Date?
    let showDivider: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(spacing: UnifiedDesignSystem.Spacing.md) {
                    UnifiedProviderLogoView(provider: provider, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.displayName)
                            .font(UnifiedDesignSystem.Typography.body)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        Text(subtitle)
                            .font(UnifiedDesignSystem.Typography.tiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    statusDot
                    Image(systemName: "chevron.right")
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
                .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
                if showDivider {
                    Rectangle()
                        .fill(UnifiedDesignSystem.Colors.borderSubtle)
                        .frame(height: 0.5)
                        .padding(.leading, 60)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(provider.displayName), \(status.displayLabel). \(subtitle)")
    }

    private var subtitle: String {
        if let lastSeen {
            return "Last seen \(lastSeen.formatted(.relative(presentation: .named)))"
        }
        return status.displayLabel
    }

    private var statusDot: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }

    private var color: Color {
        switch status {
        case .active: return UnifiedDesignSystem.Colors.success
        case .idle: return UnifiedDesignSystem.Colors.amber
        case .dormant: return UnifiedDesignSystem.Colors.textMuted
        case .unconfigured: return UnifiedDesignSystem.Colors.textMuted
        }
    }
}
