import SwiftUI
import Charts
import OpenBurnBarCore

// Stream/day/session/search rows, project card, filter sheet, and search-result state.
// Extracted from StreamsView.swift (god-file decomposition) — same module, verbatim.

struct StreamsDayHeader: View {
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

struct AuroraSessionRow: View {
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
                    ProviderAuroraAvatar(provider: providerEnum, size: 40, animated: false, glassInCard: true)
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

struct StreamSearchResultRow: View {
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

struct CloudConversationSearchResultRow: View {
    let hit: CloudConversationSearchRow

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 14, interactive: true, padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if let provider = hit.providerEnum {
                        UnifiedProviderLogoView(provider: provider, size: 22)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "lock.doc")
                            .foregroundStyle(MobileTheme.ember)
                            .accessibilityHidden(true)
                    }
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
                }
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
    }
}

struct CloudConversationDetailSheet: View {
    let hit: CloudConversationSearchRow
    let decryptedBody: String?
    let error: String?
    let isLoading: Bool
    let onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(hit.title.isEmpty ? "Encrypted session" : hit.title, systemImage: "lock.doc")
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        if let provider = hit.provider, !provider.isEmpty {
                            Text(provider)
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                        }
                    }

                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else if let error {
                        AuroraStatePane(
                            kind: .error,
                            icon: "exclamationmark.lock",
                            title: "Could not decrypt",
                            message: error,
                            ctaLabel: "Try Again",
                            onCTA: onRetry
                        )
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

struct ActivityCompactRow: View {
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
                .font(.system(size: 13, weight: .bold))
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

struct ProjectCard: View {
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

struct StreamsFilterSheet: View {
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

enum StreamsSearchResultMode: Equatable {
    case inactive
    case cloudConversationHits
    case streamHits
    case searching
    case failed
    case empty
}

struct StreamsSearchResultState: Equatable {
    let query: String
    let isSearching: Bool
    let cloudConversationHitCount: Int
    let streamHitCount: Int
    var searchFailed: Bool = false

    var mode: StreamsSearchResultMode {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            return .inactive
        }
        // A search that failed is not a search that found nothing. Decide it
        // ahead of the hit counts and ahead of `.empty`, so leftover hits from
        // the previous query — or a full page of cached rows, which keeps the
        // list's load-error branch from ever showing — cannot dress a failed
        // search up as "No matches" and swallow its retry.
        if searchFailed { return .failed }
        if cloudConversationHitCount > 0 { return .cloudConversationHits }
        if streamHitCount > 0 { return .streamHits }
        if isSearching { return .searching }
        return .empty
    }
}
