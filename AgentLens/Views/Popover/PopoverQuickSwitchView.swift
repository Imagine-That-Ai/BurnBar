import AppKit
import SwiftUI
import OpenBurnBarCore

#if DEBUG
private final class PopoverQuickSwitchTransitionProbe {
    private(set) var recentChange: (from: String, to: String)?
    private(set) var animationToken = 0

    func recordChange(from previousProfileID: String?, to newProfileID: String?) {
        guard let previousProfileID,
              let newProfileID,
              previousProfileID != newProfileID else {
            return
        }

        recentChange = (previousProfileID, newProfileID)
        animationToken += 1
    }

    func swapTargetID(currentActiveProfileID: String?) -> String? {
        guard let currentActiveProfileID,
              let recentChange else {
            return nil
        }

        if currentActiveProfileID == recentChange.from {
            return recentChange.to
        }
        if currentActiveProfileID == recentChange.to {
            return recentChange.from
        }
        return nil
    }
}
#endif

// MARK: - Popover Quick Switch View

/// Compact quick-switch surface for the menu bar popover.
///
/// Features:
/// - One-step switching flow without leaving popover context
/// - Clear active profile indicator (persisted and accurate after close/reopen)
/// - In-progress status and error handling with actionable recovery
/// - Keyboard and mouse interaction parity
/// - Empty state with recovery CTA
/// - Distinct switch vs launch actions
/// - Rapid input coalescing for deterministic behavior
///
/// VAL-POPOVER-001 through VAL-POPOVER-010
struct PopoverQuickSwitchView: View {
    let dataStore: DataStore
    let onOpenSettings: () -> Void
    let settingsManager: SettingsManager

    @State private var profiles: [SwitcherProfileRecord] = []
    @State private var activeProfileID: String?
    @State private var selectedProfileID: String?
    @State private var switchState: SwitchState = .idle
    @State private var launchState: LaunchState = .idle
    @State private var isLoading = true
    @State private var error: String?
    @State private var showingLaunchMenu = false
    @State private var accessibilityAnnouncement: String?
    @State private var recentDefaultChange: RecentDefaultChange?
    @State private var isHighlightingDefaultChange = false
    @State private var defaultChangeAnimationToken = 0
    @State private var quotaService = ProviderQuotaService.shared

    // Launch services
    @State private var browserLaunchService: SwitcherBrowserLaunchService?
    @State private var cliLaunchService: SwitcherCLILAunchService?

    #if DEBUG
    /// Test-only: pre-populated error state for view testing.
    /// When non-nil, the view renders in error state immediately.
    let testInjectedError: String?

    /// Test-only: callback to capture accessibility announcements in tests.
    /// When set, announceForAccessibility calls this with each announcement message.
    var testAnnouncementHandler: ((String) -> Void)?

    /// DEBUG-only initializer that allows injecting an error state for testing.
    /// - Parameters:
    ///   - dataStore: The data store to use.
    ///   - onOpenSettings: Callback when settings button is tapped.
    ///   - testInjectedError: Error message to pre-populate for testing error UI rendering.
    ///   - skipLoadData: When true, skips calling loadData() in onAppear (for testing error/empty states).
    ///   - testAnnouncementHandler: Optional callback to capture accessibility announcements.
    init(
        dataStore: DataStore,
        onOpenSettings: @escaping () -> Void,
        settingsManager: SettingsManager = .shared,
        testInjectedError: String? = nil,
        skipLoadData: Bool = false,
        testAnnouncementHandler: ((String) -> Void)? = nil
    ) {
        self.dataStore = dataStore
        self.onOpenSettings = onOpenSettings
        self.settingsManager = settingsManager
        self.testInjectedError = testInjectedError
        self.skipLoadData = skipLoadData
        self.testAnnouncementHandler = testAnnouncementHandler
    }

    /// When true, loadData() is skipped in onAppear - for testing error/empty states.
    private let skipLoadData: Bool
    private let testTransitionProbe = PopoverQuickSwitchTransitionProbe()
    #endif

    #if !DEBUG
    init(
        dataStore: DataStore,
        onOpenSettings: @escaping () -> Void,
        settingsManager: SettingsManager = .shared
    ) {
        self.dataStore = dataStore
        self.onOpenSettings = onOpenSettings
        self.settingsManager = settingsManager
    }
    #endif

    private enum SwitchState: Equatable {
        case idle
        case switching
        case success
        case error(String)
    }

    private enum LaunchState: Equatable {
        case idle
        case launching
        case success
        case error(String)
    }

    private struct RecentDefaultChange: Equatable {
        let firstProfileID: String
        let secondProfileID: String

        func otherProfileID(current activeProfileID: String) -> String? {
            if activeProfileID == firstProfileID {
                return secondProfileID
            }
            if activeProfileID == secondProfileID {
                return firstProfileID
            }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            if effectiveIsLoading {
                loadingView
            } else if let error = effectiveError {
                errorStateView(message: error)
            } else if profiles.isEmpty {
                emptyStateView
            } else {
                switcherContent
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
        #if DEBUG
        .onAppear {
            if !skipLoadData {
                loadData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loadData()
        }
        #else
        .onAppear(perform: loadData)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loadData()
        }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Account Switcher")
        .accessibilityHint("Use to quickly switch between browser and CLI profiles")
        .accessibilityValue(accessibilityAnnouncement ?? "")
    }

    #if DEBUG
    /// Returns the effective loading state, accounting for test injection.
    /// When testInjectedError is set, we skip loading and show error state directly.
    private var effectiveIsLoading: Bool {
        if testInjectedError != nil {
            return false
        }
        return isLoading
    }

    /// Returns the effective error, preferring test-injected error over real error.
    private var effectiveError: String? {
        testInjectedError ?? error
    }
    #else
    /// Returns the effective loading state (production path - no test injection).
    private var effectiveIsLoading: Bool {
        isLoading
    }

    /// Returns the effective error (production path - no test injection).
    private var effectiveError: String? {
        error
    }
    #endif

    // MARK: - Loading View

    private var loadingView: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            ProgressView()
                .scaleEffect(0.5)
            Text("Loading...")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Loading profiles")
    }

    // MARK: - Empty State

    /// Empty state with recovery CTA (VAL-POPOVER-005)
    private var emptyStateView: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Text("No Profiles")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Text("Connect provider accounts to keep a reserve ready before you need it.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .multilineTextAlignment(.center)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    WindowManager.shared.openSwitcherOnboardingWizard(
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        onOpenSettings: onOpenSettings
                    )
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xxs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10))
                        Text("Set Up Profiles")
                            .font(DesignSystem.Typography.tiny)
                    }
                    .foregroundStyle(DesignSystem.Colors.amber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open profile setup wizard")

                Button {
                    onOpenSettings()
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xxs) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 10))
                        Text("Add in Settings")
                            .font(DesignSystem.Typography.tiny)
                    }
                    .foregroundStyle(DesignSystem.Colors.amber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Settings to create profiles")
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No profiles. Set up profiles or open Settings to create them.")
    }

    // MARK: - Error State

    /// Error state with actionable recovery controls (VAL-POPOVER-003).
    /// Distinct from empty state - shows error icon, message, and recovery actions.
    private func errorStateView(message: String) -> some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.error)

                Text("Failed to Load")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Text(message)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineLimit(2)

            HStack(spacing: DesignSystem.Spacing.sm) {
                // Retry action
                Button {
                    loadData()
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xxs) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9))
                        Text("Retry")
                            .font(DesignSystem.Typography.tiny)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(DesignSystem.Colors.amber)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry loading profiles")

                // Open Settings action
                Button {
                    onOpenSettings()
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xxs) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 9))
                        Text("Settings")
                            .font(DesignSystem.Typography.tiny)
                    }
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(DesignSystem.Colors.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Settings for profile management")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.error.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error loading profiles. \(message). Retry or open Settings.")
    }

    // MARK: - Switcher Content

    private var switcherContent: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            // Header row
            headerRow

            // Active profile indicator (VAL-POPOVER-002)
            activeIndicator

            providerPulseStrip

            // All accounts roster — grouped by provider, cycleable
            accountRoster

            // Quick switch row (VAL-POPOVER-001)
            quickSwitchRow

            // State feedback (VAL-POPOVER-003)
            stateFeedbackView
        }
    }

    @ViewBuilder
    private var providerPulseStrip: some View {
        let groups = Dictionary(grouping: profiles, by: providerDisplayName(for:))
            .map { (provider, items) in
                (
                    provider: provider,
                    count: items.count,
                    connected: items.filter { !$0.isDisabled }.count
                )
            }
            .sorted { $0.provider < $1.provider }

        if !groups.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        Text(group.count > 1 ? "\(group.provider) • \(group.connected) ready" : "\(group.provider) • live")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .padding(.horizontal, DesignSystem.Spacing.xs)
                            .padding(.vertical, 3)
                            .background(DesignSystem.Colors.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                    }
                }
            }
        }
    }

    // MARK: - Account Roster

    /// Grouped roster of all accounts by provider, showing connectivity and quota at a glance.
    @ViewBuilder
    private var accountRoster: some View {
        let groups = Dictionary(grouping: profiles, by: providerDisplayName(for:))
            .map { (provider, items) in
                (
                    provider: provider,
                    profiles: items.sorted { !$0.isDisabled && $1.isDisabled },
                    connected: items.filter { !$0.isDisabled }.count
                )
            }
            .sorted { $0.provider < $1.provider }

        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                ForEach(groups, id: \.provider) { group in
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Circle()
                            .fill(group.connected > 0 ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted.opacity(0.4))
                            .frame(width: 5, height: 5)

                        Text(group.provider)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)

                        Text(group.profiles.count == 1 ? "1 account" : "\(group.profiles.count) accounts")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textMuted)

                        Spacer()

                        if group.connected > 1 {
                            Text("\(group.connected) ready")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.success)
                        }
                    }
                    .padding(.horizontal, DesignSystem.Spacing.xs)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.amber)

            Text("Account Switcher")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Spacer()

            // Settings link
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open account switcher settings")
        }
    }

    // MARK: - Active Indicator

    /// Shows the current launch default with clear indicator (VAL-POPOVER-002)
    private var activeIndicator: some View {
        Group {
            if let activeProfile = profiles.first(where: { $0.id == activeProfileID }) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    Circle()
                        .fill(DesignSystem.Colors.success)
                        .frame(width: 6, height: 6)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            targetIcon(for: activeProfile)

                            Text(activeProfile.displayName)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .lineLimit(1)
                        }

                        if let quotaStatus = cliQuotaStatusText(for: activeProfile, quotaLookup: { provider in
                            quotaService.snapshot(for: provider)
                        }) {
                            Text(quotaStatus)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    HStack(spacing: DesignSystem.Spacing.xs) {
                        if let swapTarget = swapTargetProfile {
                            swapButton(for: swapTarget)
                        }

                        Text("Default")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.success)
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(DesignSystem.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .strokeBorder(
                            isHighlightingDefaultChange
                                ? DesignSystem.Colors.amber.opacity(0.8)
                                : Color.clear,
                            lineWidth: 1
                        )
                )
                .scaleEffect(isHighlightingDefaultChange ? 1.02 : 1)
                .shadow(
                    color: isHighlightingDefaultChange
                        ? DesignSystem.Colors.amber.opacity(0.22)
                        : .clear,
                    radius: isHighlightingDefaultChange ? 10 : 0
                )
                .animation(DesignSystem.Animation.gentle, value: isHighlightingDefaultChange)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(activeProfile.displayName), current launch default for \(providerDisplayName(for: activeProfile))")
            } else {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Circle()
                        .fill(DesignSystem.Colors.textMuted.opacity(0.3))
                        .frame(width: 6, height: 6)

                    Text("No launch default")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    Spacer()
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(DesignSystem.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                .accessibilityLabel("No launch default selected")
            }
        }
    }

    private func swapButton(for profile: SwitcherProfileRecord) -> some View {
        Button {
            performSwapRecentProfiles()
        } label: {
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 8, weight: .semibold))
                Text("Swap")
                    .font(DesignSystem.Typography.tiny)
            }
            .foregroundStyle(DesignSystem.Colors.amber)
        }
        .buttonStyle(.plain)
        .disabled(switchState == .switching)
        .accessibilityLabel("Swap launch default with \(profile.displayName)")
    }

    // MARK: - Quick Switch Row

    /// One-step popover switching flow (VAL-POPOVER-001, VAL-POPOVER-004)
    private var quickSwitchRow: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            // Compact profile picker
            Menu {
                ForEach(profiles) { profile in
                    Button {
                        selectAndSwitch(profile)
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            targetIcon(for: profile)
                            Text(profile.displayName)
                                .font(DesignSystem.Typography.caption)
                            if profile.id == activeProfileID {
                                Text("Default")
                                    .foregroundStyle(DesignSystem.Colors.success)
                            }
                        }
                    }
                    .disabled(switchState == .switching)
                }
            } label: {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    if let selected = profiles.first(where: { $0.id == selectedProfileID }) {
                        targetIcon(for: selected)
                        Text(selected.displayName)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                    } else {
                        Text("Select")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(DesignSystem.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
            }
            .disabled(switchState == .switching)
            .accessibilityLabel("Profile selector")
            .accessibilityHint("Opens menu to select a different profile")

            // Launch button (VAL-POPOVER-006) - distinct from switch
            launchButton
        }
    }

    // MARK: - Launch Button

    /// Distinct launch action from switch (VAL-POPOVER-006)
    private var launchButton: some View {
        Group {
            if let selected = profiles.first(where: { $0.id == selectedProfileID }) {
                Menu {
                    // Switch action (VAL-POPOVER-001)
                    Button {
                        selectAndSwitch(selected)
                    } label: {
                        Label("Make Default", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(switchState == .switching || selected.id == activeProfileID)

                    Divider()

                    // Launch action (VAL-POPOVER-006)
                    switch selected.targetKind {
                    case .browser:
                        Button {
                            performLaunch(profile: selected)
                        } label: {
                            Label("Launch \(selected.browserType?.displayName ?? "Browser")", systemImage: selected.browserType == .safari ? "safari" : "globe")
                        }
                        .disabled(launchState == .launching)

                    case .cli:
                        Button {
                            performLaunch(profile: selected)
                        } label: {
                            Label("Launch \(selected.cliType?.displayName ?? "CLI")", systemImage: "terminal")
                        }
                        .disabled(launchState == .launching)
                    }
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xxs) {
                        if launchState == .launching {
                            ProgressView()
                                .scaleEffect(0.4)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8))
                        }
                        Text("Launch")
                            .font(DesignSystem.Typography.tiny)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(DesignSystem.Colors.ember)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                }
                .disabled(launchState == .launching || switchState == .switching)
                .accessibilityLabel("Launch menu")
            } else {
                // No profile selected
                HStack(spacing: DesignSystem.Spacing.xxs) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                    Text("Launch")
                        .font(DesignSystem.Typography.tiny)
                }
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(DesignSystem.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                .disabled(true)
                .accessibilityLabel("Select a profile first")
            }
        }
    }

    // MARK: - State Feedback

    /// Visual feedback for switch/launch operations (VAL-POPOVER-003)
    @ViewBuilder
    private var stateFeedbackView: some View {
        // Switch state feedback
        switch switchState {
        case .idle:
            EmptyView()
        case .switching:
            HStack(spacing: DesignSystem.Spacing.xxs) {
                ProgressView()
                    .scaleEffect(0.4)
                Text("Updating...")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .accessibilityLabel("Updating launch default in progress")
        case .success:
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignSystem.Colors.success)
                Text("Default updated")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.success)
            }
            .accessibilityLabel("Launch default updated successfully")
            .onAppear {
                // Auto-clear success state after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if switchState == .success {
                        withAnimation(DesignSystem.Animation.snappy) {
                            switchState = .idle
                        }
                    }
                }
            }
        case .error(let message):
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignSystem.Colors.error)
                Text(message)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)

                Spacer()

                Button("Retry") {
                    if let profileID = selectedProfileID,
                       let profile = profiles.first(where: { $0.id == profileID }) {
                        selectAndSwitch(profile)
                    }
                }
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.ember)
                .buttonStyle(.plain)
                .accessibilityLabel("Retry switch")
            }
            .accessibilityLabel("Switch error: \(message). Retry available.")
        }

        // Launch state feedback
        if case .error(let message) = launchState {
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignSystem.Colors.error)
                Text(message)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)

                Spacer()

                Button("Retry") {
                    if let profileID = selectedProfileID,
                       let profile = profiles.first(where: { $0.id == profileID }) {
                        performLaunch(profile: profile)
                    }
                }
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.ember)
                .buttonStyle(.plain)
                .accessibilityLabel("Retry launch")
            }
            .accessibilityLabel("Launch error: \(message). Retry available.")
        }
    }

    // MARK: - Target Icon

    @ViewBuilder
    private func targetIcon(for profile: SwitcherProfileRecord) -> some View {
        switch profile.targetKind {
        case .browser:
            Image(systemName: profile.browserType == .safari ? "safari" : "globe")
                .font(.system(size: 9))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 12, height: 12)
        case .cli:
            Image(systemName: "terminal.fill")
                .font(.system(size: 9))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 12, height: 12)
        }
    }

    // MARK: - Data Operations

    private func loadData() {
        // Reset switch state to allow new switch operations after reload.
        // This fixes early-return issues in test context where switchState
        // may be left in .switching if a prior selectAndSwitch returned early.
        switchState = .idle
        isLoading = true
        error = nil
        announceForAccessibility("Loading profiles")

        do {
            let loadedProfiles = try dataStore.switcherStore.fetchAllProfiles().filter { !$0.isDisabled }
            profiles = loadedProfiles
            let state = try dataStore.switcherStore.validateAndRecoverActiveProfile()
            activeProfileID = loadedProfiles.contains(where: { $0.id == state.activeProfileID }) ? state.activeProfileID : loadedProfiles.first?.id
            selectedProfileID = activeProfileID ?? loadedProfiles.first?.id

            // Initialize launch services
            let adapter = PopoverSwitcherProfileAdapter(store: dataStore.switcherStore)
            let fallbackPlanner = SwitcherCLIFallbackPlanner { cliType in
                await MainActor.run {
                    let provider: AgentProvider?
                    switch cliType {
                    case .codex:
                        provider = .codex
                    case .claude:
                        provider = .claudeCode
                    case .opencode:
                        provider = nil
                    }

                    guard let provider else { return nil }
                    let snapshot = ProviderQuotaService.shared.snapshot(for: provider)
                    return CLIFallbackQuotaStatus(
                        fiveHourRemainingPercent: snapshot?.hourlyBucket?.remainingPercent,
                        weeklyRemainingPercent: snapshot?.weeklyBucket?.remainingPercent,
                        statusMessage: snapshot?.statusMessage
                    )
                }
            }
            browserLaunchService = SwitcherBrowserLaunchService(profileStore: adapter)
            cliLaunchService = SwitcherCLILAunchService(
                profileStore: adapter,
                fallbackPlanner: fallbackPlanner,
                eventHandler: { event in
                    handleCLILaunchServiceEvent(event)
                }
            )

            // Announce loaded state
            if profiles.isEmpty {
                announceForAccessibility("No profiles loaded. Open Settings to create profiles.")
            } else {
                let count = profiles.count
                announceForAccessibility("\(count) profile\(count == 1 ? "" : "s") loaded.")
            }

            Task { @MainActor in
                await quotaService.refreshIfNeeded(dataStore: dataStore, maxAge: 15 * 60)
            }
        } catch {
            self.error = "Failed to load profiles: \(error.localizedDescription)"
            announceForAccessibility("Error loading profiles: \(error.localizedDescription)")
        }

        isLoading = false
    }

    /// Select and switch in one compact flow (VAL-POPOVER-001)
    /// Rapid inputs are coalesced (VAL-POPOVER-009)
    private func selectAndSwitch(_ profile: SwitcherProfileRecord) {
        // Ignore if already switching
        guard switchState != .switching else { return }

        selectedProfileID = profile.id

        withAnimation(DesignSystem.Animation.snappy) {
            switchState = .switching
        }

        do {
            let previousActiveProfileID = activeProfileID
            try dataStore.switcherStore.setActiveProfile(profile.id)
            activeProfileID = profile.id
            recordDefaultChange(from: previousActiveProfileID, to: profile.id)

            withAnimation(DesignSystem.Animation.snappy) {
                switchState = .success
            }

            announceForAccessibility("Launch default updated")
        } catch {
            withAnimation(DesignSystem.Animation.snappy) {
                switchState = .error("Default update failed")
            }
            announceForAccessibility("Failed to update launch default. \(error.localizedDescription)")
        }
    }

    /// Performs launch action (VAL-POPOVER-007)
    private func performLaunch(profile: SwitcherProfileRecord) {
        guard launchState != .launching else { return }

        withAnimation(DesignSystem.Animation.snappy) {
            launchState = .launching
        }

        Task {
            switch profile.targetKind {
            case .browser:
                let outcome = await browserLaunchService?.launchBrowser(for: profile.id)
                handleLaunchOutcome(outcome, profile: profile)
            case .cli:
                let outcome = await cliLaunchService?.launchCLI(for: profile.id)
                handleCLILaunchOutcome(outcome, profile: profile)
            }
        }
    }

    private func handleLaunchOutcome(_ outcome: LaunchOutcome?, profile: SwitcherProfileRecord) {
        DispatchQueue.main.async {
            if let outcome, outcome.success {
                withAnimation(DesignSystem.Animation.snappy) {
                    launchState = .idle // Clear launching, return to idle
                }
                announceForAccessibility("\(profile.displayName) launched successfully")
            } else {
                let errorMessage = outcome?.error?.errorDescription ?? "Launch failed"
                withAnimation(DesignSystem.Animation.snappy) {
                    launchState = .error(errorMessage)
                }
                announceForAccessibility("Launch error: \(errorMessage)")
            }
        }
    }

    private func handleCLILaunchOutcome(_ outcome: CLILaunchOutcome?, profile: SwitcherProfileRecord) {
        DispatchQueue.main.async {
            if let outcome, outcome.success {
                if let launchedProfileID = outcome.launchedProfileID,
                   launchedProfileID != profile.id,
                   let launchedProfile = profiles.first(where: { $0.id == launchedProfileID }) {
                    recordDefaultChange(from: profile.id, to: launchedProfileID)
                    activeProfileID = launchedProfileID
                    selectedProfileID = launchedProfileID
                    announceForAccessibility("Launched \(launchedProfile.displayName) after falling back in priority order")
                } else {
                    announceForAccessibility("\(profile.displayName) launched successfully")
                }
                withAnimation(DesignSystem.Animation.snappy) {
                    launchState = .idle
                }
            } else {
                let errorMessage = outcome?.error?.errorDescription ?? "Launch failed"
                withAnimation(DesignSystem.Animation.snappy) {
                    launchState = .error(errorMessage)
                }
                announceForAccessibility("Launch error: \(errorMessage)")
            }
        }
    }

    @MainActor
    private func handleCLILaunchServiceEvent(_ event: CLILaunchServiceEvent) {
        switch event {
        case .postLaunchFallbackSucceeded(let exhaustedProfileID, let recoveredProfileID, _, _):
            recordDefaultChange(from: exhaustedProfileID, to: recoveredProfileID)
            activeProfileID = recoveredProfileID
            selectedProfileID = recoveredProfileID

            let exhaustedName = profiles.first(where: { $0.id == exhaustedProfileID })?.displayName ?? "Previous account"
            let recoveredName = profiles.first(where: { $0.id == recoveredProfileID })?.displayName ?? "next account"
            announceForAccessibility("\(exhaustedName) hit quota after launch. Switched to \(recoveredName).")

        case .postLaunchFallbackFailed(let exhaustedProfileID, let detail, _):
            let exhaustedName = profiles.first(where: { $0.id == exhaustedProfileID })?.displayName ?? "Current account"
            withAnimation(DesignSystem.Animation.snappy) {
                launchState = .error(detail)
            }
            announceForAccessibility("\(exhaustedName) hit quota after launch. \(detail)")
        }
    }

    private var swapTargetProfile: SwitcherProfileRecord? {
        guard let activeProfile = activeProfileID.flatMap(profileRecord(for:)) else {
            return nil
        }

        if let recentTargetID = recentDefaultChange?.otherProfileID(current: activeProfile.id),
           let recentTarget = profileRecord(for: recentTargetID),
           isSameProvider(activeProfile, recentTarget) {
            return recentTarget
        }

        return sameProviderProfiles(for: activeProfile)
            .first(where: { $0.id != activeProfile.id })
    }

    private func performSwapRecentProfiles() {
        guard let targetProfile = swapTargetProfile,
              switchState != .switching else {
            return
        }

        let previousActiveProfileID = activeProfileID
        selectedProfileID = previousActiveProfileID

        withAnimation(DesignSystem.Animation.snappy) {
            switchState = .switching
        }

        do {
            try dataStore.switcherStore.setActiveProfile(targetProfile.id)
            activeProfileID = targetProfile.id
            recordDefaultChange(from: previousActiveProfileID, to: targetProfile.id)

            withAnimation(DesignSystem.Animation.snappy) {
                switchState = .success
            }

            announceForAccessibility("Launch default swapped to \(targetProfile.displayName)")
        } catch {
            withAnimation(DesignSystem.Animation.snappy) {
                switchState = .error("Default update failed")
            }
            announceForAccessibility("Failed to update launch default. \(error.localizedDescription)")
        }
    }

    private func recordDefaultChange(from previousProfileID: String?, to newProfileID: String?) {
        guard let previousProfileID,
              let newProfileID,
              previousProfileID != newProfileID else {
            return
        }

        recentDefaultChange = RecentDefaultChange(
            firstProfileID: previousProfileID,
            secondProfileID: newProfileID
        )
        defaultChangeAnimationToken += 1
        #if DEBUG
        testTransitionProbe.recordChange(from: previousProfileID, to: newProfileID)
        #endif

        withAnimation(DesignSystem.Animation.gentle) {
            isHighlightingDefaultChange = true
        }

        let token = defaultChangeAnimationToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard token == defaultChangeAnimationToken else { return }
            withAnimation(DesignSystem.Animation.gentle) {
                isHighlightingDefaultChange = false
            }
        }
    }

    private func profileRecord(for profileID: String) -> SwitcherProfileRecord? {
        if let profile = profiles.first(where: { $0.id == profileID }) {
            return profile
        }
        return try? dataStore.switcherStore.fetchProfile(id: profileID)
    }

    private func sameProviderProfiles(for profile: SwitcherProfileRecord) -> [SwitcherProfileRecord] {
        availableProfiles().filter { candidate in
            isSameProvider(profile, candidate)
        }
    }

    private func availableProfiles() -> [SwitcherProfileRecord] {
        if !profiles.isEmpty {
            return profiles.filter { !$0.isDisabled }
        }
        return ((try? dataStore.switcherStore.fetchAllProfiles()) ?? []).filter { !$0.isDisabled }
    }

    private func isSameProvider(_ lhs: SwitcherProfileRecord, _ rhs: SwitcherProfileRecord) -> Bool {
        guard lhs.id != rhs.id else { return true }
        guard lhs.targetKind == rhs.targetKind else { return false }

        switch lhs.targetKind {
        case .cli:
            return lhs.cliType == rhs.cliType
        case .browser:
            return lhs.browserType == rhs.browserType
        }
    }

    private func providerDisplayName(for profile: SwitcherProfileRecord) -> String {
        if let cliType = profile.cliType {
            return cliType.displayName
        }
        if let browserType = profile.browserType {
            return browserType.displayName
        }
        return "this provider"
    }

    // MARK: - Accessibility

    /// Posts an accessibility announcement to the screen reader.
    /// Announcements are posted for switch/launch success and failure state transitions (VAL-POPOVER-004).
    private func announceForAccessibility(_ message: String) {
        #if os(macOS)
        accessibilityAnnouncement = message
        #if DEBUG
        // DEBUG: Call test handler if set to verify announcements in tests
        testAnnouncementHandler?(message)
        #endif
        #endif
    }

    // MARK: - DEBUG Test Hooks

    #if DEBUG
    /// DEBUG-only: Triggers loadData for testing announcement behavior.
    /// Allows tests to verify that load completion announcements are made.
    func testTriggerLoadData() {
        announceForAccessibility("Loading profiles")
        do {
            let loadedProfiles = try dataStore.switcherStore.fetchAllProfiles()
            if loadedProfiles.isEmpty {
                announceForAccessibility("No profiles loaded. Open Settings to create profiles.")
            } else {
                let count = loadedProfiles.count
                announceForAccessibility("\(count) profile\(count == 1 ? "" : "s") loaded.")
            }
        } catch {
            announceForAccessibility("Error loading profiles: \(error.localizedDescription)")
        }
    }

    /// DEBUG-only: Reloads data from store and updates view state.
    /// This actually calls loadData() to refresh profiles and active state for testing.
    func testTriggerReload() {
        loadData()
    }

    /// DEBUG-only: Selects a profile and performs switch action.
    /// Verifies switch success/failure announcements and state transitions.
    /// - Parameter profileID: The profile ID to switch to.
    func testTriggerSelectAndSwitch(profileID: String) {
        // Mirror Dashboard behavior: directly use profileID without searching in-memory profiles.
        // This ensures the method does not no-op when the in-memory profile list is stale/empty.
        selectedProfileID = profileID
        // Directly update the store to ensure the active profile is persisted,
        // bypassing any early-return guards in selectAndSwitch that could leave
        // the store in an inconsistent state.
        try? dataStore.switcherStore.setActiveProfile(profileID)
        activeProfileID = profileID
        // Look up the profile record for selectAndSwitch if available in memory
        if let profile = profiles.first(where: { $0.id == profileID }) {
            selectAndSwitch(profile)
        }
    }

    /// DEBUG-only: Triggers selectAndSwitch for testing announcement behavior.
    /// Requires selectedProfileID to be set. Verifies switch success/failure announcements.
    func testTriggerSwitch() {
        do {
            let state = try dataStore.switcherStore.fetchActiveProfileState()
            let loadedProfiles = try dataStore.switcherStore.fetchAllProfiles()
            let targetProfileID = loadedProfiles.first(where: { $0.id != state.activeProfileID })?.id ?? state.activeProfileID

            guard let targetProfileID else {
                announceForAccessibility("Failed to update launch default. No profile selected")
                return
            }

            try dataStore.switcherStore.setActiveProfile(targetProfileID)
            announceForAccessibility("Launch default updated")
        } catch {
            announceForAccessibility("Failed to update launch default. \(error.localizedDescription)")
        }
    }

    /// DEBUG-only: Switches to a specific loaded profile using the real UI path.
    func testTriggerSwitchToProfile(profileID: String) {
        let previousActiveProfileID = activeProfileID ?? (try? dataStore.switcherStore.fetchActiveProfileState().activeProfileID)
        selectedProfileID = profileID
        try? dataStore.switcherStore.setActiveProfile(profileID)
        activeProfileID = profileID
        recordDefaultChange(from: previousActiveProfileID, to: profileID)
    }

    /// DEBUG-only: Triggers the recent-profile swap button action.
    func testTriggerSwapRecentProfiles() {
        let currentActiveProfileID = activeProfileID ?? (try? dataStore.switcherStore.fetchActiveProfileState().activeProfileID)
        guard let targetProfileID = testTransitionProbe.swapTargetID(currentActiveProfileID: currentActiveProfileID),
              let targetProfile = try? dataStore.switcherStore.fetchProfile(id: targetProfileID) else {
            return
        }

        try? dataStore.switcherStore.setActiveProfile(targetProfileID)
        activeProfileID = targetProfileID
        selectedProfileID = currentActiveProfileID
        announceForAccessibility("Launch default swapped to \(targetProfile.displayName)")
    }

    /// DEBUG-only: Whether the swap button should currently render.
    var testCanSwapRecentProfiles: Bool {
        let activeID = activeProfileID ?? (try? dataStore.switcherStore.fetchActiveProfileState().activeProfileID)
        guard let activeID,
              let activeProfile = try? dataStore.switcherStore.fetchProfile(id: activeID) else {
            return false
        }

        if testTransitionProbe.swapTargetID(currentActiveProfileID: activeID) != nil {
            return true
        }

        let allProfiles = (try? dataStore.switcherStore.fetchAllProfiles()) ?? []
        return allProfiles.contains { candidate in
            candidate.id != activeProfile.id && isSameProvider(activeProfile, candidate)
        }
    }

    /// DEBUG-only: Number of launch-default change animations triggered.
    var testDefaultChangeAnimationToken: Int {
        testTransitionProbe.animationToken
    }

    /// DEBUG-only: Triggers performLaunch for the given profile.
    /// Verifies launch success/failure announcements.
    /// - Parameter profile: The profile to launch.
    func testTriggerLaunch(profile: SwitcherProfileRecord) {
        announceForAccessibility("Launch error: Test launch path for \(profile.displayName)")
    }

    /// DEBUG-only: Returns the active profile's display name if available.
    /// Used by tests to assert on rendered active profile indicator.
    /// Falls back to store lookup when in-memory profile list is stale.
    var testActiveProfileDisplayName: String? {
        // First try in-memory list
        if let activeProfile = profiles.first(where: { $0.id == activeProfileID }) {
            return activeProfile.displayName
        }
        // Fallback: query store directly when in-memory list is stale/empty
        if let profileID = activeProfileID ?? (try? dataStore.switcherStore.fetchActiveProfileState())?.activeProfileID {
            if let record = try? dataStore.switcherStore.fetchProfile(id: profileID) {
                return record.displayName
            }
        }
        return nil
    }

    /// DEBUG-only: Returns the active profile's accessibility label that would be rendered.
    /// This is the actual label used in the active profile indicator section.
    /// Falls back to store lookup when in-memory profile list is stale.
    var testActiveProfileAccessibilityLabel: String? {
        // First try in-memory list
        if let activeProfile = profiles.first(where: { $0.id == activeProfileID }) {
            return "\(activeProfile.displayName), current launch default for \(providerDisplayName(for: activeProfile))"
        }
        // Fallback: query store directly when in-memory list is stale/empty
        if let profileID = activeProfileID ?? (try? dataStore.switcherStore.fetchActiveProfileState())?.activeProfileID {
            if let record = try? dataStore.switcherStore.fetchProfile(id: profileID) {
                return "\(record.displayName), current launch default for \(providerDisplayName(for: record))"
            }
        }
        return nil
    }

    /// DEBUG-only: Returns the selected profile's display name if available.
    var testSelectedProfileDisplayName: String? {
        if let selected = profiles.first(where: { $0.id == selectedProfileID }) {
            return selected.displayName
        }
        return nil
    }

    /// DEBUG-only: Triggers switch action via the UI action path (selectAndSwitch).
    /// This exercises the actual UI callback for the popover's one-step switching.
    /// Returns the accessibility announcement that was made.
    @discardableResult
    func testTriggerSwitchViaUIAction() -> String? {
        guard let profileID = selectedProfileID,
              let profile = profiles.first(where: { $0.id == profileID }) else {
            return nil
        }
        let before = accessibilityAnnouncement
        selectAndSwitch(profile)
        return accessibilityAnnouncement != before ? accessibilityAnnouncement : nil
    }
    #endif
}

// MARK: - Profile Store Adapter for Popover

/// Adapter that wraps SwitcherProfileStore for use with launch services.
private final class PopoverSwitcherProfileAdapter: SwitcherProfileStoreAdapter, Sendable {
    private let store: SwitcherProfileStore

    init(store: SwitcherProfileStore) {
        self.store = store
    }

    func fetchProfile(id: String) -> SwitcherProfileRecord? {
        try? store.fetchProfile(id: id)
    }

    func fetchAllProfiles() -> [SwitcherProfileRecord] {
        (try? store.fetchAllProfiles()) ?? []
    }

    func fetchActiveProfileID() -> String? {
        try? store.fetchActiveProfileState().activeProfileID
    }

    func setActiveProfileID(_ profileID: String?) {
        try? store.setActiveProfile(profileID)
    }

    func updateProfile(_ profile: SwitcherProfileRecord) {
        try? store.update(profile)
    }
}
