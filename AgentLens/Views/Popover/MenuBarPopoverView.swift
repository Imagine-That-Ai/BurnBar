import SwiftUI
import AppKit

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
                        onOpenSettings: onOpenSettings
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

// MARK: - Header Copy

/// Popover header strings as pure functions so the exact copy stays
/// unit-testable.
enum PopoverHeaderCopy {
    /// "Burning 52.4M" while usage flows; falls back to the app name before
    /// the first scan so the header never reads "Burning 0".
    static func burnTitle(metric: String, hasUsage: Bool) -> String {
        hasUsage ? "Burning \(metric)" : "OpenBurnBar"
    }

    /// Units line under the burn title — "tokens per week" in token mode,
    /// "per week" in currency mode. Nil until there's usage to describe.
    static func burnSubtitle(hasUsage: Bool, mode: UsageDisplayMode) -> String? {
        guard hasUsage else { return nil }
        switch mode {
        case .tokens: return "tokens per week"
        case .currency: return "per week"
        }
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var theme: ProviderTheme { ProviderTheme.theme(for: summary.provider) }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                Circle()
                    .fill(theme.primaryColor.opacity(0.15))
                    .frame(width: 28, height: 28)

                ProviderLogoView(provider: summary.provider, size: 16, useFallbackColor: false)
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
                .foregroundStyle(quotaLegibleProviderColor(theme.primaryColor, in: colorScheme))
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(isHovered
                    ? (colorScheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.035))
                    : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hover) {
                isHovered = hovering
            }
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
    var embedded: Bool = false
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(LiquidGlassTransparency.storageKey) private var rawGlassTransparency: Double = 0

    @State private var isHovered = false
    @State private var isPressed = false

    init(
        interactive: Bool = false,
        embedded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.interactive = interactive
        self.embedded = embedded
        self.content = content
    }

    /// Light mode: ember + Spanish orange sheen instead of neutral white.
    private var glassSheenGradient: LinearGradient {
        if colorScheme == .light {
            LinearGradient(
                colors: [
                    Color(hex: "F45B69").opacity(0.07),
                    Color.clear,
                    Color(hex: "E86100").opacity(0.045)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.clear,
                    DesignSystem.Colors.ember.opacity(0.02)
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
                    Color(hex: "E86100").opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.18),
                    DesignSystem.Colors.border.opacity(0.45),
                    DesignSystem.Colors.border.opacity(0.25)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
        content()
            .padding(DesignSystem.Spacing.xs)
            .background { backgroundLayer }
            .clipShape(shape, style: FillStyle(antialiased: true))
            .overlay(
                shape
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

    @ViewBuilder
    private var backgroundLayer: some View {
        let shape = RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
        if embedded {
            shape.fill(
                colorScheme == .dark
                    ? Color.white.opacity(isHovered ? 0.085 : 0.055)
                    : Color.black.opacity(isHovered ? 0.065 : 0.035)
            )
        } else if reduceTransparency {
            shape.fill(DesignSystem.Colors.surface)
        } else if #available(macOS 26, *) {
            // Native Liquid Glass samples the content BEHIND it — a material
            // fill underneath would block the refraction and read as frosted
            // plastic. The warm sheen survives as a faint wash riding on top
            // of pure glass.
            let t = LiquidGlassTransparency.effective(rawGlassTransparency, reduceTransparency: reduceTransparency)
            shape
                .fill(glassSheenGradient)
                .opacity(LiquidGlassTransparency.fallbackPlateOpacity(t))
                .liquidGlassEffect(
                    interactive ? .regular.interactive() : .regular,
                    in: shape
                )
        } else {
            // Pre-26 plate honors the glass transparency preference the same
            // way the shared adapters do: the material fades toward the raw
            // backdrop for "clearer", a thick frost scrim rises for "frostier".
            let t = LiquidGlassTransparency.effective(rawGlassTransparency, reduceTransparency: reduceTransparency)
            ZStack {
                shape.fill(.ultraThinMaterial)
                    .opacity(LiquidGlassTransparency.fallbackPlateOpacity(t))
                shape.fill(DesignSystem.Colors.surface.opacity(0.55 * LiquidGlassTransparency.fallbackPlateOpacity(t)))
                shape.fill(.thickMaterial)
                    .opacity(LiquidGlassTransparency.frostScrimOpacity(t))
                shape.fill(glassSheenGradient)
            }
        }
    }
}

// MARK: - Glass Button

struct GlassButton: View {
    enum Style {
        /// Dashboard — warm ember, the app running hot.
        case prominent
        /// Settings — neutral glass.
        case regular
        /// Quit — the ember logo cooling to ice and draining away.
        case cool
    }

    let title: String
    let icon: String
    let style: Style
    let action: () -> Void

    @AppStorage(LiquidGlassTransparency.storageKey) private var rawGlassTransparency: Double = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var isHovered = false
    @State private var isPressed = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.xs + 1) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(DesignSystem.Typography.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.Spacing.sm + 1)
            .padding(.horizontal, DesignSystem.Spacing.xs)
            .background(background)
            .clipShape(shape)
            .overlay(border)
            .shadow(color: glowColor.opacity(isHovered ? 0.35 : 0), radius: isHovered ? 9 : 0, y: 2)
        }
        .buttonStyle(.plain)
        .contentShape(shape)
        .scaleEffect(isPressed ? 0.97 : (isHovered ? 1.025 : 1.0))
        .animation(isPressed ? DesignSystem.Animation.snappy : DesignSystem.Animation.hover, value: isHovered)
        .animation(DesignSystem.Animation.snappy, value: isPressed)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    // MARK: - Per-style theming

    private var foreground: AnyShapeStyle {
        switch style {
        case .prominent: return AnyShapeStyle(DesignSystem.Colors.primaryGradient)
        case .regular:   return AnyShapeStyle(DesignSystem.Colors.textSecondary)
        case .cool:      return AnyShapeStyle(DesignSystem.Colors.coolDownGradient)
        }
    }

    @ViewBuilder
    private var background: some View {
        if #available(macOS 26, *) {
            // Style wash rides on interactive glass; the material + neutral
            // surface base fills stay pre-26 only (nothing sits under glass).
            styleWash.liquidGlassEffect(.regular.interactive(), in: shape)
        } else {
            let t = LiquidGlassTransparency.effective(rawGlassTransparency, reduceTransparency: reduceTransparency)
            ZStack {
                shape.fill(.ultraThinMaterial)
                    .opacity(LiquidGlassTransparency.fallbackPlateOpacity(t))
                shape.fill(.thickMaterial)
                    .opacity(LiquidGlassTransparency.frostScrimOpacity(t))
                switch style {
                case .prominent:
                    shape.fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                case .regular, .cool:
                    shape.fill(DesignSystem.Colors.surface.opacity(0.5))
                }
                styleWash
            }
        }
    }

    @ViewBuilder
    private var styleWash: some View {
        switch style {
        case .prominent:
            shape.fill(DesignSystem.Colors.ember.opacity(isHovered ? 0.12 : 0.06))
        case .regular:
            shape.fill(Color.white.opacity(isHovered ? 0.05 : 0))
        case .cool:
            // The cool wash drains downward — frost at the top fading to navy below.
            shape.fill(
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.frost.opacity(isHovered ? 0.18 : 0.09),
                        DesignSystem.Colors.abyss.opacity(isHovered ? 0.22 : 0.11)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    @ViewBuilder
    private var border: some View {
        switch style {
        case .prominent:
            shape.strokeBorder(
                LinearGradient(
                    colors: [DesignSystem.Colors.ember.opacity(0.4), DesignSystem.Colors.amber.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.75
            )
        case .regular:
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.12), DesignSystem.Colors.border.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.5
            )
        case .cool:
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.frost.opacity(isHovered ? 0.7 : 0.5),
                        DesignSystem.Colors.abyss.opacity(0.35)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.75
            )
        }
    }

    private var glowColor: Color {
        switch style {
        case .prominent: return DesignSystem.Colors.ember
        case .regular:   return Color.white
        case .cool:      return DesignSystem.Colors.glacier
        }
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
            .liquidGlassInteractive(in: .circle, fallback: .ultraThinMaterial)
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

private struct ResizableTraySectionDivider: View {
    var showsLine: Bool
    var hasCustomHeight: Bool
    var sectionLabel: String
    var onResizeChanged: (CGFloat) -> Void
    var onResizeEnded: () -> Void
    var onReset: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isDragging = false
    @State private var cursorPushed = false

    var body: some View {
        ZStack {
            // Visual elements
            ZStack {
                if showsLine {
                    Rectangle()
                        .fill(
                            isHovered || isDragging
                                ? DesignSystem.Colors.ember.opacity(0.35)
                                : (colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.09))
                        )
                        .frame(height: 0.5)
                        .padding(.horizontal, 12)
                }
                if isHovered || isDragging {
                    Capsule()
                        .fill(handleColor)
                        .frame(width: 36, height: 3)
                        .overlay(
                            Capsule()
                                .strokeBorder(DesignSystem.Colors.ember.opacity(isDragging ? 0.55 : 0.28), lineWidth: 0.5)
                        )
                        .transition(.opacity)
                }
            }
            .frame(height: 8)

            // Taller, invisible interactive hit zone
            Color.clear
                .frame(height: 24) // 24 points is generous and very easy to target
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(DesignSystem.Animation.hover) {
                        isHovered = hovering
                    }
                    updateCursor(showResize: hovering)
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                updateCursor(showResize: true)
                            }
                            onResizeChanged(value.translation.height)
                        }
                        .onEnded { _ in
                            isDragging = false
                            onResizeEnded()
                            if !isHovered {
                                updateCursor(showResize: false)
                            }
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        if hasCustomHeight {
                            onReset()
                        }
                    }
                )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 8) // Layout height remains exactly 8
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Resize \(sectionLabel) section")
        .accessibilityHint(hasCustomHeight
            ? "Drag to resize. Double-tap to reset to natural height."
            : "Drag to resize.")
        .popoverTooltip(hasCustomHeight
            ? "Drag to resize • Double-click to reset"
            : "Drag to resize")
        .onDisappear {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
    }

    private var handleColor: Color {
        isDragging
            ? DesignSystem.Colors.ember.opacity(0.85)
            : DesignSystem.Colors.ember.opacity(0.55)
    }

    private func updateCursor(showResize: Bool) {
        if showResize {
            if !cursorPushed {
                NSCursor.resizeUpDown.push()
                cursorPushed = true
            }
        } else {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
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

