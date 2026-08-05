import SwiftUI
import OpenBurnBarCore

extension SessionLogsView {
    // MARK: - Command Center

    var commandCenter: some View {
        VStack(spacing: 0) {
            statsHeader
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.top, DesignSystem.Spacing.md)
                .padding(.bottom, DesignSystem.Spacing.sm)

            searchBar
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.bottom, DesignSystem.Spacing.sm)

            filterBar
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.bottom, hasAnyDevices ? DesignSystem.Spacing.sm : DesignSystem.Spacing.md)

            if hasAnyDevices {
                deviceFilterBar
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.bottom, DesignSystem.Spacing.md)
            }

            if dataSource == .local, !visibleDegradedModes.isEmpty {
                retrievalDegradedModeBanner
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.bottom, DesignSystem.Spacing.md)
            }

            Divider().background(DesignSystem.Colors.border.opacity(0.6))

            if isLoading {
                Spacer()
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ProgressView()
                    Text("Loading logs…")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Spacer()
            } else if filteredLogs.isEmpty {
                emptyListState
            } else {
                groupedList
            }
        }
        .background {
            if dashboardLiveBackdropActive {
                Color.clear.liquidGlassSurface(in: RoundedRectangle(cornerRadius: DesignSystem.Radius.md), fallback: .ultraThinMaterial)
            } else {
                ZStack {
                    DesignSystem.Colors.surface.opacity(0.92)
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.textPrimary.opacity(0.015),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        }
        .onAppear { appeared = true }
    }

    // MARK: - Stats Header

    private var statsHeader: some View {
        let providerCount = Set(filteredLogs.map(\.provider)).count
        let projectCount = Set(filteredLogs.map(\.projectName)).count

        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "scroll")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.ember)
                Text("Session Logs")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer(minLength: 0)

                Text("\(filteredLogs.count.formatted())")
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .monospacedDigit()
            }

            HStack(spacing: DesignSystem.Spacing.xs) {
                statPill(value: providerCount, label: "provider")
                dotSeparator
                statPill(value: projectCount, label: "project")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dotSeparator: some View {
        Circle()
            .fill(DesignSystem.Colors.textMuted.opacity(0.35))
            .frame(width: 2, height: 2)
    }

    private func statPill(value: Int, label: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.xxs) {
            Text("\(value)")
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .monospacedDigit()
            Text(value == 1 ? label : label + "s")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .fixedSize()
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            TextField("Search sessions…", text: $searchText)
                .font(DesignSystem.Typography.caption)
                .textFieldStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .help("Search by title, project, provider, or keyword")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }

            if dataSource == .local, isRetrievalSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .liquidGlassSurface(
            in: RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous),
            fallback: .ultraThinMaterial
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
        )
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            // Scope segments own a full row so their labels never compress into
            // vertical letters when the rail is narrow.
            HStack(spacing: 2) {
                ForEach(SessionLogSourceFilter.allCases) { filter in
                    sourceFilterButton(filter)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.5)
            )

            HStack(spacing: DesignSystem.Spacing.xs) {
                groupModePicker

                Spacer(minLength: 0)

                exportButton

                dataSourceMenu
            }
        }
    }

    private var exportButton: some View {
        Button {
            Task { await exportAllConversations() }
        } label: {
            if isExporting {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 20)
            } else {
                filterIconButton(
                    systemImage: "square.and.arrow.up",
                    isActive: false,
                    activeColor: DesignSystem.Colors.teal
                )
            }
        }
        .buttonStyle(.plain)
        .disabled(isExporting || filteredLogs.isEmpty)
        .help("Export \(filteredLogs.count) conversation\(filteredLogs.count == 1 ? "" : "s") to a folder (JSON + Markdown)")
    }

    private func sourceFilterButton(_ filter: SessionLogSourceFilter) -> some View {
        let isActive = sourceFilter == filter
        let accent = filterAccent(for: filter)
        return Button {
            withAnimation(DesignSystem.Animation.snappy) {
                sourceFilter = filter
            }
        } label: {
            Text(filter.rawValue)
                .font(DesignSystem.Typography.tiny)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(isActive ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isActive ? AnyShapeStyle(accent.opacity(0.18)) : AnyShapeStyle(Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isActive ? accent.opacity(0.4) : Color.clear, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var groupModePicker: some View {
        HStack(spacing: 2) {
            ForEach(SessionLogGroupMode.allCases) { mode in
                groupModeButton(mode)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func groupModeButton(_ mode: SessionLogGroupMode) -> some View {
        let isActive = groupMode == mode
        return Button {
            withAnimation(DesignSystem.Animation.snappy) {
                groupMode = mode
            }
        } label: {
            Image(systemName: mode.icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isActive ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isActive ? DesignSystem.Colors.surfaceElevated : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help("Group by \(mode.rawValue.lowercased())")
    }

    private var dataSourceMenu: some View {
        Menu {
            ForEach(SessionLogDataSource.allCases) { source in
                Button {
                    withAnimation(DesignSystem.Animation.snappy) {
                        dataSource = source
                    }
                } label: {
                    Label(source.rawValue, systemImage: source.icon)
                }
            }
        } label: {
            filterIconButton(
                systemImage: dataSource.icon,
                isActive: dataSource != .local,
                activeColor: DesignSystem.Colors.ember
            )
        }
        .menuStyle(.borderlessButton)
        .help("Data source: \(dataSource.rawValue)")
    }

    private func filterIconButton(systemImage: String, isActive: Bool, activeColor: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isActive ? activeColor : DesignSystem.Colors.textMuted)
            .frame(width: 24, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isActive ? activeColor.opacity(0.12) : Color.clear)
            )
    }

    private func filterAccent(for filter: SessionLogSourceFilter) -> Color {
        switch filter {
        case .all:       return DesignSystem.Colors.ember
        case .provider:  return DesignSystem.Colors.amber
        case .assistant: return DesignSystem.Colors.whimsy
        }
    }

    private var deviceFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                deviceFilterPill(label: "All", icon: "rectangle.stack", id: nil)

                ForEach(knownDevices) { device in
                    deviceFilterPill(label: device.deviceName, icon: device.sfSymbolName, id: device.deviceId)
                }
            }
        }
    }

    private func deviceFilterPill(label: String, icon: String, id: String?) -> some View {
        let isActive = deviceFilter == id
        return Button {
            withAnimation(DesignSystem.Animation.snappy) {
                deviceFilter = id
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
                Text(label)
                    .lineLimit(1)
            }
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(isActive ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xxs + 1)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                    .fill(isActive ? DesignSystem.Colors.teal.opacity(0.18) : DesignSystem.Colors.surfaceElevated.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                    .strokeBorder(
                        isActive ? DesignSystem.Colors.teal.opacity(0.45) : DesignSystem.Colors.border.opacity(0.3),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                if let id { iconPickerDeviceId = id }
            }
        )
        .popover(isPresented: Binding(
            get: { iconPickerDeviceId == id && id != nil },
            set: { if !$0 { iconPickerDeviceId = nil } }
        )) {
            if let id {
                DeviceIconPicker(
                    deviceId: id,
                    currentIcon: icon,
                    dataStore: dataStore
                ) {
                    iconPickerDeviceId = nil
                    Task { @MainActor in
                        knownDevices = (try? await dataStore.fetchDevices()) ?? []
                    }
                }
            }
        }
    }

    private var retrievalDegradedModeBanner: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            ForEach(visibleDegradedModes) { state in
                HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignSystem.Colors.warning)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text(state.message)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(DesignSystem.Colors.warning.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
            }
        }
    }

    // MARK: - Grouped List

    private var groupedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(logGroups) { group in
                        Section {
                            if expandedSections.contains(group.id) {
                                sectionContent(for: group)
                            }
                        } header: {
                            sectionHeader(for: group)
                        }
                    }
                }
                .padding(.vertical, DesignSystem.Spacing.xs)
            }
            .defaultScrollAnchor(.top)
            .scrollContentBackground(.hidden)
            .onChange(of: logGroups.first?.id) { _, _ in
                if let firstId = logGroups.first?.id {
                    withAnimation { proxy.scrollTo(firstId, anchor: .top) }
                }
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }

    private func sectionHeader(for group: SessionLogGroup) -> some View {
        let isExpanded = expandedSections.contains(group.id)
        return Button {
            withAnimation(DesignSystem.Animation.snappy) {
                if isExpanded {
                    expandedSections.remove(group.id)
                } else {
                    expandedSections.insert(group.id)
                }
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs + 2) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10, alignment: .center)

                if let provider = group.provider {
                    ProviderLogoView(provider: provider, size: 13, useFallbackColor: true)
                } else {
                    Image(systemName: group.systemImage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(group.accentColor.opacity(0.85))
                        .frame(width: 13)
                }

                Text(group.title)
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(
                        isExpanded ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted
                    )
                    .lineLimit(1)

                Spacer(minLength: DesignSystem.Spacing.xs)

                Text("\(group.logs.count)")
                    .font(DesignSystem.Typography.monoSmall)
                    .monospacedDigit()
                    .foregroundStyle(group.accentColor.opacity(0.9))
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs + 1)
            .background(
                DesignSystem.Colors.surface
                    .opacity(0.96)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(DesignSystem.Colors.border.opacity(isExpanded ? 0.0 : 0.25))
                            .frame(height: 0.5)
                    }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(group.id)
    }

    @ViewBuilder
    private func sectionContent(for group: SessionLogGroup) -> some View {
        let limit = sectionDisplayLimits[group.id] ?? defaultDisplayLimit
        let showing = Array(group.logs.prefix(limit))

        VStack(spacing: DesignSystem.Spacing.xxs) {
            ForEach(showing) { record in
                CompactSessionRow(
                    record: record,
                    isSelected: selectedId == record.id,
                    showDeviceIndicator: hasMultipleDevices,
                    modelName: sessionModelMap[record.id],
                    deviceIcon: record.sourceDeviceId.flatMap { did in
                        knownDevices.first { $0.deviceId == did }?.sfSymbolName
                    }
                ) {
                    withAnimation(DesignSystem.Animation.snappy) {
                        selectedId = record.id
                    }
                } onResume: { targetHarness in
                    resumeRequest = SessionResumeRequest(record: record, targetHarness: targetHarness)
                }
            }

            if group.logs.count > limit {
                let remaining = group.logs.count - limit
                Button {
                    withAnimation(DesignSystem.Animation.gentle) {
                        sectionDisplayLimits[group.id] = limit + min(30, remaining)
                    }
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 9))
                        Text("Show \(min(30, remaining)) more of \(remaining) remaining")
                            .font(DesignSystem.Typography.tiny)
                    }
                    .foregroundStyle(group.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.top, DesignSystem.Spacing.xxs)
        .padding(.bottom, DesignSystem.Spacing.sm)
        .transition(.opacity)
    }

    // MARK: - Empty State

    private var emptyListState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Spacer()
            Image(systemName: dataSource.icon)
                .font(.system(size: 36))
                .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.5))

            if let error = dataSourceError {
                Text("Could not load \(dataSource.rawValue) logs")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(error)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
            } else if dataSource == .cloud {
                if !accountManager.isSignedIn {
                    Text("Sign in to load cloud logs")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Cloud logs require a OpenBurnBar account. Sign in via Settings.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                } else {
                    Text(searchText.isEmpty ? "No cloud logs yet" : "No results")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(searchText.isEmpty
                            ? "Enable session log cloud backup in Settings to store logs here."
                            : "Try a different search term."
                    )
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                }
            } else if dataSource == .iCloud {
                if !(iCloudMirrorService?.hasUbiquityIdentity ?? false) {
                    Text("Sign in to iCloud")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Sign in to iCloud in System Settings to access your mirrored sessions.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                } else {
                    Text(searchText.isEmpty ? "No mirrored files found" : "No results")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(searchText.isEmpty
                            ? "Enable iCloud session mirror in Settings and run a sync first."
                            : "Try a different search term."
                    )
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                }
            } else if !settingsManager.conversationIndexingEnabled && sourceFilter != .assistant {
                Text("Enable conversation indexing")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Turn on indexing in Settings to track your provider sessions here.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
            } else {
                Text(searchText.isEmpty ? "No logs yet" : "No results")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(searchText.isEmpty
                        ? "Start a chat with the OpenBurnBar Assistant, or scan your provider sessions."
                        : "Try a different search term."
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.Spacing.lg)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
