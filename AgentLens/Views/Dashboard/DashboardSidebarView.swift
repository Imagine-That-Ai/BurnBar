import AppKit
import OpenBurnBarCore
import SwiftUI

// MARK: - Sidebar

extension DashboardView {

    var sidebarSections: [DashboardSidebarSection] {
        DashboardSidebarSection.ordered(from: sidebarSectionOrderRaw)
    }

    var sidebarSectionState: [String: DashboardSidebarSectionState] {
        DashboardSidebarSectionState.decode(sidebarSectionStateRaw)
    }

    var visibleSidebarSections: [DashboardSidebarSection] {
        sidebarSections.filter { sidebarSectionState[$0.rawValue]?.isVisible ?? true }
    }

    var topProjectSummaries: [(name: String, cost: Double, tokens: Int, count: Int)] {
        var dict: [String: (cost: Double, tokens: Int, count: Int)] = [:]
        for usage in dashboardUsageWindow.usages {
            let name = usage.projectName.isEmpty ? "Default" : usage.projectName
            let existing = dict[name] ?? (0.0, 0, 0)
            dict[name] = (existing.cost + usage.cost, existing.tokens + usage.totalTokens, existing.count + 1)
        }
        let ranked = dict
            .map { (name: $0.key, cost: $0.value.cost, tokens: $0.value.tokens, count: $0.value.count) }
            .sorted { $0.cost > $1.cost }
        return Array(ranked.prefix(5))
    }

    var recentUsageSessions: [TokenUsage] {
        Array(dashboardUsageWindow.usages.sorted { $0.endTime > $1.endTime }.prefix(5))
    }

    var sidebarView: some View {
        @Bindable var ds = dataStore
        let adaptiveColors = BackdropAdaptiveColors(profile: dashboardActiveReadabilityProfile)

        return ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Command")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(adaptiveColors.muted)
                            .textCase(.uppercase)

                        Text("Workspace")
                            .font(DesignSystem.Typography.title)
                            .foregroundStyle(adaptiveColors.primary)

                        Text("Customizable sidebar for your active agent workspace.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(adaptiveColors.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 4) {
                        Menu {
                            Text("CUSTOMIZE SECTIONS")
                                .font(.system(size: 9.5, weight: .bold))
                            Divider()
                            ForEach(DashboardSidebarSection.allCases) { section in
                                let isVisible = sidebarSectionState[section.rawValue]?.isVisible ?? true
                                Button {
                                    toggleSidebarSectionVisibility(section)
                                } label: {
                                    HStack {
                                        if isVisible {
                                            Image(systemName: "checkmark")
                                        }
                                        Text(section.displayName)
                                    }
                                }
                            }
                            Divider()
                            Button("Reset Sections to Default") {
                                resetSidebarSections()
                            }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(adaptiveColors.secondary)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Customize sidebar sections")
                        .accessibilityLabel("Customize sidebar sections")

                        Button(action: toggleDashboardSidebar) {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(adaptiveColors.secondary)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Hide sidebar")
                        .accessibilityLabel("Hide sidebar")
                    }
                }

                VStack(spacing: DesignSystem.Spacing.md) {
                    ForEach(Array(visibleSidebarSections.enumerated()), id: \.element.id) { index, section in
                        let isCollapsed = sidebarSectionState[section.rawValue]?.collapsed == true
                        sidebarSectionBlock(
                            section: section,
                            isCollapsed: isCollapsed,
                            index: index,
                            totalCount: visibleSidebarSections.count,
                            adaptiveColors: adaptiveColors
                        )
                    }
                }

                if visibleSidebarSections.isEmpty {
                    VStack(spacing: DesignSystem.Spacing.sm) {
                        Text("All sidebar sections hidden")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(adaptiveColors.muted)

                        Button("Reset to Default") {
                            resetSidebarSections()
                        }
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.ember)
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DesignSystem.Spacing.xl)
                }

                // Utility Cards
                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Window")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(adaptiveColors.muted)
                            .textCase(.uppercase)

                        Text(selectedTimeRange.displayName)
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(adaptiveColors.primary)

                        Text("\(activeProviderCount) active providers")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(adaptiveColors.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Cursor")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(adaptiveColors.muted)
                            .textCase(.uppercase)

                        Button(action: openBurnBarCursorExtension) {
                            HStack(spacing: DesignSystem.Spacing.md) {
                                ZStack {
                                    Circle()
                                        .fill(adaptiveColors.primary.opacity(0.08))
                                        .frame(width: 36, height: 36)

                                    ProviderLogoView(provider: .cursor, size: 24, useFallbackColor: false)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add OpenBurnBar to Cursor")
                                        .font(DesignSystem.Typography.body)
                                        .foregroundStyle(adaptiveColors.primary)
                                        .multilineTextAlignment(.leading)

                                    Text("Opens the extension install page")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(adaptiveColors.muted)
                                }

                                Spacer(minLength: 0)

                                Image(systemName: "arrow.up.forward.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(adaptiveColors.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Install OpenBurnBar in Cursor (openburnbar.openburnbar)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                }

                if accountManager.isSignedIn {
                    DeviceBreakdownCard(
                        dataStore: dataStore,
                        isSyncing: cloudSyncService?.isSyncing ?? false
                    )
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background {
            DashboardSidebarMaterial(
                liveBackdropActive: dashboardLiveBackdropActive,
                moodBand: dataStore.moodBand,
                kernelColorScheme: dashboardKernelColorScheme
            )
        }
        .scrollContentBackground(.hidden)
        .onMoveCommand { direction in
            let order = sidebarRouteOrder
            guard let idx = order.firstIndex(of: mainRoute) else { return }
            switch direction {
            case .up, .left:
                if idx > 0 { navigate(to: order[idx - 1]) }
            case .down, .right:
                if idx + 1 < order.count { navigate(to: order[idx + 1]) }
            default:
                break
            }
        }
        .onKeyPress(.escape) {
            withAnimation(DesignSystem.Animation.standard) {
                goBack()
            }
            return .handled
        }
        .onAppear { sidebarAppeared = true }
    }

    // MARK: - Section Blocks

    @ViewBuilder
    private func sidebarSectionBlock(
        section: DashboardSidebarSection,
        isCollapsed: Bool,
        index: Int,
        totalCount: Int,
        adaptiveColors: BackdropAdaptiveColors
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            sidebarSectionHeader(
                section: section,
                isCollapsed: isCollapsed,
                index: index,
                totalCount: totalCount,
                adaptiveColors: adaptiveColors
            )

            if !isCollapsed {
                sidebarSectionContent(section: section, adaptiveColors: adaptiveColors)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func sidebarSectionHeader(
        section: DashboardSidebarSection,
        isCollapsed: Bool,
        index: Int,
        totalCount: Int,
        adaptiveColors: BackdropAdaptiveColors
    ) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Button {
                toggleSidebarSectionCollapsed(section)
            } label: {
                HStack(spacing: DesignSystem.Spacing.xxs) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(adaptiveColors.muted)

                    Image(systemName: section.symbolName)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(adaptiveColors.secondary)

                    Text(section.title)
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .tracking(0.8)
                        .foregroundStyle(adaptiveColors.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Show \(section.accessibilityLabel)" : "Hide \(section.accessibilityLabel)")

            Spacer(minLength: 0)

            if let badge = sectionBadge(section) {
                Text(badge)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(adaptiveColors.muted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(adaptiveColors.primary.opacity(0.06))
                    )
            }

            // Keyboard and VoiceOver reachable reorder menu
            Menu {
                Button("Move \(section.accessibilityLabel) up") {
                    moveSidebarSection(section, by: -1)
                }
                .disabled(index == 0)

                Button("Move \(section.accessibilityLabel) down") {
                    moveSidebarSection(section, by: 1)
                }
                .disabled(index == totalCount - 1)

                Divider()

                Button("Hide \(section.accessibilityLabel)") {
                    toggleSidebarSectionVisibility(section)
                }

                Button("Reset sections") {
                    resetSidebarSections()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(adaptiveColors.muted)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Reorder or configure \(section.displayName)")
            .accessibilityLabel("Configure \(section.displayName)")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private func sectionBadge(_ section: DashboardSidebarSection) -> String? {
        switch section {
        case .providers:
            return "\(activeProviderCount)"
        case .models:
            return "\(dashboardModelSummaries.count)"
        case .projects:
            let count = topProjectSummaries.count
            return count > 0 ? "\(count)" : nil
        case .sessions:
            let count = recentUsageSessions.count
            return count > 0 ? "\(count)" : nil
        case .fleet:
            return fleetModel.activeCount > 0 ? "\(fleetModel.activeCount) live" : nil
        case .inbox:
            let count = (aiInboxUnreadCount ?? 0) + (pendingMemoryReviewCount ?? 0)
            return count > 0 ? "\(count)" : nil
        case .quota:
            return nil
        }
    }

    @ViewBuilder
    private func sidebarSectionContent(
        section: DashboardSidebarSection,
        adaptiveColors: BackdropAdaptiveColors
    ) -> some View {
        switch section {
        case .providers:
            providersSectionContent(adaptiveColors: adaptiveColors)
        case .models:
            modelsSectionContent(adaptiveColors: adaptiveColors)
        case .projects:
            projectsSectionContent(adaptiveColors: adaptiveColors)
        case .sessions:
            sessionsSectionContent(adaptiveColors: adaptiveColors)
        case .quota:
            quotaSectionContent(adaptiveColors: adaptiveColors)
        case .fleet:
            fleetSectionContent(adaptiveColors: adaptiveColors)
        case .inbox:
            inboxSectionContent(adaptiveColors: adaptiveColors)
        }
    }

    // MARK: - Section Content Renderers

    @ViewBuilder
    private func providersSectionContent(adaptiveColors: BackdropAdaptiveColors) -> some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            SidebarItem(
                provider: nil,
                isSelected: mainRoute == .overview,
                primaryMetric: settingsManager.formatUsageMetric(cost: totalCostForTimeRange, tokens: totalTokensForTimeRange),
                totalCost: totalCostForTimeRange,
                sessionCount: dashboardUsageWindow.sessionCount
            ) {
                withAnimation(DesignSystem.Animation.standard) {
                    routeHistory.removeAll()
                    mainRoute = .overview
                }
            }

            ForEach(Array(dashboardProviderSummaries.enumerated()), id: \.element.id) { index, summary in
                SidebarItem(
                    provider: summary.provider,
                    isSelected: mainRoute == .provider(summary.provider),
                    primaryMetric: settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens),
                    totalCost: summary.totalCost,
                    sessionCount: summary.sessionCount
                ) {
                    withAnimation(DesignSystem.Animation.standard) {
                        navigate(to: .provider(summary.provider))
                    }
                }
                .opacity(sidebarAppeared ? 1 : 0)
                .offset(y: sidebarAppeared ? 0 : 8)
                .animation(
                    DesignSystem.Animation.standard.delay(Double(index) * 0.04),
                    value: sidebarAppeared
                )
            }

            if dashboardProviderSummaries.isEmpty {
                Text("No providers in this window")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(adaptiveColors.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DesignSystem.Spacing.md)
            }
        }
    }

    @ViewBuilder
    private func modelsSectionContent(adaptiveColors: BackdropAdaptiveColors) -> some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            ForEach(Array(dashboardModelSummaries.enumerated()), id: \.element.id) { index, summary in
                ModelSidebarItem(
                    summary: summary,
                    isSelected: mainRoute == .model(summary.modelName)
                ) {
                    withAnimation(DesignSystem.Animation.standard) {
                        navigate(to: .model(summary.modelName))
                    }
                }
                .opacity(sidebarAppeared ? 1 : 0)
                .offset(y: sidebarAppeared ? 0 : 8)
                .animation(
                    DesignSystem.Animation.standard.delay(Double(index) * 0.04),
                    value: sidebarAppeared
                )
            }

            if dashboardModelSummaries.isEmpty {
                Text("No models in this window")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(adaptiveColors.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DesignSystem.Spacing.md)
            }
        }
    }

    @ViewBuilder
    private func projectsSectionContent(adaptiveColors: BackdropAdaptiveColors) -> some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            if topProjectSummaries.isEmpty {
                Text("No projects in this window")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(adaptiveColors.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DesignSystem.Spacing.md)
            } else {
                ForEach(topProjectSummaries, id: \.name) { project in
                    Button {
                        withAnimation(DesignSystem.Animation.standard) {
                            navigate(to: .projects)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(DesignSystem.Colors.whimsy)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.name)
                                    .font(DesignSystem.Typography.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(adaptiveColors.primary)
                                    .lineLimit(1)

                                Text("\(project.count) sessions")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(adaptiveColors.muted)
                            }

                            Spacer(minLength: 0)

                            Text(settingsManager.formatUsageMetric(cost: project.cost, tokens: project.tokens))
                                .font(DesignSystem.Typography.tiny)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundStyle(adaptiveColors.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(mainRoute == .projects ? DesignSystem.Colors.ember.opacity(0.12) : adaptiveColors.primary.opacity(0.04))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    withAnimation(DesignSystem.Animation.standard) {
                        navigate(to: .projects)
                    }
                } label: {
                    HStack {
                        Text("View all projects")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.whimsy)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundStyle(DesignSystem.Colors.whimsy)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func sessionsSectionContent(adaptiveColors: BackdropAdaptiveColors) -> some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            if recentUsageSessions.isEmpty {
                Text("No recent sessions")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(adaptiveColors.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DesignSystem.Spacing.md)
            } else {
                ForEach(recentUsageSessions) { session in
                    Button {
                        withAnimation(DesignSystem.Animation.standard) {
                            navigate(to: .sessionLogs)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            ProviderLogoView(provider: session.provider, size: 14)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.model.isEmpty ? session.provider.displayName : session.model)
                                    .font(DesignSystem.Typography.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(adaptiveColors.primary)
                                    .lineLimit(1)

                                Text(session.startTime, style: .time)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(adaptiveColors.muted)
                            }

                            Spacer(minLength: 0)

                            Text(settingsManager.formatUsageMetric(cost: session.cost, tokens: session.totalTokens))
                                .font(DesignSystem.Typography.tiny)
                                .monospacedDigit()
                                .foregroundStyle(adaptiveColors.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(mainRoute == .sessionLogs ? DesignSystem.Colors.ember.opacity(0.12) : adaptiveColors.primary.opacity(0.04))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    withAnimation(DesignSystem.Animation.standard) {
                        navigate(to: .sessionLogs)
                    }
                } label: {
                    HStack {
                        Text("All session logs")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.ember)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundStyle(DesignSystem.Colors.ember)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func quotaSectionContent(adaptiveColors: BackdropAdaptiveColors) -> some View {
        sidebarNavRow(
            icon: "gauge.with.dots.needle.67percent",
            iconTint: DesignSystem.Colors.amber,
            title: "Quota & Subscriptions",
            subtitle: "Check limits & renewals",
            route: .quota,
            adaptiveColors: adaptiveColors
        )
    }

    @ViewBuilder
    private func fleetSectionContent(adaptiveColors: BackdropAdaptiveColors) -> some View {
        sidebarNavRow(
            icon: "antenna.radiowaves.left.and.right",
            iconTint: fleetModel.activeCount > 0 ? DesignSystem.Colors.success : adaptiveColors.muted,
            title: "Live Agent Fleet",
            subtitle: fleetModel.activeCount > 0 ? "\(fleetModel.activeCount) agents active" : "No agents running",
            route: .fleet,
            adaptiveColors: adaptiveColors
        )
    }

    @ViewBuilder
    private func inboxSectionContent(adaptiveColors: BackdropAdaptiveColors) -> some View {
        let unread = (aiInboxUnreadCount ?? 0) + (pendingMemoryReviewCount ?? 0)
        sidebarNavRow(
            icon: "tray.full.fill",
            iconTint: unread > 0 ? DesignSystem.Colors.ember : adaptiveColors.secondary,
            title: "AI Inbox",
            subtitle: unread > 0 ? "\(unread) items need review" : "Inbox up to date",
            route: .inbox,
            adaptiveColors: adaptiveColors
        )
    }

    /// The shared one-line nav row: icon, title over subtitle, chevron, with the
    /// ember wash marking the selected route.
    @ViewBuilder
    private func sidebarNavRow(
        icon: String,
        iconTint: Color,
        title: String,
        subtitle: String,
        route: DashboardMainRoute,
        adaptiveColors: BackdropAdaptiveColors
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Button {
                withAnimation(DesignSystem.Animation.standard) {
                    navigate(to: route)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(iconTint)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(adaptiveColors.primary)

                        Text(subtitle)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(adaptiveColors.muted)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(adaptiveColors.muted)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(mainRoute == route ? DesignSystem.Colors.ember.opacity(0.12) : adaptiveColors.primary.opacity(0.04))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Section Mutations

    private func moveSidebarSection(_ section: DashboardSidebarSection, by offset: Int) {
        let newOrder = DashboardSidebarSection.moveSection(section, by: offset, in: sidebarSections)
        withAnimation(MotionTokens.settle(reduceMotion: reduceMotion)) {
            sidebarSectionOrderRaw = DashboardSidebarSection.encode(newOrder)
        }
    }

    private func toggleSidebarSectionCollapsed(_ section: DashboardSidebarSection) {
        let updated = DashboardSidebarSectionState.toggleCollapsed(section, in: sidebarSectionState)
        withAnimation(MotionTokens.settle(reduceMotion: reduceMotion)) {
            sidebarSectionStateRaw = DashboardSidebarSectionState.encode(updated)
        }
    }

    private func toggleSidebarSectionVisibility(_ section: DashboardSidebarSection) {
        let updated = DashboardSidebarSectionState.toggleVisibility(section, in: sidebarSectionState)
        withAnimation(MotionTokens.settle(reduceMotion: reduceMotion)) {
            sidebarSectionStateRaw = DashboardSidebarSectionState.encode(updated)
        }
    }

    private func resetSidebarSections() {
        withAnimation(MotionTokens.settle(reduceMotion: reduceMotion)) {
            sidebarSectionOrderRaw = DashboardSidebarSection.encode(DashboardSidebarSection.defaultOrder)
            sidebarSectionStateRaw = "{}"
        }
    }

    var sidebarRouteOrder: [DashboardMainRoute] {
        var routes: [DashboardMainRoute] = [.overview, .insights, .recap]
        for section in sidebarSections {
            guard sidebarSectionState[section.rawValue]?.isVisible ?? true else { continue }
            switch section {
            case .providers:
                routes.append(contentsOf: dashboardProviderSummaries.map { .provider($0.provider) })
            case .models:
                routes.append(contentsOf: dashboardModelSummaries.map { .model($0.modelName) })
            case .projects:
                if !routes.contains(.projects) { routes.append(.projects) }
            case .sessions:
                if !routes.contains(.sessionLogs) { routes.append(.sessionLogs) }
            case .quota:
                if !routes.contains(.quota) { routes.append(.quota) }
            case .fleet:
                if !routes.contains(.fleet) { routes.append(.fleet) }
            case .inbox:
                if !routes.contains(.inbox) { routes.append(.inbox) }
            }
        }
        return routes
    }
}

private struct DashboardSidebarMaterial: View {
    let liveBackdropActive: Bool
    let moodBand: MoodBand
    let kernelColorScheme: ColorScheme

    var body: some View {
        if liveBackdropActive {
            liveGlass
        } else {
            staticSurface
        }
    }

    /// One plate over the window's single field.
    ///
    /// This used to mount a whole second `DashboardBackdrop` — a second live backdrop,
    /// with its own WebContent process, sampling its own canvas and throwing every
    /// readability profile it produced away. Two independent fields also meant a
    /// structural seam down the split-view divider, because neither knew where the other
    /// one was. A single registered plate makes the sidebar's weather the *continuation*
    /// of the main field, so the seam disappears for free.
    private var liveGlass: some View {
        Color.clear
            .burnBarGlass(.ledger, role: .chrome, cornerRadius: 0)
    }

    private var staticSurface: some View {
        ZStack {
            DesignSystem.Colors.surface.opacity(0.92)

            LinearGradient(
                colors: [
                    DesignSystem.Colors.textPrimary.opacity(0.02),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

/// SwiftUI's sidebar-removal placement is occasionally reapplied after this
/// manually hosted dashboard window mounts. Keep the window chrome clean by
/// removing only the system toggle item; the in-sidebar button remains the
/// single visible control for this action.
struct DashboardSidebarToolbarItemRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DashboardSidebarToolbarScrubberView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DashboardSidebarToolbarScrubberView)?.removeSystemSidebarToggle()
    }
}

@MainActor
private final class DashboardSidebarToolbarScrubberView: NSView {
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearObservers()
        guard let window else { return }

        removeSystemSidebarToggle()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.removeSystemSidebarToggle()
        }

        let center = NotificationCenter.default
        let notificationNames: [NSNotification.Name] = [
            NSWindow.didUpdateNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification
        ]

        for name in notificationNames {
            let obs = center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.removeSystemSidebarToggle()
                }
            }
            observers.append(obs)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            clearObservers()
        }
    }

    private func clearObservers() {
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
        observers.removeAll()
    }

    // No `deinit` teardown: `observers` is `@MainActor` state and a nonisolated
    // deinit cannot touch it under Swift 6. It does not need to — entries are only
    // registered while the view is attached to a window, and
    // `viewWillMove(toWindow: nil)` clears them on the way out.

    func removeSystemSidebarToggle() {
        guard let toolbar = window?.toolbar else { return }
        for index in toolbar.items.indices.reversed() {
            let item = toolbar.items[index]
            if item.itemIdentifier == .toggleSidebar ||
                item.itemIdentifier.rawValue == "NSToolbarToggleSidebarItemIdentifier" {
                toolbar.removeItem(at: index)
            }
        }
    }
}
