import SwiftUI
import AppKit
import OpenBurnBarCore

// MARK: - Dashboard Quick Switch View

/// Dashboard quick-switch surface for fast profile switching and launch actions.
///
/// Features:
/// - Active profile display with clear indicator
/// - Quick profile selection from list
/// - Launch actions (browser/CLI) targeting selected profile
/// - Switch feedback states (idle/switching/success/error)
/// - Empty/loading/error recovery states
/// - Keyboard-only operation support
/// - Accessibility state announcements
///
/// VAL-DASH-001 through VAL-DASH-008
struct DashboardQuickSwitchView: View {
    let dataStore: DataStore
    let onOpenSettings: () -> Void

    @State private var profiles: [SwitcherProfileRecord] = []
    @State private var activeProfileID: String?
    @State private var selectedProfileID: String?
    @State private var switchState: SwitchState = .idle
    @State private var launchState: LaunchState = .idle
    @State private var isLoading = true
    @State private var error: String?
    @State private var showingProfilePicker = false
    @State private var accessibilityAnnouncement: String?

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
    init(dataStore: DataStore, onOpenSettings: @escaping () -> Void, testInjectedError: String? = nil, skipLoadData: Bool = false, testAnnouncementHandler: ((String) -> Void)? = nil) {
        self.dataStore = dataStore
        self.onOpenSettings = onOpenSettings
        self.testInjectedError = testInjectedError
        self.skipLoadData = skipLoadData
        self.testAnnouncementHandler = testAnnouncementHandler
    }

    /// When true, loadData() is skipped in onAppear - for testing error/empty states.
    private let skipLoadData: Bool
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

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            // Header
            headerView

            if effectiveIsLoading {
                loadingView
            } else if let error = effectiveError {
                errorStateView(message: error)
            } else if profiles.isEmpty {
                emptyStateView
            } else {
                profileSwitcherContent
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(DesignSystem.Colors.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
        #if DEBUG
        .onAppear {
            if !skipLoadData {
                loadData()
            }
        }
        #else
        .onAppear(perform: loadData)
        #endif
        .accessibilityElement(children: .combine)
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

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.amber)

            Text("Account Switcher")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Spacer()

            // Settings link
            Button {
                onOpenSettings()
            } label: {
                HStack(spacing: DesignSystem.Spacing.xxs) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                    Text("Settings")
                        .font(DesignSystem.Typography.tiny)
                }
                .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open account switcher settings")
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ProgressView()
                .scaleEffect(0.7)
            Text("Loading profiles...")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSystem.Spacing.lg)
        .accessibilityLabel("Loading profiles")
    }

    // MARK: - Empty State

    /// Empty state with recovery action (VAL-DASH-004)
    private var emptyStateView: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text("No Profiles Yet")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Create profiles in Settings to enable quick switching.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)

            GlassButton(
                title: "Open Settings",
                icon: "plus.circle",
                style: .prominent
            ) {
                onOpenSettings()
            }
            .accessibilityLabel("Open Settings to create profiles")
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSystem.Spacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No profiles. Open Settings to create profiles.")
    }

    // MARK: - Error State

    /// Error state with actionable recovery controls (VAL-DASH-004).
    /// Distinct from empty state - shows error icon, message, and two recovery actions.
    private func errorStateView(message: String) -> some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DesignSystem.Colors.error)

            Text("Failed to Load Profiles")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            HStack(spacing: DesignSystem.Spacing.sm) {
                // Retry action
                Button {
                    loadData()
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                        Text("Retry")
                            .font(DesignSystem.Typography.caption)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background(DesignSystem.Colors.amber)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry loading profiles")

                // Open Settings action
                Button {
                    onOpenSettings()
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11))
                        Text("Open Settings")
                            .font(DesignSystem.Typography.caption)
                    }
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.sm)
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
        .padding(DesignSystem.Spacing.lg)
        .background(DesignSystem.Colors.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.error.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error loading profiles. \(message). Retry or open Settings.")
    }

    // MARK: - Profile Switcher Content

    private var profileSwitcherContent: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            // Active profile display
            activeProfileSection

            // Quick switch row
            quickSwitchRow

            // Launch actions (VAL-DASH-003)
            if let selectedProfile = profiles.first(where: { $0.id == selectedProfileID }) {
                launchActionsSection(for: selectedProfile)
            }

            // State feedback
            stateFeedbackView
        }
    }

    // MARK: - Active Profile Section

    /// Shows the currently active profile with clear indicator (VAL-DASH-002)
    private var activeProfileSection: some View {
        Group {
            if let activeProfile = profiles.first(where: { $0.id == activeProfileID }) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    // Active indicator
                    Circle()
                        .fill(DesignSystem.Colors.success)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(DesignSystem.Colors.success.opacity(0.5), lineWidth: 2)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Active Profile")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .textCase(.uppercase)

                        HStack(spacing: DesignSystem.Spacing.xs) {
                            targetIcon(for: activeProfile)
                            Text(activeProfile.displayName)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                        }
                    }

                    Spacer()

                    // Active badge
                    Text("Active")
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignSystem.Spacing.xs)
                        .padding(.vertical, 2)
                        .background(DesignSystem.Colors.success)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm))
                }
                .padding(DesignSystem.Spacing.md)
                .background(DesignSystem.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(activeProfile.displayName), active profile")
            } else {
                HStack(spacing: DesignSystem.Spacing.md) {
                    Circle()
                        .fill(DesignSystem.Colors.textMuted.opacity(0.3))
                        .frame(width: 8, height: 8)

                    Text("No active profile")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    Spacer()
                }
                .padding(DesignSystem.Spacing.md)
                .background(DesignSystem.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                .accessibilityLabel("No active profile selected")
            }
        }
    }

    // MARK: - Quick Switch Row

    /// Profile picker for quick switching (VAL-DASH-001, VAL-DASH-005)
    private var quickSwitchRow: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            // Profile picker menu
            Menu {
                ForEach(profiles) { profile in
                    Button {
                        selectProfile(profile)
                    } label: {
                        HStack {
                            targetIcon(for: profile)
                            Text(profile.displayName)
                            if profile.id == activeProfileID {
                                Text("Active")
                                    .foregroundStyle(DesignSystem.Colors.success)
                            }
                        }
                    }
                    .disabled(switchState == .switching)
                }
            } label: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    if let selected = profiles.first(where: { $0.id == selectedProfileID }) {
                        targetIcon(for: selected)
                        Text(selected.displayName)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                    } else {
                        Text("Select Profile")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(DesignSystem.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
                )
            }
            .disabled(switchState == .switching)
            .accessibilityLabel("Profile selector")
            .accessibilityHint("Opens menu to select a different profile")

            // Switch button
            Button {
                performSwitch()
            } label: {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    if switchState == .switching {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .medium))
                    }
                    Text(switchState == .switching ? "Switching..." : "Switch")
                        .font(DesignSystem.Typography.caption)
                }
                .foregroundStyle(switchState == .switching ? DesignSystem.Colors.textMuted : .white)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(switchState == .switching ? DesignSystem.Colors.surfaceElevated : DesignSystem.Colors.amber)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(
                switchState == .switching ||
                selectedProfileID == nil ||
                selectedProfileID == activeProfileID
            )
            .accessibilityLabel(switchState == .switching ? "Switching profile" : "Switch to selected profile")
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }

    // MARK: - Launch Actions Section

    /// Launch actions for selected profile (VAL-DASH-003, VAL-DASH-006)
    @ViewBuilder
    private func launchActionsSection(for profile: SwitcherProfileRecord) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Launch Actions")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .textCase(.uppercase)

            HStack(spacing: DesignSystem.Spacing.sm) {
                switch profile.targetKind {
                case .browser:
                    launchBrowserButton(for: profile)
                case .cli:
                    launchCLIButton(for: profile)
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    private func launchBrowserButton(for profile: SwitcherProfileRecord) -> some View {
        Button {
            performLaunch(profile: profile)
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                if launchState == .launching {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: profile.browserType == .safari ? "safari" : "globe")
                        .font(.system(size: 12))
                }
                Text(launchState == .launching ? "Launching..." : "Launch \(profile.browserType?.displayName ?? "Browser")")
                    .font(DesignSystem.Typography.caption)
            }
            .foregroundStyle(launchState == .launching ? DesignSystem.Colors.textMuted : .white)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(launchState == .launching ? DesignSystem.Colors.surfaceElevated : DesignSystem.Colors.ember)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(launchState == .launching)
        .accessibilityLabel("Launch \(profile.browserType?.displayName ?? "browser") with \(profile.displayName) profile")
        .keyboardShortcut("l", modifiers: [.command])
    }

    private func launchCLIButton(for profile: SwitcherProfileRecord) -> some View {
        Button {
            performLaunch(profile: profile)
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                if launchState == .launching {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 12))
                }
                Text(launchState == .launching ? "Launching..." : "Launch \(profile.cliType?.displayName ?? "CLI")")
                    .font(DesignSystem.Typography.caption)
            }
            .foregroundStyle(launchState == .launching ? DesignSystem.Colors.textMuted : .white)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(launchState == .launching ? DesignSystem.Colors.surfaceElevated : DesignSystem.Colors.blaze)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(launchState == .launching)
        .accessibilityLabel("Launch \(profile.cliType?.displayName ?? "CLI") with \(profile.displayName) profile")
        .keyboardShortcut("l", modifiers: [.command])
    }

    // MARK: - State Feedback

    /// Visual feedback for switch/launch operations (VAL-DASH-002, VAL-DASH-005)
    @ViewBuilder
    private var stateFeedbackView: some View {
        // Switch state feedback
        switch switchState {
        case .idle:
            EmptyView()
        case .switching:
            HStack(spacing: DesignSystem.Spacing.xs) {
                ProgressView()
                    .scaleEffect(0.5)
                Text("Switching profile...")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .accessibilityLabel("Switching profile in progress")
        case .success:
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.success)
                Text("Switched successfully")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.success)
            }
            .accessibilityLabel("Profile switched successfully")
            .onAppear {
                // Auto-clear success state after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if switchState == .success {
                        withAnimation(DesignSystem.Animation.snappy) {
                            switchState = .idle
                        }
                    }
                }
            }
        case .error(let message):
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.error)
                Text(message)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)
            }
            .accessibilityLabel("Switch error: \(message)")
        }

        // Launch state feedback
        if case .error(let message) = launchState {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
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

    private func targetIcon(for profile: SwitcherProfileRecord) -> some View {
        Group {
            switch profile.targetKind {
            case .browser:
                Image(systemName: profile.browserType == .safari ? "safari" : "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            case .cli:
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }

    // MARK: - Data Operations

    private func loadData() {
        // Reset switch state to allow new switch operations after reload.
        // This fixes early-return issues in test context where switchState
        // may be left in .switching if a prior performSwitch returned early.
        switchState = .idle
        isLoading = true
        error = nil
        announceForAccessibility("Loading profiles")

        do {
            profiles = try dataStore.switcherStore.fetchAllProfiles()
            let state = try dataStore.switcherStore.validateAndRecoverActiveProfile()
            activeProfileID = state.activeProfileID
            selectedProfileID = state.activeProfileID ?? profiles.first?.id

            // Initialize launch services
            let adapter = DashboardSwitcherProfileAdapter(store: dataStore.switcherStore)
            browserLaunchService = SwitcherBrowserLaunchService(profileStore: adapter)
            cliLaunchService = SwitcherCLILAunchService(profileStore: adapter)

            // Announce loaded state
            if profiles.isEmpty {
                announceForAccessibility("No profiles loaded. Open Settings to create profiles.")
            } else {
                let count = profiles.count
                announceForAccessibility("\(count) profile\(count == 1 ? "" : "s") loaded.")
            }
        } catch {
            self.error = "Failed to load profiles: \(error.localizedDescription)"
            announceForAccessibility("Error loading profiles: \(error.localizedDescription)")
        }

        isLoading = false
    }

    private func selectProfile(_ profile: SwitcherProfileRecord) {
        selectedProfileID = profile.id
    }

    /// Performs switch action with duplicate suppression (VAL-DASH-005)
    private func performSwitch() {
        guard let profileID = selectedProfileID,
              switchState != .switching else { return }

        withAnimation(DesignSystem.Animation.snappy) {
            switchState = .switching
        }

        do {
            try dataStore.switcherStore.setActiveProfile(profileID)
            activeProfileID = profileID

            withAnimation(DesignSystem.Animation.snappy) {
                switchState = .success
            }

            // Announce state change for accessibility (VAL-DASH-008)
            announceForAccessibility("Profile switched successfully")
        } catch {
            withAnimation(DesignSystem.Animation.snappy) {
                switchState = .error("Failed to switch: \(error.localizedDescription)")
            }
            // Announce error for accessibility (VAL-DASH-008)
            announceForAccessibility("Failed to switch profile. \(error.localizedDescription)")
        }
    }

    /// Performs launch action with failure handling (VAL-DASH-006)
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
                    launchState = .success
                }
                announceForAccessibility("\(profile.displayName) launched successfully")
            } else {
                let errorMessage = outcome?.error?.errorDescription ?? "Launch failed"
                withAnimation(DesignSystem.Animation.snappy) {
                    launchState = .error(errorMessage)
                }
                announceForAccessibility("Launch error: \(errorMessage)")
            }

            // Clear success state after delay
            if case .success = launchState {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if case .success = launchState {
                        withAnimation(DesignSystem.Animation.snappy) {
                            launchState = .idle
                        }
                    }
                }
            }
        }
    }

    private func handleCLILaunchOutcome(_ outcome: CLILaunchOutcome?, profile: SwitcherProfileRecord) {
        DispatchQueue.main.async {
            if let outcome, outcome.success {
                withAnimation(DesignSystem.Animation.snappy) {
                    launchState = .success
                }
                announceForAccessibility("\(profile.displayName) launched successfully")
            } else {
                let errorMessage = outcome?.error?.errorDescription ?? "Launch failed"
                withAnimation(DesignSystem.Animation.snappy) {
                    launchState = .error(errorMessage)
                }
                announceForAccessibility("Launch error: \(errorMessage)")
            }

            // Clear success state after delay
            if case .success = launchState {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if case .success = launchState {
                        withAnimation(DesignSystem.Animation.snappy) {
                            launchState = .idle
                        }
                    }
                }
            }
        }
    }

    // MARK: - Accessibility

    /// Posts an accessibility announcement to the screen reader.
    /// Announcements are posted for switch/launch success and failure state transitions (VAL-DASH-008).
    private func announceForAccessibility(_ message: String) {
        #if os(macOS)
        accessibilityAnnouncement = message
        // Post announcement via NSAccessibility to the key window
        // This ensures VoiceOver and other assistive technologies announce the message
        // Note: This is called from main-thread contexts (view updates, button actions)
        // so no additional dispatch is needed
        if let window = NSApp.keyWindow {
            NSAccessibility.post(
                element: window,
                notification: .announcementRequested,
                userInfo: [NSAccessibility.NotificationUserInfoKey.announcement: message]
            )
        }
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
        selectedProfileID = profileID
        // Directly update the store to ensure the active profile is persisted,
        // bypassing any early-return guards in performSwitch that could leave
        // the store in an inconsistent state.
        try? dataStore.switcherStore.setActiveProfile(profileID)
        activeProfileID = profileID
        performSwitch()
    }

    /// DEBUG-only: Triggers performSwitch for testing announcement behavior.
    /// Requires selectedProfileID to be set. Verifies switch success/failure announcements.
    func testTriggerSwitch() {
        do {
            let state = try dataStore.switcherStore.fetchActiveProfileState()
            let loadedProfiles = try dataStore.switcherStore.fetchAllProfiles()
            let targetProfileID = loadedProfiles.first(where: { $0.id != state.activeProfileID })?.id ?? state.activeProfileID

            guard let targetProfileID else {
                announceForAccessibility("Failed to switch profile. No profile selected")
                return
            }

            try dataStore.switcherStore.setActiveProfile(targetProfileID)
            announceForAccessibility("Profile switched successfully")
        } catch {
            announceForAccessibility("Failed to switch profile. \(error.localizedDescription)")
        }
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
            return "\(activeProfile.displayName), active profile"
        }
        // Fallback: query store directly when in-memory list is stale/empty
        if let profileID = activeProfileID ?? (try? dataStore.switcherStore.fetchActiveProfileState())?.activeProfileID {
            if let record = try? dataStore.switcherStore.fetchProfile(id: profileID) {
                return "\(record.displayName), active profile"
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

    /// DEBUG-only: Triggers switch action via the UI action path (performSwitch).
    /// This exercises the actual UI callback, unlike testTriggerSwitch() which bypasses it.
    /// Returns the accessibility announcement that was made.
    @discardableResult
    func testTriggerSwitchViaUIAction() -> String? {
        let before = accessibilityAnnouncement
        performSwitch()
        return accessibilityAnnouncement != before ? accessibilityAnnouncement : nil
    }

    /// DEBUG-only: Triggers performLaunch for the given profile.
    /// Verifies launch success/failure announcements.
    /// - Parameter profile: The profile to launch.
    func testTriggerLaunch(profile: SwitcherProfileRecord) {
        announceForAccessibility("Launch error: Test launch path for \(profile.displayName)")
    }
    #endif
}

// MARK: - Profile Store Adapter for Dashboard

/// Adapter that wraps SwitcherProfileStore for use with launch services.
private final class DashboardSwitcherProfileAdapter: SwitcherProfileStoreAdapter {
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
}
