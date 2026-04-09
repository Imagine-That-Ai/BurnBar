import SwiftUI
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

    // Launch services
    @State private var browserLaunchService: SwitcherBrowserLaunchService?
    @State private var cliLaunchService: SwitcherCLILAunchService?

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

            if isLoading {
                loadingView
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
        .onAppear(perform: loadData)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Account Switcher")
        .accessibilityHint("Use to quickly switch between browser and CLI profiles")
    }

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
        isLoading = true
        error = nil

        do {
            profiles = try dataStore.switcherStore.fetchAllProfiles()
            let state = try dataStore.switcherStore.validateAndRecoverActiveProfile()
            activeProfileID = state.activeProfileID
            selectedProfileID = state.activeProfileID ?? profiles.first?.id

            // Initialize launch services
            let adapter = DashboardSwitcherProfileAdapter(store: dataStore.switcherStore)
            browserLaunchService = SwitcherBrowserLaunchService(profileStore: adapter)
            cliLaunchService = SwitcherCLILAunchService(profileStore: adapter)
        } catch {
            self.error = "Failed to load profiles: \(error.localizedDescription)"
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

    private func announceForAccessibility(_ message: String) {
        #if os(macOS)
        // Accessibility announcements would be posted here using NSAccessibility
        // For now, we rely on SwiftUI's built-in accessibility support
        _ = message
        #endif
    }
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
}
