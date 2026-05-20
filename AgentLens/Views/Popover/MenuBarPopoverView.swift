import SwiftUI
import AppKit

// MARK: - Menu Bar Popover View

struct MenuBarPopoverView: View {
    @Environment(\.dismiss) private var dismiss
    let dataStore: DataStore
    var aggregator: UsageAggregator?
    var quotaService: ProviderQuotaService?
    let settingsManager: SettingsManager
    var smartHubBridgeController: SmartHubBridgeController?
    var smartDisplayRepairCoordinator: SmartDisplayRepairCoordinator?
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer
    let onOpenDashboard: () -> Void
    let onOpenSettings: () -> Void
    var chatController: ChatSessionController?
    var onOpenDashboardWithChat: (() -> Void)?
    var onOpenOnboardingWizard: (() -> Void)?
    /// Mercury Phase 8 — when present, the popover renders a Mercury
    /// tray section with the live indicator + outbound triggers.
    /// Left optional so previews + onboarding paths can omit it.
    var runtimeContext: OpenBurnBarRuntimeContext?

    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var showScanFlash = false
    @State private var listAppeared = false
    @State private var insightSnapshot: WorkflowInsightRollupSnapshot = .unavailable
    @State private var hermesChatActive = false
    @State private var isCastingSmartHub = false
    @State private var smartHubCastStatusMessage: String?
    @State private var resizingStartSize: CGSize?
    @State private var hoveredSectionID: String? = nil

    @AppStorage("popoverTrayWidth") private var storedPopoverTrayWidth = 340.0
    @AppStorage("popoverTrayHeight") private var storedPopoverTrayHeight = 540.0
    @AppStorage("popoverTraySectionOrder") private var storedPopoverTraySectionOrder = ""
    @AppStorage("hasResetScrambledPopoverLayoutV2") private var hasResetScrambledPopoverLayoutV2 = false

    private var isScanning: Bool { aggregator?.isRefreshing ?? false }

    private var insights: [Insight] {
        insightSnapshot.insights
    }

    private var popoverWidth: CGFloat {
        clampPopoverWidth(CGFloat(storedPopoverTrayWidth))
    }

    private var popoverViewportHeight: CGFloat {
        clampPopoverHeight(CGFloat(storedPopoverTrayHeight))
    }

    private var popoverScrollMaxHeight: CGFloat {
        max(popoverViewportHeight - 285, 210)
    }

    private var availableTraySections: [PopoverTraySection] {
        PopoverTraySection.allCases.filter { section in
            switch section {
            case .chat:
                return chatController != nil
            case .mercury:
                return runtimeContext?.mercuryRouter != nil
            default:
                return true
            }
        }
    }

    private var orderedTraySections: [PopoverTraySection] {
        let available = availableTraySections
        let decoded = storedPopoverTraySectionOrder
            .split(separator: ",")
            .compactMap { PopoverTraySection(rawValue: String($0)) }
            .filter { available.contains($0) }
        let appended = decoded + available.filter { !decoded.contains($0) }
        return appended.isEmpty ? available : appended
    }

    private var menuBarSparklineSeries: [Double] {
        switch settingsManager.usageDisplayMode {
        case .currency:
            return dataStore.last7DayCosts
        case .tokens:
            return dataStore.last7DayTokenTotals.map { Double($0) }
        }
    }

    private var lastRefreshDate: Date? {
        aggregator?.lastRefresh ?? dataStore.lastRefresh
    }

    private func runScan() {
        guard let agg = aggregator else { return }
        Task { await agg.refreshAll() }
    }

    private func runRecount() {
        guard let agg = aggregator else { return }
        Task { await agg.recountAll() }
    }

    private func refreshInsightRollups() {
        insightSnapshot = WorkflowInsightRollupService(dataStore: dataStore).snapshot(refreshIfStale: true)
    }

    private var smartHubCastTooltip: String {
        if isCastingSmartHub {
            return "Casting OpenBurnBar to your smart display."
        }
        if let smartHubCastStatusMessage {
            return smartHubCastStatusMessage
        }
        return "Cast OpenBurnBar to your saved Nest Hub or smart display."
    }

    private func castSmartHubFromTray() {
        guard !isCastingSmartHub else { return }
        isCastingSmartHub = true
        smartHubCastStatusMessage = "Casting OpenBurnBar to your smart display..."
        Task { @MainActor in
            let adapter = MacSmartHubDisplayOperationsAdapter(
                settingsManager: settingsManager,
                controller: smartHubBridgeController,
                repairCoordinator: smartDisplayRepairCoordinator
            )
            let status = await adapter.repairDisplay()
            smartHubCastStatusMessage = status.message
            isCastingSmartHub = false
        }
    }

    var body: some View {
        Group {
            if !hasOnboarded && dataStore.totalUsageSessionCount == 0, aggregator != nil {
                OnboardingView(
                    settingsManager: settingsManager,
                    onOpenWizard: {
                        dismiss()
                        onOpenOnboardingWizard?()
                    },
                    onSkip: {
                        hasOnboarded = true
                    }
                )
            } else if hermesChatActive, let chatController {
                AssistantsPopoverChatView(
                    controller: chatController,
                    operatingLayer: operatingLayer,
                    settingsManager: settingsManager,
                    onDismissChat: {
                        withAnimation(DesignSystem.Animation.gentle) {
                            hermesChatActive = false
                        }
                    },
                    onOpenDashboardWithChat: {
                        dismiss()
                        onOpenDashboardWithChat?()
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    headerView
                    freshnessBar
                    Divider().background(DesignSystem.Colors.border)

                    QuotaPopoverBar(
                        quotaService: quotaService ?? ProviderQuotaService.shared,
                        settingsManager: settingsManager,
                        dataStore: dataStore
                    )
                    Divider().background(DesignSystem.Colors.border)

                    ScrollView(.vertical, showsIndicators: true) {
                        trayContent
                    }
                    .frame(width: popoverWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .clipped()

                    Divider().background(DesignSystem.Colors.border)
                    cloudWhisperStrip
                    Divider().background(DesignSystem.Colors.border)
                    actionBar
                }
            }
        }
        .frame(width: popoverWidth)
        .frame(height: popoverViewportHeight)
        .background(DesignSystem.Colors.background)
        .overlay(alignment: .bottomTrailing) {
            resizeHandle
        }
        .onChange(of: isScanning) { oldValue, newValue in
            guard oldValue, !newValue else { return }
            refreshInsightRollups()
            Task { @MainActor in
                withAnimation(DesignSystem.Animation.gentle) {
                    showScanFlash = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(DesignSystem.Animation.gentle) {
                        showScanFlash = false
                    }
                }
            }
        }
        .onAppear {
            if !hasResetScrambledPopoverLayoutV2 {
                storedPopoverTrayHeight = 540.0
                storedPopoverTraySectionOrder = ""
                hasResetScrambledPopoverLayoutV2 = true
            }
            clampStoredPopoverSize()
            Task { @MainActor in
                listAppeared = true
                refreshInsightRollups()
                await operatingLayer.refreshControllerRuntime()
                // Auto-open chat view if Hermes is actively streaming or has an active conversation
                if let ctrl = chatController,
                   (ctrl.isStreaming || !ctrl.messages.isEmpty) {
                    hermesChatActive = true
                }
            }
        }
        .onChange(of: dataStore.lastRefresh) { _, _ in
            refreshInsightRollups()
        }
        .openBurnBarPreferredColorScheme(settingsManager.preferredSwiftUIColorScheme)
        .environment(settingsManager)
    }

    // MARK: - Tray Layout

    private var trayContent: some View {
        VStack(spacing: 0) {
            let sections = orderedTraySections
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                traySection(section)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            hoveredSectionID = hovering ? section.id : nil
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if hoveredSectionID == section.id {
                            trayReorderControls(for: section, at: index, totalCount: sections.count)
                                .transition(.opacity)
                        }
                    }
                if index < sections.count - 1 {
                    Divider().background(DesignSystem.Colors.border)
                }
            }
        }
        .animation(DesignSystem.Animation.snappy, value: orderedTraySections)
    }

    @ViewBuilder
    private func traySection(_ section: PopoverTraySection) -> some View {
        switch section {
        case .insights:
            InsightCardView(
                insights: insights,
                freshness: insightSnapshot.freshness,
                freshnessMessage: insightSnapshot.statusMessage
            )
        case .summary:
            summaryView
        case .providers:
            providerListView
        case .chat:
            if let chatController {
                AssistantsPopoverStrip(
                    controller: chatController,
                    onOpenDashboardWithChat: {
                        onOpenDashboardWithChat?()
                    },
                    onActivateChat: {
                        withAnimation(DesignSystem.Animation.gentle) {
                            hermesChatActive = true
                        }
                    },
                    hermesSetupCompleted: settingsManager.hermesSetupWizardCompleted,
                    onRequireHermesSetup: {
                        dismiss()
                        WindowManager.shared.openHermesSetupWizard(
                            settingsManager: settingsManager,
                            chatController: chatController,
                            dataStore: dataStore
                        )
                    }
                )
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
            }
        case .quickSwitch:
            PopoverQuickSwitchView(
                dataStore: dataStore,
                onOpenSettings: {
                    dismiss()
                    onOpenSettings()
                },
                settingsManager: settingsManager
            )
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs)
        case .mercury:
            if let router = runtimeContext?.mercuryRouter,
               let peerSource = runtimeContext?.mercuryPeerSource {
                MercuryTraySection(
                    router: router,
                    peerSource: peerSource,
                    fileTransferService: runtimeContext?.hermesRelayHostService?.mercuryFileTransfer,
                    voipCallTrigger: runtimeContext?.voipCallTrigger,
                    consentStore: runtimeContext?.mercuryConsentStore,
                    uidProvider: { [weak runtimeContext] in
                        runtimeContext?.accountManager.userID
                    },
                    onDismissPopover: { dismiss() }
                )
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
            }
        }
    }

    private func trayReorderControls(for section: PopoverTraySection, at index: Int, totalCount: Int) -> some View {
        HStack(spacing: 0) {
            Button {
                moveTraySection(section, offset: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .accessibilityLabel("Move \(section.accessibilityLabel) up")
            .popoverTooltip("Move \(section.accessibilityLabel) up")

            Button {
                moveTraySection(section, offset: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index >= totalCount - 1)
            .accessibilityLabel("Move \(section.accessibilityLabel) down")
            .popoverTooltip("Move \(section.accessibilityLabel) down")
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.72))
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .frame(height: 22)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
        .padding(.top, 3)
        .padding(.trailing, 4)
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.75))
            .frame(width: 28, height: 28)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if resizingStartSize == nil {
                            resizingStartSize = CGSize(width: popoverWidth, height: popoverViewportHeight)
                        }
                        let start = resizingStartSize ?? CGSize(width: popoverWidth, height: popoverViewportHeight)
                        storedPopoverTrayWidth = Double(clampPopoverWidth(start.width + value.translation.width))
                        storedPopoverTrayHeight = Double(clampPopoverHeight(start.height + value.translation.height))
                    }
                    .onEnded { _ in
                        resizingStartSize = nil
                        clampStoredPopoverSize()
                    }
            )
            .accessibilityLabel("Resize popover tray")
            .popoverTooltip("Drag to resize")
            .padding(2)
    }

    private func setTraySectionOrder(_ sections: [PopoverTraySection]) {
        let available = availableTraySections
        let normalized = sections.filter { available.contains($0) }
            + available.filter { !sections.contains($0) }
        storedPopoverTraySectionOrder = normalized.map(\.rawValue).joined(separator: ",")
    }

    private func moveTraySection(_ section: PopoverTraySection, offset: Int) {
        let sections = orderedTraySections
        guard let currentIndex = sections.firstIndex(of: section) else { return }
        moveTraySection(section, toSlot: currentIndex + offset)
    }

    private func moveTraySection(_ section: PopoverTraySection, toSlot slot: Int) {
        var sections = orderedTraySections
        guard let currentIndex = sections.firstIndex(of: section) else { return }

        sections.remove(at: currentIndex)
        let adjustedSlot = slot > currentIndex ? slot - 1 : slot
        let clampedSlot = min(max(adjustedSlot, 0), sections.count)
        sections.insert(section, at: clampedSlot)
        withAnimation(DesignSystem.Animation.snappy) {
            setTraySectionOrder(sections)
        }
    }

    private func clampStoredPopoverSize() {
        storedPopoverTrayWidth = Double(popoverWidth)
        storedPopoverTrayHeight = Double(popoverViewportHeight)
    }

    private func clampPopoverWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, 320), 560)
    }

    private func clampPopoverHeight(_ height: CGFloat) -> CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let maxHeight = min(max(screenHeight * 0.86, 500), 760)
        return min(max(height, 500), maxHeight)
    }

    // MARK: - Header

    private var headerView: some View {
        GlassCard {
            HStack(spacing: DesignSystem.Spacing.sm) {
                AppLogoView(size: 28)

                Text("OpenBurnBar")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Spacer()

                GlassIconButton(isLoading: isCastingSmartHub, action: castSmartHubFromTray) {
                    Image(systemName: "airplayvideo")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .popoverTooltip(smartHubCastTooltip)

                GlassIconButton(action: runRecount) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .disabled(isScanning || aggregator == nil)
                .popoverTooltip("Rebuild usage totals from saved sessions (clears derived numbers, then tallies again).")

                GlassIconButton(isLoading: isScanning, action: runScan) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .popoverTooltip("Import new and updated sessions from your agent log folders.")

                GlassIconButton(action: {
                    dismiss()
                    onOpenSettings()
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .popoverTooltip("Open settings")
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, DesignSystem.Spacing.md)
        }
        .background(
            DesignSystem.Colors.success.opacity(showScanFlash ? 0.08 : 0)
        )
    }

    // MARK: - Freshness Bar

    private var freshnessBar: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(spacing: DesignSystem.Spacing.xs) {
                Circle()
                    .fill(freshnessColor(at: context.date))
                    .frame(width: 6, height: 6)
                    .popoverTooltip("Data freshness indicator")

                Text(freshnessLabel(at: context.date))
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Spacer()

                if dataStore.totalUsageSessionCount > 0 {
                    Text(settingsManager.formatUsageMetric(cost: dataStore.totalCostToday, tokens: dataStore.totalTokensToday))
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.primaryGradient)
                        .popoverTooltip("Today's total cost/tokens")

                    Text("·")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    Text("\(dataStore.totalUsageSessionCount.formatted()) session\(dataStore.totalUsageSessionCount == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .popoverTooltip("Total imported sessions across all providers")
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(DesignSystem.Colors.surface.opacity(0.5))
        }
    }

    private func freshnessColor(at now: Date) -> Color {
        guard let last = lastRefreshDate else { return DesignSystem.Colors.textMuted }
        let elapsed = now.timeIntervalSince(last)
        if elapsed < 60 { return DesignSystem.Colors.success }
        if elapsed < 900 { return DesignSystem.Colors.textSecondary }
        return DesignSystem.Colors.warning
    }

    private func freshnessLabel(at now: Date) -> String {
        if isScanning { return "Scanning..." }
        guard let last = lastRefreshDate else { return "Not scanned yet" }
        let elapsed = Int(now.timeIntervalSince(last))
        if elapsed < 5 { return "Updated just now" }
        if elapsed < 60 { return "Updated \(elapsed)s ago" }
        if elapsed < 3600 { return "Updated \(elapsed / 60)m ago" }
        return "Updated \(elapsed / 3600)h ago"
    }

    // MARK: - Summary

    private var summaryView: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text(settingsManager.formatUsageMetric(cost: dataStore.totalCostToday, tokens: dataStore.totalTokensToday))
                    .font(DesignSystem.Typography.monoLarge)
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)
                    .contentTransition(.numericText(countsDown: false))
                    .animation(DesignSystem.Animation.gentle, value: dataStore.totalCostToday)
                    .animation(DesignSystem.Animation.gentle, value: dataStore.totalTokensToday)
                    .animation(DesignSystem.Animation.gentle, value: settingsManager.usageDisplayMode)
                    .popoverTooltip("Today's total cost/tokens across all providers")

                Text("today")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                HStack(spacing: DesignSystem.Spacing.xs) {
                    Circle()
                        .fill(dataStore.moodColor)
                        .frame(width: 6, height: 6)
                    Text(dataStore.moodLabel)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(dataStore.moodColor)
                }
                .popoverTooltip("Spending intensity: Light (<$5), Moderate ($5–20), Heavy (>$20)")

                Spacer()
            }

            HStack(spacing: DesignSystem.Spacing.xl) {
                PeriodCost(
                    label: "This Week",
                    value: settingsManager.formatUsageMetric(cost: dataStore.totalCostThisWeek, tokens: dataStore.totalTokensThisWeek)
                )
                .popoverTooltip("Rolling 7-day total")
                PeriodCost(
                    label: "This Month",
                    value: settingsManager.formatUsageMetric(cost: dataStore.totalCostThisMonth, tokens: dataStore.totalTokensThisMonth)
                )
                .popoverTooltip("Rolling 30-day total")
            }

            HStack {
                Spacer()
                MiniSparkline(data: menuBarSparklineSeries)
                    .popoverTooltip("7-day spending trend")
            }
        }
        .padding(DesignSystem.Spacing.lg)
    }

    // MARK: - Provider List

    private var providerListView: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("PROVIDERS")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.md)
                .popoverTooltip("Top 5 providers by cost")

            if dataStore.providerSummaries.isEmpty {
                emptyStateView
            } else {
                ForEach(Array(dataStore.providerSummaries.prefix(5).enumerated()), id: \.element.id) { index, summary in
                    ProviderListRow(summary: summary)
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, DesignSystem.Spacing.xs)
                        .popoverTooltip("\(summary.provider.displayName): \(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s")")
                        .opacity(listAppeared ? 1 : 0)
                        .offset(y: listAppeared ? 0 : 8)
                        .animation(
                            DesignSystem.Animation.standard.delay(Double(index) * 0.06),
                            value: listAppeared
                        )
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
        }
        .padding(.bottom, DesignSystem.Spacing.sm)
    }

    private var emptyStateView: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            if dataStore.totalUsageSessionCount == 0 {
                Image(systemName: "cpu")
                    .font(.system(size: 28))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text("Welcome to OpenBurnBar")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text("Click Scan to import sessions from\nyour AI coding agents.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .multilineTextAlignment(.center)
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text("The first scan reads your full log history and may take a moment.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .multilineTextAlignment(.center)
                }
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 28))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text("No activity")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.xl)
    }

    // MARK: - Action Bar

    // MARK: - Cloud whisper strip
    //
    // Renders the Cloud Member chip when entitled, the upsell when free.
    // Tapping either parks a deep-link in UserDefaults so the Settings
    // window opens straight on the Cloud pane.

    @ViewBuilder
    private var cloudWhisperStrip: some View {
        CloudWhisperStrip(
            onOpen: {
                UserDefaults.standard.set(SettingsTab.cloud.rawValue, forKey: "settings.pendingTab")
                dismiss()
                onOpenSettings()
            }
        )
    }

    private var actionBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            GlassButton(
                title: "Dashboard",
                icon: "chart.bar.fill",
                style: .prominent
            ) {
                dismiss()
                onOpenDashboard()
            }
            .popoverTooltip("Open the full dashboard")

            GlassButton(
                title: "Settings",
                icon: "gearshape.fill",
                style: .regular
            ) {
                dismiss()
                onOpenSettings()
            }
            .popoverTooltip("Open settings")

            GlassIconButton(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .popoverTooltip("Quit OpenBurnBar")
        }
        .padding(DesignSystem.Spacing.md)
    }

}

// MARK: - Period Cost

private struct PeriodCost: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text(value)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
    }
}

// MARK: - Provider List Row

private struct ProviderListRow: View {
    let summary: ProviderSummary

    @Environment(SettingsManager.self) private var settingsManager

    private var theme: ProviderTheme { ProviderTheme.theme(for: summary.provider) }

    var body: some View {
        GlassCard(interactive: true) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(theme.primaryColor.opacity(0.15))
                        .frame(width: 32, height: 32)

                    ProviderLogoView(provider: summary.provider, size: 20, useFallbackColor: false)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.provider.displayName)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text("\(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s")")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)

                        if summary.cacheEfficiency.hasSignal {
                            let tier = CacheHitRateTier(summary.cacheEfficiency)
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(tier.color)
                                    .frame(width: 4, height: 4)
                                Text("\(summary.cacheEfficiency.formattedHitRate) cache")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(tier.color)
                                    .monospacedDigit()
                            }
                            .help("Cache hit rate for \(summary.provider.displayName)")
                        }
                    }
                }

                Spacer()

                Text(settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens))
                    .font(DesignSystem.Typography.mono)
                    .foregroundStyle(theme.primaryColor)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
        }
    }
}

// MARK: - Glass Card (Glassmorphic)

/// View modifier that conditionally attaches a press-detecting drag gesture.
/// Only active when `interactive` is true, so non-interactive GlassCards inside
/// Button views don't swallow tap gestures.
private struct InteractiveGlassCardGesture: ViewModifier {
    let interactive: Bool
    @Binding var isPressed: Bool

    func body(content: Content) -> some View {
        if interactive {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
        } else {
            content
        }
    }
}

/// Frosted glass card with real material blur, warm tint, and luminous border.
struct GlassCard<Content: View>: View {
    var interactive: Bool = false
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    @State private var isHovered = false
    @State private var isPressed = false

    init(
        interactive: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.interactive = interactive
        self.content = content
    }

    /// Light mode: ember + Spanish orange sheen instead of neutral white.
    private var glassSheenGradient: LinearGradient {
        if colorScheme == .light {
            LinearGradient(
                colors: [
                    Color(hex: "F45B69").opacity(0.07),
                    Color.clear,
                    Color(hex: "E86100").opacity(0.045),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.clear,
                    DesignSystem.Colors.ember.opacity(0.02),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var glassEdgeGradient: LinearGradient {
        if colorScheme == .light {
            LinearGradient(
                colors: [
                    Color(hex: "F45B69").opacity(0.22),
                    DesignSystem.Colors.border.opacity(0.55),
                    Color(hex: "E86100").opacity(0.18),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.18),
                    DesignSystem.Colors.border.opacity(0.45),
                    DesignSystem.Colors.border.opacity(0.25),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    var body: some View {
        content()
            .padding(DesignSystem.Spacing.xs)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.55))
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(glassSheenGradient)
                }
            }
            .clipShape(.rect(cornerRadius: DesignSystem.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .strokeBorder(
                        glassEdgeGradient,
                        lineWidth: 0.75
                    )
            )
            .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)
            .scaleEffect(interactive ? (isPressed ? 0.98 : isHovered ? 1.015 : 1.0) : 1.0)
            .animation(isPressed ? DesignSystem.Animation.snappy : DesignSystem.Animation.hover, value: isHovered)
            .animation(DesignSystem.Animation.snappy, value: isPressed)
            .onHover { if interactive { isHovered = $0 } }
            .modifier(InteractiveGlassCardGesture(interactive: interactive, isPressed: $isPressed))
    }
}

// MARK: - Glass Button

struct GlassButton: View {
    enum Style {
        case prominent
        case regular
    }

    let title: String
    let icon: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if style == .prominent {
                prominentLabel
            } else {
                regularLabel
            }
        }
        .buttonStyle(.plain)
    }

    private var prominentLabel: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            Text(title)
                .font(DesignSystem.Typography.caption)
        }
        .foregroundStyle(DesignSystem.Colors.primaryGradient)
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.ember.opacity(0.06))
            }
        }
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [DesignSystem.Colors.ember.opacity(0.4), DesignSystem.Colors.amber.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        )
    }

    private var regularLabel: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            Text(title)
                .font(DesignSystem.Typography.caption)
        }
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.5))
            }
        }
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), DesignSystem.Colors.border.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }
}

// MARK: - Glass Icon Button

struct GlassIconButton<Label: View>: View {
    var isLoading: Bool = false
    let action: () -> Void
    @ViewBuilder private var label: () -> Label

    init(isLoading: Bool = false, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.isLoading = isLoading
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .fill(DesignSystem.Colors.surface.opacity(0.45))
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.1), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if isLoading {
                    AnimatedMiningPickView()
                        .frame(width: 20, height: 20)
                        .clipShape(.circle)
                } else {
                    label()
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(.circle)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.15), DesignSystem.Colors.border.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
            .shadow(color: Color.black.opacity(0.03), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

private enum PopoverTraySection: String, CaseIterable, Identifiable {
    case insights
    case summary
    case providers
    case mercury
    case chat
    case quickSwitch

    var id: String { rawValue }

    var accessibilityLabel: String {
        switch self {
        case .insights:
            return "Insights"
        case .summary:
            return "Summary"
        case .providers:
            return "Providers"
        case .mercury:
            return "Mercury"
        case .chat:
            return "Chat"
        case .quickSwitch:
            return "Quick Switch"
        }
    }
}

#Preview {
    let store = (try? DataStore()) ?? {
        preconditionFailure("Preview requires a valid DataStore - ensure app support directory is writable")
    }()
    let settingsManager = SettingsManager()
    MenuBarPopoverView(
        dataStore: store,
        aggregator: nil,
        quotaService: ProviderQuotaService.shared,
        settingsManager: settingsManager,
        operatingLayer: OpenBurnBarOperatingLayer(dataStore: store),
        onOpenDashboard: {},
        onOpenSettings: {}
    )
}
