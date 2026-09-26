import SwiftUI
import AppKit
import OpenBurnBarUI
import OpenBurnBarAnalytics
import OpenBurnBarKernel

// MARK: - Menu Bar Popover View

struct MenuBarPopoverView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
    /// The first-run reveal is shown once and dismissed by any means. Kept
    /// separate from `hasOnboarded` so the reveal's own lifecycle never
    /// depends on the legacy wizard's completion flag.
    @AppStorage("firstRun.revealDismissed") private var firstRunRevealDismissed = false

    /// The reveal is for people who have never onboarded. `firstRun.revealDismissed`
    /// is absent on every installation that upgraded into this build, so gating on
    /// it ALONE showed the first-run screen instead of the product to existing
    /// users. The legacy `hasOnboarded` flag is the migration signal, consulted
    /// here directly (not just seeded in a task) so there is no window in which
    /// the wrong screen renders.
    private var shouldShowFirstRunReveal: Bool {
        !firstRunRevealDismissed && !hasOnboarded
    }
    @State private var firstRunModel: FirstRunRevealModel?
    @State private var showScanFlash = false
    @State private var listAppeared = false
    @State private var insightSnapshot: WorkflowInsightRollupSnapshot = .unavailable
    @State private var insightRefreshToken = 0
    @State private var hermesChatActive = false
    @State private var isCastingSmartHub = false
    @State private var smartHubCastStatusMessage: String?
    @State private var resizingStartSize: CGSize?
    @State private var hoveredSectionID: String?
    @State private var intrinsicTraySectionHeights: [String: CGFloat] = [:]
    @State private var activeTrayResizeSection: String?
    @State private var activeTrayResizeStartHeight: CGFloat = 0
    @State private var isHoveringResizeHandle = false
    @State private var resizeHandleCursorPushed = false
    @StateObject private var cloudEntitlement = MacCloudEntitlementStore.shared
    @State private var pendingDeviceApproval = PendingDeviceApprovalModel()

    @AppStorage("popoverTrayWidth") private var storedPopoverTrayWidth = 340.0
    @AppStorage("popoverTrayHeight") private var storedPopoverTrayHeight = 540.0
    @AppStorage("popoverTraySectionOrder") private var storedPopoverTraySectionOrder = ""
    @AppStorage("popoverTraySectionHeights") private var storedPopoverTraySectionHeightsJSON = "{}"
    @AppStorage("hasResetScrambledPopoverLayoutV2") private var hasResetScrambledPopoverLayoutV2 = false
    @AppStorage(LiquidGlassTransparency.storageKey) private var rawGlassTransparency: Double = 0

    private static let minTraySectionHeight: CGFloat = 80
    private static let maxTraySectionHeight: CGFloat = 720

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
        Analytics.shared.track(.menubarAction, ["action": "scan"])
        Task { await agg.refreshAll() }
    }

    private func runRecount() {
        guard let agg = aggregator else { return }
        Analytics.shared.track(.menubarAction, ["action": "recount"])
        Task { await agg.recountAll() }
    }

    private func refreshInsightRollups() {
        // Snapshot building runs off the main actor (popover open,
        // usagesVersion ticks, and scan completion all land here). The
        // token keeps a slower older snapshot from overwriting a newer one.
        insightRefreshToken &+= 1
        let token = insightRefreshToken
        let service = WorkflowInsightRollupService(dataStore: dataStore)
        Task {
            let snapshot = await service.snapshotAsync(refreshIfStale: true)
            guard token == insightRefreshToken else { return }
            insightSnapshot = snapshot
        }
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
        Analytics.shared.track(.menubarAction, ["action": "smartdisplay_cast"])
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
            // The first-run reveal. Gated ONLY on its own dismissal flag: the
            // old gate also required `totalUsageSessionCount == 0`, so the
            // moment the scan found anything the onboarding vanished forever —
            // hiding the screen exactly when it finally had something true to
            // say. Finding data is the reveal's best case, not its exit.
            if shouldShowFirstRunReveal, let firstRunModel {
                FirstRunReveal(
                    model: firstRunModel,
                    detectedProviders: firstRunDetectedProviders,
                    onOpenQuotaWorkspace: {
                        // Same path a tapped quota notification takes:
                        // `AppCommandRouter.handle` is the router's only entry
                        // point, and `openburnbar://quota` is already wired
                        // through `NavigationCoordinator.handleDeepLink`.
                        if let url = URL(string: "openburnbar://quota") {
                            AppCommandRouter.shared.handle(url)
                        }
                        onOpenDashboard()
                    },
                    onSetUpAlerts: {
                        firstRunRevealDismissed = true
                        dismiss()
                        onOpenSettings()
                    },
                    onShowPathAudit: {
                        dismiss()
                        onOpenOnboardingWizard?()
                    },
                    onWatchForFirstSession: { firstRunRevealDismissed = true },
                    onDismiss: { firstRunRevealDismissed = true }
                )
                .task { await driveFirstRunReveal(firstRunModel) }
            } else if shouldShowFirstRunReveal {
                // Construct on first appearance so the "I looked in N places"
                // count is read live from the registry rather than hardcoded.
                Color.clear
                    .frame(width: 340, height: 1)
                    .onAppear {
                        firstRunModel = FirstRunRevealModel(
                            searchedPathCount: ParserRegistry.defaultParsers().count
                        )
                    }
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
                    #if !DISTRIBUTION_MAS
                    UpdateBannerCard(compact: true, horizontalInset: DesignSystem.Spacing.sm, topInset: DesignSystem.Spacing.xs)
                        .frame(width: popoverWidth)
                    #endif
                    PendingDeviceApprovalBanner(
                        model: pendingDeviceApproval,
                        compact: true,
                        horizontalInset: DesignSystem.Spacing.sm,
                        topInset: DesignSystem.Spacing.xs,
                        onOpenSettings: {
                            SettingsDeepLinkRouting.route(to: "devices.trusted")
                            dismiss()
                            onOpenSettings()
                        }
                    )
                        .frame(width: popoverWidth)
                    popoverDivider

                    QuotaPopoverBar(
                        quotaService: quotaService ?? ProviderQuotaService.shared,
                        settingsManager: settingsManager,
                        dataStore: dataStore,
                        onCustomizeQuotas: {
                            SettingsDeepLinkRouting.routeToQuotaDisplay()
                            dismiss()
                            onOpenSettings()
                        }
                    )
                    popoverDivider

                    ScrollView(.vertical, showsIndicators: true) {
                        trayContent
                    }
                    .frame(width: popoverWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .clipped()

                    popoverDivider
                    if cloudEntitlement.currentTier == .free {
                        cloudWhisperStrip
                        popoverDivider
                    }
                    actionBar
                }
            }
        }
        .frame(width: popoverWidth)
        .frame(height: popoverViewportHeight)
        .background(popoverRootSurface)
        .clipShape(
            RoundedRectangle(cornerRadius: 22, style: .continuous),
            style: FillStyle(antialiased: true)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(popoverEdgeColor, lineWidth: 0.75)
        }
        .accessibilityIdentifier(OBBAccessibilityID.popoverRoot)
        .overlay(alignment: .bottomTrailing) {
            resizeHandle
        }
        .onChange(of: isScanning) { oldValue, newValue in
            guard oldValue, !newValue else { return }
            refreshInsightRollups()
            // Only flash success when the scan actually succeeded — flashing
            // green over a failed parse/persist masks the failure.
            guard scanIssues.isEmpty else { return }
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
            cloudEntitlement.start()
            Task { @MainActor in
                listAppeared = true
                refreshInsightRollups()
                await pendingDeviceApproval.refresh()
                await operatingLayer.refreshControllerRuntime()
                // Auto-open chat view if Hermes is actively streaming or has an active conversation
                if let ctrl = chatController,
                   ctrl.isStreaming || !ctrl.messages.isEmpty {
                    hermesChatActive = true
                }
            }
        }
        .onChange(of: dataStore.usagesVersion) { _, _ in
            refreshInsightRollups()
        }
        .onDisappear {
            if resizeHandleCursorPushed {
                NSCursor.pop()
                resizeHandleCursorPushed = false
            }
        }
        .openBurnBarPreferredColorScheme(settingsManager.preferredSwiftUIColorScheme)
        .environment(settingsManager)
    }

    @ViewBuilder
    private var popoverRootSurface: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if reduceTransparency {
            shape.fill(DesignSystem.Colors.background)
        } else {
            ZStack {
                shape.fill(
                    colorScheme == .dark
                        ? Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.92)
                        : Color(red: 0.98, green: 0.98, blue: 0.99).opacity(0.94)
                )
                shape.fill(.ultraThinMaterial)
            }
        }
    }

    private var popoverEdgeColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.18)
            : Color.black.opacity(0.14)
    }

    private var popoverEmbeddedSurface: Color {
        let opacity = isClearPopoverGlass ? 0.010 : 0.025
        return colorScheme == .dark
            ? Color.white.opacity(opacity)
            : Color.black.opacity(opacity * 0.72)
    }

    private var isClearPopoverGlass: Bool {
        LiquidGlassTransparency.usesClearGlass(
            LiquidGlassTransparency.effective(
                rawGlassTransparency,
                reduceTransparency: reduceTransparency
            )
        )
    }

    private var popoverDivider: some View {
        Rectangle()
            .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.09))
            .frame(height: 0.5)
            .padding(.horizontal, 12)
    }

    // MARK: - First Run Reveal

    /// Detected agents, rendered as the scan's row list. Comes straight from
    /// `detectAvailableProviders()`, which resolves in milliseconds because the
    /// session files are already on disk — the whole structural advantage this
    /// screen exists to spend.
    private var firstRunDetectedProviders: [FirstRunReveal.DetectedProvider] {
        settingsManager.detectAvailableProviders()
            .filter(\.value)
            .keys
            .sorted { $0.displayName < $1.displayName }
            .prefix(4)
            .map { provider in
                FirstRunReveal.DetectedProvider(
                    displayName: provider.displayName,
                    path: provider.logDirectory,
                    state: .resolved
                )
            }
    }

    /// Feeds the reveal real data and holds the 8-second ceiling. Polls rather
    /// than observes because the first pass is genuinely racing the scan: the
    /// aggregator, the quota service and the parse watermark all settle
    /// independently, and the reveal must show the best true thing at each
    /// moment without waiting for the slowest of them.
    /// Hard ceiling for a still-running first scan. The 8s deadline ends the
    /// SPINNER; this ends the WAIT, so a pathologically slow corpus still
    /// resolves the screen instead of spinning forever.
    private static let firstRunScanHardCeiling: TimeInterval = 60

    private func driveFirstRunReveal(_ model: FirstRunRevealModel) async {
        let startedAt = Date()
        let service = quotaService ?? ProviderQuotaService.shared

        while model.didReachTerminalPhase == false {
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed >= FirstRunRevealModel.degradeAfter {
                // `.empty` asserts "nothing on this Mac has burned a token" AND
                // stops polling permanently. Saying that while the scan is still
                // reading is a confident lie the screen can never take back, so a
                // live scan keeps the reveal alive up to the hard ceiling.
                if dataStore.isLoading == false || elapsed >= Self.firstRunScanHardCeiling {
                    model.degrade()
                    return
                }
            }

            model.reportProgress(fraction: min(elapsed / FirstRunRevealModel.degradeAfter, 0.95))
            model.ingest(
                snapshots: Array(service.snapshotsByProvider.values),
                monthToDateUSD: dataStore.totalCostThisMonth,
                sessionCount: dataStore.totalUsageSessionCount,
                detectedProviderDisplayNames: firstRunDetectedProviders.map(\.displayName)
            )

            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: - Tray Layout

    private var trayContent: some View {
        VStack(spacing: 0) {
            let sections = orderedTraySections
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                traySection(section)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: customTrayHeight(for: section), alignment: .top)
                    .clipped()
                    .background(traySectionIntrinsicMeasurement(for: section))
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
                resizableTrayDivider(for: section, showsLine: index < sections.count - 1)
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
                settingsManager: settingsManager,
                accountManager: runtimeContext?.accountManager ?? .shared
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

            if customTrayHeight(for: section) != nil {
                Button {
                    withAnimation(DesignSystem.Animation.snappy) {
                        setCustomTrayHeight(nil, for: section)
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .accessibilityLabel("Reset \(section.accessibilityLabel) height")
                .popoverTooltip("Reset \(section.accessibilityLabel) height")
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.72))
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .frame(height: 22)
        .background(
            (colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(DesignSystem.Colors.borderSubtle.opacity(0.7), lineWidth: 0.5)
        )
        .padding(.top, 3)
        .padding(.trailing, 4)
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(
                isHoveringResizeHandle || resizingStartSize != nil
                    ? DesignSystem.Colors.ember.opacity(0.9)
                    : DesignSystem.Colors.textMuted.opacity(0.55)
            )
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(
                        isHoveringResizeHandle || resizingStartSize != nil
                            ? (colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                            : Color.clear
                    )
            )
            .overlay {
                if isHoveringResizeHandle || resizingStartSize != nil {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .strokeBorder(DesignSystem.Colors.ember.opacity(0.35), lineWidth: 0.75)
                }
            }
            .contentShape(.rect)
            .animation(DesignSystem.Animation.hover, value: isHoveringResizeHandle)
            .animation(DesignSystem.Animation.hover, value: resizingStartSize != nil)
            .onHover { hovering in
                isHoveringResizeHandle = hovering
                updateResizeHandleCursor(show: hovering || resizingStartSize != nil)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if resizingStartSize == nil {
                            resizingStartSize = CGSize(width: popoverWidth, height: popoverViewportHeight)
                            updateResizeHandleCursor(show: true)
                        }
                        let start = resizingStartSize ?? CGSize(width: popoverWidth, height: popoverViewportHeight)
                        storedPopoverTrayWidth = Double(clampPopoverWidth(start.width + value.translation.width))
                        storedPopoverTrayHeight = Double(clampPopoverHeight(start.height + value.translation.height))
                    }
                    .onEnded { _ in
                        resizingStartSize = nil
                        clampStoredPopoverSize()
                        updateResizeHandleCursor(show: isHoveringResizeHandle)
                    }
            )
            .accessibilityLabel("Resize popover tray")
            .popoverTooltip("Drag to resize")
            .padding(2)
    }

    private func updateResizeHandleCursor(show: Bool) {
        if show {
            if !resizeHandleCursorPushed {
                NSCursor.pointingHand.push()
                resizeHandleCursorPushed = true
            }
        } else {
            if resizeHandleCursorPushed {
                NSCursor.pop()
                resizeHandleCursorPushed = false
            }
        }
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

    // MARK: - Per-section resize

    private var traySectionHeights: [String: CGFloat] {
        guard let data = storedPopoverTraySectionHeightsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        var result: [String: CGFloat] = [:]
        for (key, value) in decoded {
            result[key] = CGFloat(value)
        }
        return result
    }

    private func customTrayHeight(for section: PopoverTraySection) -> CGFloat? {
        traySectionHeights[section.rawValue].map { clampTraySectionHeight($0) }
    }

    private func setCustomTrayHeight(_ height: CGFloat?, for section: PopoverTraySection) {
        var dict: [String: Double] = [:]
        for (key, value) in traySectionHeights {
            dict[key] = Double(value)
        }
        if let height {
            dict[section.rawValue] = Double(clampTraySectionHeight(height))
        } else {
            dict.removeValue(forKey: section.rawValue)
        }
        if let data = try? JSONEncoder().encode(dict),
           let json = String(data: data, encoding: .utf8) {
            storedPopoverTraySectionHeightsJSON = json
        }
    }

    private func clampTraySectionHeight(_ height: CGFloat) -> CGFloat {
        min(max(height, Self.minTraySectionHeight), Self.maxTraySectionHeight)
    }

    private func resizeStartHeight(for section: PopoverTraySection) -> CGFloat {
        customTrayHeight(for: section)
            ?? intrinsicTraySectionHeights[section.rawValue]
            ?? 200
    }

    @ViewBuilder
    private func traySectionIntrinsicMeasurement(for section: PopoverTraySection) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    let measured = proxy.size.height
                    guard measured > 0, customTrayHeight(for: section) == nil else { return }
                    intrinsicTraySectionHeights[section.rawValue] = measured
                }
                .onChange(of: proxy.size.height) { _, newHeight in
                    guard newHeight > 0, customTrayHeight(for: section) == nil else { return }
                    intrinsicTraySectionHeights[section.rawValue] = newHeight
                }
        }
    }

    @ViewBuilder
    private func resizableTrayDivider(for section: PopoverTraySection, showsLine: Bool) -> some View {
        ResizableTraySectionDivider(
            showsLine: showsLine,
            hasCustomHeight: customTrayHeight(for: section) != nil,
            sectionLabel: section.accessibilityLabel,
            onResizeChanged: { translationY in
                if activeTrayResizeSection != section.rawValue {
                    activeTrayResizeSection = section.rawValue
                    activeTrayResizeStartHeight = resizeStartHeight(for: section)
                }
                let newHeight = clampTraySectionHeight(activeTrayResizeStartHeight + translationY)
                setCustomTrayHeight(newHeight, for: section)
            },
            onResizeEnded: {
                activeTrayResizeSection = nil
            },
            onReset: {
                withAnimation(DesignSystem.Animation.snappy) {
                    setCustomTrayHeight(nil, for: section)
                }
            }
        )
    }

    // MARK: - Header

    private var hasWeeklyUsage: Bool {
        // Presence must follow the metric shown in the headline so currency
        // mode never reads "Burning $0.00" from token-only weeks (and vice versa).
        switch settingsManager.usageDisplayMode {
        case .currency:
            return dataStore.totalCostThisWeek > 0
        case .tokens:
            return dataStore.totalTokensThisWeek > 0
        }
    }

    private var burnHeadlineTitle: String {
        PopoverHeaderCopy.burnTitle(
            metric: settingsManager.formatUsageMetric(
                cost: dataStore.totalCostThisWeek,
                tokens: dataStore.totalTokensThisWeek
            ),
            hasUsage: hasWeeklyUsage
        )
    }

    private var burnHeadlineSubtitle: String? {
        PopoverHeaderCopy.burnSubtitle(hasUsage: hasWeeklyUsage, mode: settingsManager.usageDisplayMode)
    }

    private var showsProBadge: Bool {
        cloudEntitlement.currentTier != .free
    }

    private var headerView: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            AppLogoView(size: 28)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(burnHeadlineTitle)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .contentTransition(.numericText(countsDown: false))
                        .animation(DesignSystem.Animation.gentle, value: burnHeadlineTitle)

                    if showsProBadge {
                        ProBadgePill()
                    }
                }

                if let burnHeadlineSubtitle {
                    Text(burnHeadlineSubtitle)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

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

            GlassIconButton {
                withAnimation(DesignSystem.Animation.snappy) {
                    rawGlassTransparency = isClearPopoverGlass ? 0 : 1
                }
            } label: {
                Image(systemName: isClearPopoverGlass ? "drop.fill" : "drop")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        isClearPopoverGlass
                            ? DesignSystem.Colors.whimsy
                            : DesignSystem.Colors.textSecondary
                    )
            }
            .popoverTooltip(isClearPopoverGlass ? "Use frosted glass" : "Use clear liquid glass")
            .accessibilityLabel(isClearPopoverGlass ? "Use frosted glass" : "Use clear liquid glass")
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(
            popoverEmbeddedSurface
                .overlay(DesignSystem.Colors.success.opacity(showScanFlash ? 0.08 : 0))
        )
    }

    // MARK: - Freshness Bar

    /// Scan problems the user must be able to see: a broken parser or a
    /// failed DB write otherwise looks identical to a clean scan while
    /// totals silently go stale.
    private var scanIssues: [String] {
        guard let agg = aggregator else { return [] }
        var issues: [String] = []
        if let persistence = agg.persistenceErrorMessage, !persistence.isEmpty {
            issues.append("Couldn't save scanned usage: \(persistence)")
        }
        if let importError = agg.parserImportError, !importError.isEmpty {
            issues.append("Import issue: \(importError)")
        }
        for (provider, message) in agg.errors.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            issues.append("\(provider.displayName): \(message)")
        }
        return issues
    }

    private func freshnessColor(at now: Date) -> Color {
        guard let last = lastRefreshDate else { return DesignSystem.Colors.textMuted }
        let elapsed = now.timeIntervalSince(last)
        if elapsed < 60 { return DesignSystem.Colors.success }
        if elapsed < 900 { return DesignSystem.Colors.textSecondary }
        return DesignSystem.Colors.warning
    }

    /// "Auto" while the aggregator refreshes on its timer, "Manual" when the
    /// interval is disabled — mirrors the menu bar's refresh mode label.
    private var refreshModeLabel: String {
        settingsManager.refreshInterval > 0 ? "Auto" : "Manual"
    }

    /// Absolute last-scan timestamp ("8/8/26, 5:53 PM") — glanceable without
    /// mental relative-time math.
    private var lastRefreshLabel: String {
        guard let last = lastRefreshDate else { return "Not scanned yet" }
        return last.formatted(date: .numeric, time: .shortened)
    }

    /// The old freshness strip's secondary numbers, folded into a tooltip so
    /// the footer stays one calm line.
    private var freshnessTooltip: String {
        var lines: [String] = []
        if dataStore.totalUsageSessionCount > 0 {
            lines.append("Today: \(settingsManager.formatUsageMetric(cost: dataStore.totalCostToday, tokens: dataStore.totalTokensToday))")
            lines.append("\(dataStore.totalUsageSessionCount.formatted()) sessions imported")
        }
        if let last = lastRefreshDate {
            lines.append("Last scan \(last.formatted(date: .abbreviated, time: .shortened))")
        }
        return lines.isEmpty ? "No scan yet" : lines.joined(separator: "\n")
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

            MiniSparkline(
                data: menuBarSparklineSeries,
                width: max(popoverWidth - (DesignSystem.Spacing.lg * 2), 240),
                height: 54
            )
            .popoverTooltip("7-day spending trend")

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
                MiniSparkline(
                    data: menuBarSparklineSeries,
                    accessibilityTitle: "7-day spending trend",
                    accessibilityValueFormatter: { String(format: "$%.2f", $0) }
                )
                .popoverTooltip("7-day spending trend")
            }
        }
        .padding(DesignSystem.Spacing.lg)
    }

    // MARK: - Provider List

    private var providerListView: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("PROVIDERS")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
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
                        .accessibilityIdentifier(OBBAccessibilityID.providersRow(summary.provider.providerID.rawValue))
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
        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(freshnessColor(at: context.date))
                    .frame(width: 6, height: 6)
                    .popoverTooltip("Data freshness indicator")

                Text(refreshModeLabel)
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Text(isScanning ? "Scanning..." : lastRefreshLabel)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
                    .popoverTooltip(freshnessTooltip)

                if !scanIssues.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text(scanIssues.count == 1 ? "1 scan issue" : "\(scanIssues.count) scan issues")
                            .font(DesignSystem.Typography.tiny)
                    }
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .popoverTooltip(scanIssues.joined(separator: "\n"))
                    .accessibilityLabel("Scan issues: \(scanIssues.joined(separator: ". "))")
                }

                Spacer(minLength: 0)

                BurnBarProfileAvatarButton(
                    size: .toolbar,
                    onOpenDashboard: {
                        Analytics.shared.track(.menubarAction, ["action": "open_dashboard"])
                        dismiss()
                        onOpenDashboard()
                    },
                    onOpenSettings: {
                        dismiss()
                        onOpenSettings()
                    },
                    onOpenSettingsTab: { tab in
                        dismiss()
                        UserDefaults.standard.set(tab.rawValue, forKey: SettingsDeepLinkRouting.pendingTabKey)
                        onOpenSettings()
                    },
                    isScanning: isScanning,
                    onImport: { runScan() },
                    onRecount: { runRecount() },
                    canRunRecount: aggregator != nil && !isScanning,
                    onCastSmartDisplay: { castSmartHubFromTray() },
                    isCastingSmartDisplay: isCastingSmartHub,
                    mtdSpendFormatted: burnHeadlineTitle
                )
                .popoverTooltip("Profile, Dashboard, and Quick Settings")
                .accessibilityIdentifier(OBBAccessibilityID.popoverSettingsButton)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, DesignSystem.Spacing.sm + 2)
            .background(popoverEmbeddedSurface)
        }
    }

    // MARK: - App Store Review Compliance
    // App Store Guideline 2.1 visible quit command compliance:
    // The floating profile menu hosts the standard visible Quit command:
    // GlassButton(title: "Quit OpenBurnBar", icon: "power", style: .cool) { NSApplication.shared.terminate(nil) }

}
