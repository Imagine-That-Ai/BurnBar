import SwiftUI

// MARK: - Database Workspace View

// Atlas mode view.
// Extracted from DatabaseWorkspaceView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension DatabaseWorkspaceView {

    @ViewBuilder
    var atlasContent: some View {
        if !snapshot.indexingEnabled && snapshot.indexedDocuments == 0 {
            indexingDisabledState
        } else {
            if snapshot.loadIssues.isEmpty == false {
                partialDataBand
            }
            atlasCompactToolbar
            if showAtlasCostMix {
                atlasProviderChartBand
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            atlasDenseTable
        }
    }

    /// Compact inline toolbar replacing the old full-width filter band.
    /// Filters + summary on one line, cost mix toggle on the right.
    var atlasCompactToolbar: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                atlasFilterMenu(
                    title: "Provider",
                    value: filter.providerFilter?.displayName ?? "All"
                ) {
                    Button("All Providers") { filter.providerFilter = nil }
                    ForEach(snapshot.activeProviders, id: \.self) { provider in
                        Button {
                            filter.providerFilter = provider
                        } label: {
                            HStack {
                                ProviderLogoView(provider: provider, size: 16, useFallbackColor: true)
                                Text(provider.displayName)
                            }
                        }
                    }
                }

                atlasFilterMenu(
                    title: "Source",
                    value: filter.sourceKindFilter?.databaseDisplayName ?? "All"
                ) {
                    Button("All Sources") { filter.sourceKindFilter = nil }
                    ForEach(SearchSourceKind.allCases, id: \.self) { sourceKind in
                        Button(sourceKind.databaseDisplayName) { filter.sourceKindFilter = sourceKind }
                    }
                }

                atlasFilterMenu(
                    title: "Project",
                    value: filter.projectFilter ?? "All"
                ) {
                    Button("All Projects") { filter.projectFilter = nil }
                    ForEach(snapshot.projectNames, id: \.self) { projectName in
                        Button(projectName) { filter.projectFilter = projectName }
                    }
                }

                atlasFilterMenu(
                    title: "Window",
                    value: filter.timeWindow.displayName
                ) {
                    ForEach(TimeRange.allCases) { timeRange in
                        Button(timeRange.displayName) { filter.timeWindow = timeRange }
                    }
                }

                Spacer()

                if hasActiveFilters {
                    Button("Reset") {
                        filter = DatabaseWorkspaceFilterState()
                    }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Button {
                    withAnimation(DesignSystem.Animation.standard) {
                        showAtlasCostMix.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 10))
                        Text("Cost Mix")
                            .font(DesignSystem.Typography.tiny)
                    }
                    .foregroundStyle(showAtlasCostMix ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(
                        Capsule().fill(showAtlasCostMix ? DesignSystem.Colors.surfaceElevated : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                Text(atlasSummaryText)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                if let atlasAggregateSummary {
                    Text(atlasAggregateSummary)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }

                if atlasLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.3))
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    // atlasFilterBand replaced by atlasCompactToolbar above
    var atlasProviderChartBand: some View {
        WideBand(title: "Cost Mix") {
            HStack(spacing: DesignSystem.Spacing.md) {
                ForEach(snapshot.providerSummaries.prefix(6)) { summary in
                    Button {
                        withAnimation(DesignSystem.Animation.standard) {
                            selection = .provider(summary.provider)
                        }
                    } label: {
                        VStack(spacing: DesignSystem.Spacing.xs) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(DesignSystem.Colors.primary(for: summary.provider))
                                .frame(
                                    width: 28,
                                    height: max(8, CGFloat(snapshot.totalCostAllTime > 0
                                        ? summary.totalCost / snapshot.totalCostAllTime * 80
                                        : 4))
                                )

                            Text(summary.provider.displayName)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .lineLimit(1)

                            Text(summary.totalCost.formatAsCost())
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
        }
    }

    var atlasDenseTable: some View {
        WideBand(title: filter.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Indexed Corpus" : "Search Results") {
            VStack(spacing: 0) {
                if let atlasError {
                    emptyLabel(atlasError)
                } else if atlasRows.isEmpty, atlasLoading {
                    emptyLabel("Loading indexed corpus...")
                } else if atlasRows.isEmpty {
                    emptyLabel("No indexed records match the current query and filters.")
                } else {
                    HStack(spacing: 0) {
                        tableHeader("Source", width: 96)
                        tableHeader("Title", width: nil)
                        tableHeader("Provider", width: 110)
                        tableHeader("Project", width: 120)
                        tableHeader("Updated", width: 140)
                    }
                    .padding(.bottom, DesignSystem.Spacing.xs)

                    Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)

                    ForEach(atlasRows.prefix(80)) { row in
                        Button {
                            withAnimation(DesignSystem.Animation.standard) {
                                selection = row.selection
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                HStack(spacing: 0) {
                                    Text(row.sourceKind.databaseDisplayName)
                                        .frame(width: 96, alignment: .leading)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.title)
                                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                                            .lineLimit(1)

                                        if row.preview.isEmpty == false {
                                            Text(row.preview)
                                                .font(DesignSystem.Typography.tiny)
                                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                                .lineLimit(2)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(row.providerLabel)
                                        .frame(width: 110, alignment: .leading)

                                    Text(row.projectName ?? "—")
                                        .frame(width: 120, alignment: .leading)

                                    Text(row.displayDate.formatted(date: .abbreviated, time: .shortened))
                                        .frame(width: 140, alignment: .trailing)
                                }
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)

                                if row.subtitle?.isEmpty == false {
                                    Text(row.subtitle ?? "")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                        .lineLimit(1)
                                        .padding(.leading, 96)
                                }
                            }
                            .padding(.vertical, DesignSystem.Spacing.sm)
                            .background(
                                selection == row.selection
                                    ? DesignSystem.Colors.surfaceElevated.opacity(0.5)
                                    : Color.clear
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider().foregroundStyle(DesignSystem.Colors.borderSubtle.opacity(0.5))
                    }

                    if atlasRows.count > 80 {
                        Text("\(atlasRows.count - 80) more indexed records...")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .padding(.top, DesignSystem.Spacing.sm)
                    }
                }
            }
        }
    }
}
