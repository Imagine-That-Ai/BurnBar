import SwiftUI
import OpenBurnBarCore

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

    @State private var profiles: [SwitcherProfileRecord] = []
    @State private var activeProfileID: String?
    @State private var selectedProfileID: String?
    @State private var switchState: SwitchState = .idle
    @State private var launchState: LaunchState = .idle
    @State private var isLoading = true
    @State private var showingLaunchMenu = false

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
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            if isLoading {
                loadingView
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
        .onAppear(perform: loadData)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Account Switcher")
        .accessibilityHint("Use to quickly switch between browser and CLI profiles")
    }

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
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No profiles. Open Settings to create profiles.")
    }

    // MARK: - Switcher Content

    private var switcherContent: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            // Header row
            headerRow

            // Active profile indicator (VAL-POPOVER-002)
            activeIndicator

            // Quick switch row (VAL-POPOVER-001)
            quickSwitchRow

            // State feedback (VAL-POPOVER-003)
            stateFeedbackView
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

    /// Shows the currently active profile with clear indicator (VAL-POPOVER-002)
    private var activeIndicator: some View {
        Group {
            if let activeProfile = profiles.first(where: { $0.id == activeProfileID }) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    // Active dot
                    Circle()
                        .fill(DesignSystem.Colors.success)
                        .frame(width: 6, height: 6)

                    targetIcon(for: activeProfile)

                    Text(activeProfile.displayName)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    Text("Active")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.success)
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(DesignSystem.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(activeProfile.displayName), active profile")
            } else {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Circle()
                        .fill(DesignSystem.Colors.textMuted.opacity(0.3))
                        .frame(width: 6, height: 6)

                    Text("No active profile")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    Spacer()
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(DesignSystem.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                .accessibilityLabel("No active profile selected")
            }
        }
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
                                Text("✓")
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
                        Label("Switch to This", systemImage: "arrow.triangle.2.circlepath")
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
                Text("Switching...")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .accessibilityLabel("Switching profile in progress")
        case .success:
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignSystem.Colors.success)
                Text("Switched")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.success)
            }
            .accessibilityLabel("Profile switched successfully")
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

    private func targetIcon(for profile: SwitcherProfileRecord) -> some View {
        Group {
            switch profile.targetKind {
            case .browser:
                Image(systemName: profile.browserType == .safari ? "safari" : "globe")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            case .cli:
                Image(systemName: "terminal.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }

    // MARK: - Data Operations

    private func loadData() {
        isLoading = true

        do {
            profiles = try dataStore.switcherStore.fetchAllProfiles()
            let state = try dataStore.switcherStore.validateAndRecoverActiveProfile()
            activeProfileID = state.activeProfileID
            selectedProfileID = state.activeProfileID ?? profiles.first?.id

            // Initialize launch services
            let adapter = PopoverSwitcherProfileAdapter(store: dataStore.switcherStore)
            browserLaunchService = SwitcherBrowserLaunchService(profileStore: adapter)
            cliLaunchService = SwitcherCLILAunchService(profileStore: adapter)
        } catch {
            // Load failed - handle gracefully
            profiles = []
            activeProfileID = nil
            selectedProfileID = nil
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
            try dataStore.switcherStore.setActiveProfile(profile.id)
            activeProfileID = profile.id

            withAnimation(DesignSystem.Animation.snappy) {
                switchState = .success
            }
        } catch {
            withAnimation(DesignSystem.Animation.snappy) {
                switchState = .error("Switch failed")
            }
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
                handleLaunchOutcome(outcome)
            case .cli:
                let outcome = await cliLaunchService?.launchCLI(for: profile.id)
                handleCLILaunchOutcome(outcome)
            }
        }
    }

    private func handleLaunchOutcome(_ outcome: LaunchOutcome?) {
        DispatchQueue.main.async {
            if let outcome, outcome.success {
                withAnimation(DesignSystem.Animation.snappy) {
                    launchState = .idle // Clear launching, return to idle
                }
            } else {
                let errorMessage = outcome?.error?.errorDescription ?? "Launch failed"
                withAnimation(DesignSystem.Animation.snappy) {
                    launchState = .error(errorMessage)
                }
            }
        }
    }

    private func handleCLILaunchOutcome(_ outcome: CLILaunchOutcome?) {
        DispatchQueue.main.async {
            if let outcome, outcome.success {
                withAnimation(DesignSystem.Animation.snappy) {
                    launchState = .idle
                }
            } else {
                let errorMessage = outcome?.error?.errorDescription ?? "Launch failed"
                withAnimation(DesignSystem.Animation.snappy) {
                    launchState = .error(errorMessage)
                }
            }
        }
    }
}

// MARK: - Profile Store Adapter for Popover

/// Adapter that wraps SwitcherProfileStore for use with launch services.
private final class PopoverSwitcherProfileAdapter: SwitcherProfileStoreAdapter {
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
