import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Account Switcher Settings View

/// Settings view for managing account switcher profiles.
/// Supports browser profiles (Chrome, Safari) and CLI profiles (Codex, Claude, OpenCode).
///
/// Security properties (VAL-SETTINGS-008):
/// - No cookie/session import or raw credential persistence
/// - Only non-sensitive launch metadata is stored
/// - OAuth boundary messaging is explicit
struct AccountSwitcherSettingsView: View {
    let dataStore: DataStore

    @State private var profiles: [SwitcherProfileRecord] = []
    @State private var activeProfileID: String?
    @State private var activeProfileState: SwitcherActiveProfileState = .init(activeProfileID: nil)
    @State private var isLoading = true
    @State private var error: String?
    @State private var profileForAccountChange: SwitcherProfileRecord?
    @State private var reconnectingCLIProfileID: String?
    @State private var pendingCLIAccountUpdate: PendingCLIAccountUpdate?
    @State private var showingReconnectConfirmation = false
    @State private var reconnectDestination: AccountChangeDestination?
    @State private var reconnectProfile: SwitcherProfileRecord?
    @State private var expandedProviderKeys: Set<String> = []
    @State private var connectingProviderKey: String?
    @State private var quotaService = ProviderQuotaService.shared

    // Sheet states
    @State private var showingCreateSheet = false
    @State private var showingEditSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var profileToEdit: SwitcherProfileRecord?
    @State private var profileToDelete: SwitcherProfileRecord?

    // Edit form state
    @State private var editFormName = ""
    @State private var editFormTargetKind: SwitcherProfileTargetKind = .browser
    @State private var editFormBrowserType: SwitcherBrowserProfileType = .chrome
    @State private var editFormCLIType: SwitcherCLIProfileType = .claude
    @State private var editFormProfileIdentifier = ""
    @State private var editFormWorkingDirectory = ""
    @State private var editFormAdditionalArgs = ""
    @State private var editFormEnvKeys = ""
    @State private var editFormValidationError: String?
    @State private var editFormDuplicateError: String?
    @State private var isSaving = false

    private let supportedTargets = ["Google Chrome", "Safari", "Codex", "Claude Code", "OpenCode"]

    private struct PendingCLIAccountUpdate: Identifiable {
        let id: String
        let updatedProfile: SwitcherProfileRecord
        let previousAccount: String?
        let detectedAccount: String?
        let canSaveAsNew: Bool
    }

    var body: some View {
        withReconnectConfirmation(
            appliedTo: withPendingCLIAccountAlert(
                appliedTo: withDeleteProfileAlert(
                appliedTo: ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                // OAuth boundary messaging (VAL-SETTINGS-007, VAL-SETTINGS-016)
                boundaryMessagingCard
                if let error {
                    errorBanner(error)
                }

                if isLoading {
                    loadingView
                } else if profiles.isEmpty {
                    emptyStateView
                } else {
                    profileListView
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(settingsBackground)
        .scrollContentBackground(.hidden)
        .onAppear {
            loadProfiles()
            refreshQuotaSnapshotsIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            enrichAndReload()
            refreshQuotaSnapshotsIfNeeded()
        }
        .sheet(isPresented: $showingCreateSheet) {
            createProfileSheet
        }
        .sheet(isPresented: $showingEditSheet) {
            if let profile = profileToEdit {
                editProfileSheet(profile: profile)
            }
        }
        .sheet(isPresented: Binding(
            get: { profileForAccountChange != nil },
            set: { isPresented in
                if !isPresented {
                    profileForAccountChange = nil
                }
            }
        )) {
            if let profile = profileForAccountChange {
                AccountDestinationPickerSheet(
                    profileName: profile.displayName,
                    destinations: availableAccountChangeDestinations(for: profile),
                    onSelect: { destination in
                        openAccountChangeDestination(destination, for: profile)
                    },
                    onCancel: {
                        profileForAccountChange = nil
                    }
                )
            }
        }
            )
        )
        )
    }

    // MARK: - Background

    private func withDeleteProfileAlert<Content: View>(appliedTo content: Content) -> some View {
        content.alert("Delete Profile?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                profileToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    deleteProfile(profile)
                }
            }
        } message: {
            Text(deleteProfileMessage)
        }
    }

    private func withPendingCLIAccountAlert<Content: View>(appliedTo content: Content) -> some View {
        content.alert(
            "Update connected account?",
            isPresented: Binding(
                get: { pendingCLIAccountUpdate != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingCLIAccountUpdate = nil
                    }
                }
            )
        ) {
            Button("Keep Existing", role: .cancel) {
                pendingCLIAccountUpdate = nil
            }
            if let pendingUpdate = pendingCLIAccountUpdate, pendingUpdate.canSaveAsNew {
                Button("Save as New") {
                    persistNewCLIProfile(pendingUpdate)
                    pendingCLIAccountUpdate = nil
                }
            }
            Button("Replace Existing") {
                if let pendingCLIAccountUpdate {
                    persistCLIProfileUpdate(pendingCLIAccountUpdate.updatedProfile)
                }
                pendingCLIAccountUpdate = nil
            }
        } message: {
            if let pendingCLIAccountUpdate {
                Text(pendingCLIAccountUpdateMessage(pendingCLIAccountUpdate))
            }
        }
    }

    private func withReconnectConfirmation<Content: View>(appliedTo content: Content) -> some View {
        content.alert(
            "Finished signing in?",
            isPresented: $showingReconnectConfirmation
        ) {
            Button("Re-scan Now") {
                guard let profile = reconnectProfile else { return }
                let destination = reconnectDestination
                reconnectProfile = nil
                reconnectDestination = nil
                Task { @MainActor in
                    if let updatedProfile = await refreshedBrowserProfile(profile, expecting: destination) {
                        do {
                            _ = try dataStore.switcherStore.update(updatedProfile)
                        } catch {
                            self.error = "Failed to refresh browser profile: \(error.localizedDescription)"
                        }
                    } else if let destination, destination.browserServiceProvider != nil {
                        self.error = "I couldn’t confirm the new \(destination.label) session in this browser profile yet."
                    }
                    enrichAndReload()
                }
            }
            Button("Cancel", role: .cancel) {
                reconnectProfile = nil
                reconnectDestination = nil
            }
        } message: {
            if let destination = reconnectDestination {
                Text("After signing in to \(destination.label), re-scan to update your profile with the new account.")
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    private var settingsBackground: some View {
        if colorScheme == .light {
            LinearGradient(
                colors: [
                    Color(hex: "F3E8E6"),
                    Color(hex: "F5E4DE"),
                    Color(hex: "F0DDD4"),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            DesignSystem.Colors.background
        }
    }

    // MARK: - OAuth Boundary Messaging

    /// Explicit OAuth/session boundary copy (VAL-SETTINGS-007, VAL-SETTINGS-016)
    private var boundaryMessagingCard: some View {
        GlassCard {
            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(DesignSystem.Colors.amber)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Session Boundaries")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text("Google, Apple, and ChatGPT login sessions are managed in your browser or at their websites. BurnBar only stores profile references for launching with the correct identity — no credentials are imported or stored.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                Spacer()
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session boundary information: Google, Apple, and ChatGPT login sessions are managed externally. BurnBar only stores profile launch references.")
    }

    private func errorBanner(_ message: String) -> some View {
        GlassCard {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(DesignSystem.Colors.error)

                Text(message)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    error = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading profiles...")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSystem.Spacing.xxl)
    }

    // MARK: - Empty State

    /// Empty state with supported targets (VAL-SETTINGS-002)
    private var emptyStateView: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            GlassCard {
                VStack(spacing: DesignSystem.Spacing.md) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    Text("No Profiles Yet")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text("Create your first profile to start switching between accounts.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(DesignSystem.Spacing.xl)
                .frame(maxWidth: .infinity)
            }

            // Setup wizard button
            Button {
                WindowManager.shared.openSwitcherOnboardingWizard(
                    dataStore: dataStore,
                    settingsManager: SettingsManager.shared,
                    onOpenSettings: {}
                )
            } label: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Setup Wizard")
                }
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.amber)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .strokeBorder(DesignSystem.Colors.amber, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open profile setup wizard")

            // Supported targets section (VAL-SETTINGS-002)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Supported Targets")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        supportedTargetRow(logoName: "ChromeLogo", sfFallback: "globe", title: "Google Chrome", subtitle: "Browser profile")
                        Divider().background(DesignSystem.Colors.borderSubtle)
                        supportedTargetRow(logoName: "SafariLogo", sfFallback: "safari", title: "Safari", subtitle: "Browser profile")
                        Divider().background(DesignSystem.Colors.borderSubtle)
                        supportedTargetRow(logoName: "CodexLogo", sfFallback: "terminal.fill", title: "Codex", subtitle: "CLI profile")
                        Divider().background(DesignSystem.Colors.borderSubtle)
                        supportedTargetRow(logoName: "ClaudeCodeLogo", sfFallback: "terminal.fill", title: "Claude Code", subtitle: "CLI profile")
                        Divider().background(DesignSystem.Colors.borderSubtle)
                        supportedTargetRow(logoName: nil, sfFallback: "terminal.fill", title: "OpenCode", subtitle: "CLI profile")
                    }
                    .padding(DesignSystem.Spacing.md)
                }
            }

            // Add profile button
            Button {
                showingCreateSheet = true
            } label: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Profile")
                }
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(DesignSystem.Colors.amber)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add first profile")
        }
    }

    private func supportedTargetRow(logoName: String?, sfFallback: String, title: String, subtitle: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Group {
                if let logoName, NSImage(named: logoName) != nil {
                    Image(logoName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: sfFallback)
                        .font(.system(size: 14))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(subtitle)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer()
        }
    }

    // MARK: - Profile List

    // Groups of profiles keyed by a stable section label
    private struct ProfileGroup {
        let key: String
        let label: String
        let icon: String
        let bundledLogoName: String?
        let color: Color
        let profiles: [(index: Int, profile: SwitcherProfileRecord)]
        let connectedCount: Int
        let enabledCount: Int
        let cliType: SwitcherCLIProfileType?
        let browserType: SwitcherBrowserProfileType?

        /// Whether this group has a real bundled logo asset.
        var hasBundledLogo: Bool {
            guard let name = bundledLogoName else { return false }
            return NSImage(named: name) != nil
        }
    }

    private var profileGroups: [ProfileGroup] {
        let indexed = Array(profiles.enumerated())

        let cliOrder: [(SwitcherCLIProfileType, String, String, Color)] = [
            (.claude, "Claude Code", "terminal.fill", Color(hex: "CC785C")),
            (.codex,  "Codex",       "terminal.fill", Color(hex: "00A67E")),
            (.opencode, "OpenCode",  "terminal.fill", DesignSystem.Colors.whimsy),
        ]

        var groups: [ProfileGroup] = []

        for (cliType, label, icon, color) in cliOrder {
            let matching = indexed.filter { $0.element.targetKind == .cli && $0.element.cliType == cliType }
            if !matching.isEmpty {
                let bundledName: String? = switch cliType {
                case .claude: "ClaudeCodeLogo"
                case .codex: "CodexLogo"
                case .opencode: nil
                }
                groups.append(ProfileGroup(
                    key: cliType.rawValue,
                    label: label,
                    icon: icon,
                    bundledLogoName: bundledName,
                    color: color,
                    profiles: matching.map { (index: $0.offset, profile: $0.element) },
                    connectedCount: matching.map(\.element).filter(isConnectedProfile).count,
                    enabledCount: matching.map(\.element).filter { !$0.isDisabled }.count,
                    cliType: cliType,
                    browserType: nil
                ))
            }
        }

        let chromeProfiles = indexed.filter { $0.element.targetKind == .browser && $0.element.browserType == .chrome }
        if !chromeProfiles.isEmpty {
            groups.append(ProfileGroup(
                key: "chrome",
                label: "Google Chrome",
                icon: "globe",
                bundledLogoName: "ChromeLogo",
                color: Color(hex: "4285F4"),
                profiles: chromeProfiles.map { (index: $0.offset, profile: $0.element) },
                connectedCount: chromeProfiles.map(\.element).filter(isConnectedProfile).count,
                enabledCount: chromeProfiles.map(\.element).filter { !$0.isDisabled }.count,
                cliType: nil,
                browserType: .chrome
            ))
        }

        let safariProfiles = indexed.filter { $0.element.targetKind == .browser && $0.element.browserType == .safari }
        if !safariProfiles.isEmpty {
            groups.append(ProfileGroup(
                key: "safari",
                label: "Safari",
                icon: "safari",
                bundledLogoName: "SafariLogo",
                color: Color(hex: "0071E3"),
                profiles: safariProfiles.map { (index: $0.offset, profile: $0.element) },
                connectedCount: safariProfiles.map(\.element).filter(isConnectedProfile).count,
                enabledCount: safariProfiles.map(\.element).filter { !$0.isDisabled }.count,
                cliType: nil,
                browserType: .safari
            ))
        }

        return groups
    }

    /// Profile list with active state indicators (VAL-SETTINGS-014)
    private var profileListView: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(profiles.count) Account\(profiles.count == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                    Text("Manage provider-specific accounts, keep reserves ready, and connect new logins without leaving BurnBar.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                Button {
                    showingCreateSheet = true
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "plus.circle")
                        Text("Manual Add")
                    }
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.amber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add new profile")
                .keyboardShortcut("n", modifiers: .command)
            }

            // Provider-grouped sections
            ForEach(profileGroups, id: \.key) { group in
                providerSection(group)
            }

            Text("Codex and Claude stay available at the same time. Primary and reserve order only apply within the same provider, so switching Codex accounts never deactivates Claude.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    @ViewBuilder
    private func providerSection(_ group: ProfileGroup) -> some View {
        let isExpanded = expandedProviderKeys.contains(group.key) || group.profiles.count <= 1 || group.profiles.contains(where: { $0.profile.isDisabled })

        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Group {
                            if group.hasBundledLogo {
                                Image(group.bundledLogoName!)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                Circle()
                                    .fill(group.color.opacity(group.enabledCount > 0 ? 1 : 0.35))
                            }
                        }
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Text(group.label)
                                    .font(DesignSystem.Typography.headline)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                                if group.connectedCount > 0 {
                                    Text("\(group.connectedCount) connected")
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(DesignSystem.Colors.success)
                                        .clipShape(Capsule())
                                }
                            }

                            Text(providerSummary(for: group))
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer()

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Button {
                            Task { @MainActor in
                                await addAccount(for: group)
                            }
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                if connectingProviderKey == group.key {
                                    ProgressView()
                                        .scaleEffect(0.55)
                                        .frame(width: 10, height: 10)
                                } else {
                                    Image(systemName: group.connectedCount == 0 ? "link.badge.plus" : "plus.circle")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                Text(group.connectedCount == 0 ? "Connect" : "Add Account")
                                    .font(DesignSystem.Typography.tiny)
                            }
                            .foregroundStyle(group.color)
                        }
                        .buttonStyle(.plain)
                        .disabled(connectingProviderKey == group.key)
                        .accessibilityLabel("\(group.connectedCount == 0 ? "Connect" : "Add another") \(group.label) account")

                        if group.profiles.count > 1 {
                            Button {
                                toggleProviderExpansion(group.key)
                            } label: {
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isExpanded ? "Collapse \(group.label) accounts" : "Expand \(group.label) accounts")
                        }
                    }
                }

                if isExpanded {
                    VStack(spacing: 2) {
                        ForEach(Array(group.profiles.enumerated()), id: \.element.profile.id) { groupIndex, item in
                            ProfileRowView(
                                profile: item.profile,
                                priorityIndex: item.index + 1,
                                fallbackIndex: group.profiles.count > 1 ? groupIndex + 1 : nil,
                                providerColor: group.color,
                                quotaLookup: { provider in
                                    quotaService.snapshot(for: provider)
                                },
                                isActive: activeProfileID == item.profile.id,
                                isChangingAccount: reconnectingCLIProfileID == item.profile.id || connectingProviderKey == item.profile.id,
                                canMoveUp: groupIndex > 0,
                                canMoveDown: groupIndex < group.profiles.count - 1,
                                canSwap: group.profiles.count > 1,
                                canSetPrimary: group.profiles.count > 1 && groupIndex > 0 && !item.profile.isDisabled,
                                canToggleDisabled: group.enabledCount > 1 || item.profile.isDisabled,
                                onSetActive: { makePrimary(item.profile, in: group) },
                                onSwap: { swapProfileWithinGroup(item.profile, in: group) },
                                onMoveUp: { moveProfileWithinGroup(item.profile, in: group, direction: .up) },
                                onMoveDown: { moveProfileWithinGroup(item.profile, in: group, direction: .down) },
                                onToggleDisabled: { toggleDisabled(item.profile, in: group) },
                                onChangeAccount: {
                                    requestAccountChange(for: item.profile)
                                },
                                onEdit: { editProfile(item.profile) },
                                onDelete: { confirmDeleteProfile(item.profile) }
                            )
                        }
                    }
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private func providerSummary(for group: ProfileGroup) -> String {
        if group.connectedCount == 0 {
            return group.browserType == nil
                ? "No connected accounts yet. Add one to start rotating within this provider."
                : "No confirmed session detected yet. Connect one to launch with this provider."
        }

        if group.enabledCount > 1 {
            return "\(group.enabledCount) ready for same-provider handoff. Primary stays first and reserves wait behind it."
        }

        if group.profiles.contains(where: { $0.profile.isDisabled }) {
            return "Some accounts are paused. Re-enable them when you want them back in the rotation."
        }

        return "One account is live. Add another to keep a reserve ready."
    }

    private func toggleProviderExpansion(_ key: String) {
        if expandedProviderKeys.contains(key) {
            expandedProviderKeys.remove(key)
        } else {
            expandedProviderKeys.insert(key)
        }
    }

    private func isConnectedProfile(_ profile: SwitcherProfileRecord) -> Bool {
        switch profile.targetKind {
        case .cli:
            if let accountDescription = profile.cliMetadata?.accountDescription,
               !accountDescription.isEmpty {
                return true
            }
            return false
        case .browser:
            if let email = profile.browserMetadata?.accountEmail,
               !email.isEmpty {
                return true
            }
            return !(profile.browserMetadata?.serviceIdentities.isEmpty ?? true)
        }
    }

    // MARK: - Create Profile Sheet

    private var createProfileSheet: some View {
        NavigationView {
            ProfileFormView(
                title: "Create Profile",
                name: $editFormName,
                targetKind: $editFormTargetKind,
                browserType: $editFormBrowserType,
                cliType: $editFormCLIType,
                profileIdentifier: $editFormProfileIdentifier,
                workingDirectory: $editFormWorkingDirectory,
                additionalArgs: $editFormAdditionalArgs,
                envKeys: $editFormEnvKeys,
                validationError: $editFormValidationError,
                duplicateError: $editFormDuplicateError,
                isSaving: isSaving,
                boundaryCopyVisible: true,
                onSave: createProfile,
                onCancel: { showingCreateSheet = false }
            )
            .navigationTitle("Create Profile")
        }
        .frame(width: 480, height: 520)
        .onAppear { resetForm() }
    }

    // MARK: - Edit Profile Sheet

    private func editProfileSheet(profile: SwitcherProfileRecord) -> some View {
        NavigationView {
            ProfileFormView(
                title: "Edit Profile",
                name: $editFormName,
                targetKind: $editFormTargetKind,
                browserType: $editFormBrowserType,
                cliType: $editFormCLIType,
                profileIdentifier: $editFormProfileIdentifier,
                workingDirectory: $editFormWorkingDirectory,
                additionalArgs: $editFormAdditionalArgs,
                envKeys: $editFormEnvKeys,
                validationError: $editFormValidationError,
                duplicateError: $editFormDuplicateError,
                isSaving: isSaving,
                boundaryCopyVisible: true,
                onSave: { saveProfile(profile) },
                onCancel: {
                    showingEditSheet = false
                    profileToEdit = nil
                }
            )
            .navigationTitle("Edit Profile")
        }
        .frame(width: 480, height: 520)
    }

    // MARK: - Data Operations

    private func loadProfiles() {
        isLoading = true
        do {
            let fetchedProfiles = try dataStore.switcherStore.fetchAllProfiles()
            profiles = enrichProfilesForDisplay(fetchedProfiles)
            let state = try dataStore.switcherStore.validateAndRecoverActiveProfile()
            activeProfileID = resolvedActiveProfileID(from: state, profiles: profiles)
            activeProfileState = state
        } catch {
            self.error = "Failed to load profiles: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func enrichAndReload() {
        do {
            let fetchedProfiles = try dataStore.switcherStore.fetchAllProfiles()
            profiles = enrichProfilesForDisplay(fetchedProfiles)
            let state = try dataStore.switcherStore.validateAndRecoverActiveProfile()
            activeProfileID = resolvedActiveProfileID(from: state, profiles: profiles)
            activeProfileState = state
        } catch {
            self.error = "Failed to reload profiles: \(error.localizedDescription)"
        }
    }

    private func refreshQuotaSnapshotsIfNeeded() {
        Task { @MainActor in
            await quotaService.refreshIfNeeded(dataStore: dataStore)
        }
    }

    private func resolvedActiveProfileID(from state: SwitcherActiveProfileState, profiles: [SwitcherProfileRecord]) -> String? {
        if let activeProfileID = state.activeProfileID,
           profiles.contains(where: { $0.id == activeProfileID && !$0.isDisabled }) {
            return activeProfileID
        }
        return profiles.first(where: { !$0.isDisabled })?.id
    }

    private func refreshedBrowserProfile(
        _ profile: SwitcherProfileRecord,
        expecting destination: AccountChangeDestination?
    ) async -> SwitcherProfileRecord? {
        guard profile.targetKind == .browser,
              let browserType = profile.browserType else {
            return nil
        }

        let expectedProvider = destination?.browserServiceProvider

        switch browserType {
        case .chrome:
            let profileIdentifier = profile.browserMetadata?.profileIdentifier ?? "Default"
            for attempt in 0..<6 {
                if let discovered = ChromeProfileDiscovery.discoverProfiles().first(where: { $0.folderKey == profileIdentifier }) {
                    let updated = refreshedBrowserProfileRecord(profile: profile, discoveredChromeProfile: discovered)
                    if expectedProvider == nil || updated.browserMetadata?.serviceIdentities.contains(where: { $0.provider == expectedProvider }) == true {
                        return updated
                    }
                }

                if attempt < 5 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            return nil

        case .safari:
            return profile
        }
    }

    private func enrichProfilesForDisplay(_ fetchedProfiles: [SwitcherProfileRecord]) -> [SwitcherProfileRecord] {
        let chromeProfilesByFolder = Dictionary(
            uniqueKeysWithValues: ChromeProfileDiscovery.discoverProfiles().map { ($0.folderKey, $0) }
        )

        return fetchedProfiles.map { profile in
            switch profile.targetKind {
            case .browser:
                guard let browserType = profile.browserType,
                      let metadata = profile.browserMetadata else {
                    return profile
                }

                switch browserType {
                case .chrome:
                    guard let discovered = chromeProfilesByFolder[metadata.profileIdentifier] else {
                        return profile
                    }

                    return SwitcherProfileRecord(
                        id: profile.id,
                        targetKind: .browser,
                        browserType: .chrome,
                        browserMetadata: SwitcherBrowserProfileMetadata(
                            profileIdentifier: metadata.profileIdentifier,
                            displayLabel: metadata.displayLabel ?? discovered.displayName,
                            accountEmail: metadata.accountEmail ?? discovered.email,
                            providerIdentifier: metadata.providerIdentifier ?? "google",
                            serviceIdentities: discovered.serviceIdentities.isEmpty ? metadata.serviceIdentities : discovered.serviceIdentities,
                            isDisabled: metadata.isDisabled
                        ),
                        sortKey: profile.sortKey,
                        createdAt: profile.createdAt,
                        updatedAt: profile.updatedAt
                    )

                case .safari:
                    guard metadata.providerIdentifier == nil else { return profile }
                    return SwitcherProfileRecord(
                        id: profile.id,
                        targetKind: .browser,
                        browserType: .safari,
                        browserMetadata: SwitcherBrowserProfileMetadata(
                            profileIdentifier: metadata.profileIdentifier,
                            displayLabel: metadata.displayLabel,
                            accountEmail: metadata.accountEmail,
                            providerIdentifier: "apple",
                            serviceIdentities: metadata.serviceIdentities,
                            isDisabled: metadata.isDisabled
                        ),
                        sortKey: profile.sortKey,
                        createdAt: profile.createdAt,
                        updatedAt: profile.updatedAt
                    )
                }

            case .cli:
                guard let cliType = profile.cliType,
                      let metadata = profile.cliMetadata else {
                    return profile
                }

                let authInfo = CLIAuthDiscovery.discoverAuthState(
                    for: cliType,
                    configDirectoryOverride: metadata.configDirectory
                )
                guard authInfo.accountDescription != metadata.accountDescription else {
                    return profile
                }

                return SwitcherProfileRecord(
                    id: profile.id,
                    targetKind: .cli,
                    cliType: cliType,
                    cliMetadata: SwitcherCLIProfileMetadata(
                        workingDirectory: metadata.workingDirectory,
                        additionalArgs: metadata.additionalArgs,
                        envKeysToPass: metadata.envKeysToPass,
                        displayLabel: metadata.displayLabel,
                        configDirectory: metadata.configDirectory,
                        accountDescription: authInfo.accountDescription,
                        lastQuotaExhaustedAt: metadata.lastQuotaExhaustedAt,
                        exhaustedUntil: metadata.exhaustedUntil,
                        lastQuotaExhaustionDetail: metadata.lastQuotaExhaustionDetail,
                        isDisabled: metadata.isDisabled
                    ),
                    sortKey: profile.sortKey,
                    createdAt: profile.createdAt,
                    updatedAt: profile.updatedAt
                )
            }
        }
    }

    private func addAccount(for group: ProfileGroup) async {
        connectingProviderKey = group.key
        defer {
            connectingProviderKey = nil
            expandedProviderKeys.insert(group.key)
        }

        switch group.cliType {
        case .codex, .claude:
            await addCLIAccount(for: group)
        case .opencode:
            editFormTargetKind = .cli
            editFormCLIType = .opencode
            showingCreateSheet = true
        case .none:
            switch group.browserType {
            case .chrome:
                let discovery = SwitcherDiscoveryService()
                if await discovery.addDifferentGoogleAccount(dataStore: dataStore) == nil {
                    error = "BurnBar couldn’t add another Google Chrome account."
                }
            case .safari:
                let discovery = SwitcherDiscoveryService()
                if await discovery.addDifferentAppleAccount(dataStore: dataStore) == nil {
                    error = "BurnBar couldn’t add another Safari / Apple account."
                }
            case .none:
                break
            }
        }

        enrichAndReload()
    }

    private func addCLIAccount(for group: ProfileGroup) async {
        guard let cliType = group.cliType else { return }

        let placeholder = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(displayLabel: cliType.displayName),
            sortKey: 0
        )

        let coordinator = SwitcherCLIAuthCoordinator()
        switch await coordinator.reconnect(profile: placeholder) {
        case .readyToPersist(let updatedProfile):
            persistNewCLIAccount(updatedProfile, for: cliType)
        case .requiresConfirmation(let updatedProfile, _, _):
            persistNewCLIAccount(updatedProfile, for: cliType)
        case .cancelled:
            break
        case .failed(let message):
            error = message
        }
    }

    private func persistNewCLIAccount(_ updatedProfile: SwitcherProfileRecord, for cliType: SwitcherCLIProfileType) {
        guard let metadata = updatedProfile.cliMetadata else { return }

        let preferredLabel: String?
        if let accountDescription = metadata.accountDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountDescription.isEmpty {
            preferredLabel = accountDescription
        } else {
            preferredLabel = metadata.displayLabel
        }

        do {
            let newProfile = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: cliType,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: metadata.workingDirectory,
                    additionalArgs: metadata.additionalArgs,
                    envKeysToPass: metadata.envKeysToPass,
                    displayLabel: preferredLabel,
                    configDirectory: metadata.configDirectory,
                    accountDescription: metadata.accountDescription,
                    lastQuotaExhaustedAt: metadata.lastQuotaExhaustedAt,
                    exhaustedUntil: metadata.exhaustedUntil,
                    lastQuotaExhaustionDetail: metadata.lastQuotaExhaustionDetail,
                    isDisabled: metadata.isDisabled
                ),
                sortKey: 0
            )
            _ = try dataStore.switcherStore.create(newProfile)
        } catch {
            self.error = "Failed to add \(cliType.displayName) account: \(error.localizedDescription)"
        }
    }

    private func toggleDisabled(_ profile: SwitcherProfileRecord, in group: ProfileGroup) {
        let nextDisabledState = !profile.isDisabled
        if nextDisabledState && group.enabledCount <= 1 {
            error = "Keep at least one \(group.label) account enabled."
            return
        }

        do {
            let updatedProfile = profileWithDisabledState(profile, isDisabled: nextDisabledState)
            _ = try dataStore.switcherStore.update(updatedProfile)

            if nextDisabledState, activeProfileID == profile.id {
                let fallbackProfileID = profiles.first(where: { $0.id != profile.id && !$0.isDisabled })?.id
                try dataStore.switcherStore.setActiveProfile(fallbackProfileID)
            }

            enrichAndReload()
        } catch {
            self.error = "Failed to update \(profile.displayName): \(error.localizedDescription)"
        }
    }

    private func profileWithDisabledState(_ profile: SwitcherProfileRecord, isDisabled: Bool) -> SwitcherProfileRecord {
        switch profile.targetKind {
        case .browser:
            return SwitcherProfileRecord(
                id: profile.id,
                targetKind: .browser,
                browserType: profile.browserType,
                browserMetadata: SwitcherBrowserProfileMetadata(
                    profileIdentifier: profile.browserMetadata?.profileIdentifier ?? "Default",
                    displayLabel: profile.browserMetadata?.displayLabel,
                    accountEmail: profile.browserMetadata?.accountEmail,
                    providerIdentifier: profile.browserMetadata?.providerIdentifier,
                    serviceIdentities: profile.browserMetadata?.serviceIdentities ?? [],
                    isDisabled: isDisabled
                ),
                sortKey: profile.sortKey,
                createdAt: profile.createdAt
            )
        case .cli:
            return SwitcherProfileRecord(
                id: profile.id,
                targetKind: .cli,
                cliType: profile.cliType,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: profile.cliMetadata?.workingDirectory,
                    additionalArgs: profile.cliMetadata?.additionalArgs ?? [],
                    envKeysToPass: profile.cliMetadata?.envKeysToPass ?? [],
                    displayLabel: profile.cliMetadata?.displayLabel,
                    configDirectory: profile.cliMetadata?.configDirectory,
                    accountDescription: profile.cliMetadata?.accountDescription,
                    lastQuotaExhaustedAt: profile.cliMetadata?.lastQuotaExhaustedAt,
                    exhaustedUntil: profile.cliMetadata?.exhaustedUntil,
                    lastQuotaExhaustionDetail: profile.cliMetadata?.lastQuotaExhaustionDetail,
                    isDisabled: isDisabled
                ),
                sortKey: profile.sortKey,
                createdAt: profile.createdAt
            )
        }
    }

    private func requestAccountChange(for profile: SwitcherProfileRecord) {
        error = nil
        switch profile.targetKind {
        case .browser:
            if let preferredDestination = preferredAccountChangeDestination(for: profile) {
                openAccountChangeDestination(preferredDestination, for: profile)
                return
            }
            profileForAccountChange = profile
        case .cli:
            guard profile.cliType == .codex || profile.cliType == .claude else {
                error = "This CLI does not support account reconnect yet."
                return
            }
            reconnectingCLIProfileID = profile.id
            Task { @MainActor in
                await reconnectCLIProfile(profile)
            }
        }
    }

    private func reconnectCLIProfile(_ profile: SwitcherProfileRecord) async {
        defer { reconnectingCLIProfileID = nil }

        let coordinator = SwitcherCLIAuthCoordinator()
        switch await coordinator.reconnect(profile: profile) {
        case .readyToPersist(let updatedProfile):
            persistCLIProfileUpdate(updatedProfile)
        case .requiresConfirmation(let updatedProfile, let previousAccount, let detectedAccount):
            pendingCLIAccountUpdate = PendingCLIAccountUpdate(
                id: profile.id,
                updatedProfile: updatedProfile,
                previousAccount: previousAccount,
                detectedAccount: detectedAccount,
                canSaveAsNew: normalizedConfigDirectory(profile.cliMetadata?.configDirectory)
                    != normalizedConfigDirectory(updatedProfile.cliMetadata?.configDirectory)
            )
        case .cancelled:
            break
        case .failed(let message):
            error = message
        }
    }

    private func persistCLIProfileUpdate(_ updatedProfile: SwitcherProfileRecord) {
        do {
            _ = try dataStore.switcherStore.update(updatedProfile)
            loadProfiles()
        } catch {
            self.error = "Failed to update CLI profile: \(error.localizedDescription)"
        }
    }

    private func persistNewCLIProfile(_ pendingUpdate: PendingCLIAccountUpdate) {
        guard let cliType = pendingUpdate.updatedProfile.cliType,
              let metadata = pendingUpdate.updatedProfile.cliMetadata else {
            error = "Failed to save the new CLI profile."
            return
        }

        do {
            let newProfile = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: cliType,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: metadata.workingDirectory,
                    additionalArgs: metadata.additionalArgs,
                    envKeysToPass: metadata.envKeysToPass,
                    displayLabel: metadata.displayLabel,
                    configDirectory: metadata.configDirectory,
                    accountDescription: metadata.accountDescription,
                    lastQuotaExhaustedAt: metadata.lastQuotaExhaustedAt,
                    exhaustedUntil: metadata.exhaustedUntil,
                    lastQuotaExhaustionDetail: metadata.lastQuotaExhaustionDetail,
                    isDisabled: metadata.isDisabled
                ),
                sortKey: 0
            )
            _ = try dataStore.switcherStore.create(newProfile)
            loadProfiles()
        } catch {
            self.error = "Failed to save the new CLI profile: \(error.localizedDescription)"
        }
    }

    private func pendingCLIAccountUpdateMessage(_ pendingUpdate: PendingCLIAccountUpdate) -> String {
        let previousAccount = pendingUpdate.previousAccount ?? "an unknown account"
        let detectedAccount = pendingUpdate.detectedAccount ?? "a different account"

        if pendingUpdate.canSaveAsNew {
            let cliName = pendingUpdate.updatedProfile.cliType?.displayName ?? "CLI"
            return "This profile was connected to \(previousAccount), but Terminal login detected \(detectedAccount). BurnBar can replace this profile or save the newly connected account as another \(cliName) profile."
        }

        return "This profile was connected to \(previousAccount), but Terminal login detected \(detectedAccount). Replace this profile to use the newly connected account?"
    }

    private var deleteProfileMessage: String {
        let displayName = profileToDelete?.displayName ?? ""
        return "This will permanently delete the profile '\(displayName)'. This action cannot be undone."
    }

    private func normalizedConfigDirectory(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func openAccountChangeDestination(_ destination: AccountChangeDestination, for profile: SwitcherProfileRecord) {
        // Google and Apple trigger real OAuth flows that capture tokens
        switch destination {
        case .googleAccount, .appleID:
            Task { @MainActor in
                error = nil
                let discovery = SwitcherDiscoveryService()
                let updated = await discovery.refreshBrowserProfileAuthentication(profile, dataStore: dataStore)
                if updated != nil {
                    profileForAccountChange = nil
                    loadProfiles()
                } else {
                    error = "Sign-in failed or was cancelled."
                }
            }
            return

        case .openAI, .claude:
            // Web-only destinations: open the login page in the browser profile,
            // then prompt the user to confirm so we can re-scan for the new session
            guard profile.targetKind == .browser else {
                openExternalAccountDestination(destination)
                return
            }

            Task { @MainActor in
                error = nil

                let service = SwitcherBrowserLaunchService(
                    profileStore: SettingsSwitcherProfileAdapter(store: dataStore.switcherStore)
                )
                let outcome = await service.launchBrowser(for: profile.id, opening: [destination.url])
                guard outcome.success else {
                    error = outcome.error?.errorDescription ?? "Failed to open \(destination.label)."
                    return
                }

                profileForAccountChange = nil

                // Give the user a moment to see the page, then prompt to confirm
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                showingReconnectConfirmation = true
                reconnectDestination = destination
                reconnectProfile = profile
            }
            return
        }
    }

    private func openExternalAccountDestination(_ destination: AccountChangeDestination) {
        guard NSWorkspace.shared.open(destination.url) else {
            error = "Failed to open \(destination.label)."
            return
        }
    }

    private func availableAccountChangeDestinations(for profile: SwitcherProfileRecord) -> [AccountChangeDestination] {
        guard profile.targetKind == .browser else {
            return serviceDestinations(for: profile)
        }

        return BrowserAccountChangePlanner.destinations(
            providerIdentifier: browserProviderIdentifier(for: profile),
            serviceIdentities: profile.browserMetadata?.serviceIdentities ?? []
        )
    }

    private func defaultAccountChangeDestination(for profile: SwitcherProfileRecord) -> AccountChangeDestination? {
        switch profile.cliType {
        case .codex:
            return .openAI
        case .claude:
            return .claude
        case .opencode, .none:
            return nil
        }
    }

    private func preferredAccountChangeDestination(for profile: SwitcherProfileRecord) -> AccountChangeDestination? {
        let serviceDestinations = serviceDestinations(for: profile)
        return serviceDestinations.count == 1 ? serviceDestinations[0] : nil
    }

    private func serviceDestinations(for profile: SwitcherProfileRecord) -> [AccountChangeDestination] {
        let serviceIdentities = profile.browserMetadata?.serviceIdentities ?? []
        let destinations = serviceIdentities.map { identity -> AccountChangeDestination in
            switch identity.provider {
            case .openAI:
                return .openAI
            case .claude:
                return .claude
            }
        }

        var uniqueDestinations: [AccountChangeDestination] = []
        for destination in destinations where !uniqueDestinations.contains(destination) {
            uniqueDestinations.append(destination)
        }
        return uniqueDestinations
    }

    private func browserProviderIdentifier(for profile: SwitcherProfileRecord) -> String {
        if let provider = profile.browserMetadata?.providerIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty {
            return provider.lowercased()
        }

        switch profile.browserType {
        case .safari:
            return "apple"
        case .chrome, .none:
            return "google"
        }
    }

    private func setActiveProfile(_ profile: SwitcherProfileRecord) {
        do {
            try dataStore.switcherStore.setActiveProfile(profile.id)
            activeProfileID = profile.id
            activeProfileState = try dataStore.switcherStore.fetchActiveProfileState()
        } catch {
            self.error = "Failed to set active profile: \(error.localizedDescription)"
        }
    }

    private func makePrimary(_ profile: SwitcherProfileRecord, in group: ProfileGroup) {
        guard let firstProfile = group.profiles.first?.profile,
              firstProfile.id != profile.id else {
            return
        }
        reorderWithinGroup(movingProfileID: profile.id, in: group, targetIndex: 0)
    }

    private func swapProfileWithinGroup(_ profile: SwitcherProfileRecord, in group: ProfileGroup) {
        let groupProfiles = group.profiles.map(\.profile)
        guard groupProfiles.count > 1,
              let sourceIndex = groupProfiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }

        let targetIndex = sourceIndex == 0 ? 1 : 0
        guard groupProfiles.indices.contains(targetIndex) else {
            return
        }

        persistGroupOrder(
            replacing: group.profiles.map(\.profile),
            in: group,
            transform: { orderedGroupProfiles in
                var updatedProfiles = orderedGroupProfiles
                updatedProfiles.swapAt(sourceIndex, targetIndex)
                return updatedProfiles
            }
        )
    }

    private func moveProfile(_ profile: SwitcherProfileRecord, direction: SwitcherProfileStore.MoveDirection) {
        do {
            try dataStore.switcherStore.moveProfile(id: profile.id, direction: direction)
            loadProfiles()
        } catch {
            self.error = "Failed to reorder profile: \(error.localizedDescription)"
        }
    }

    private func moveProfileWithinGroup(
        _ profile: SwitcherProfileRecord,
        in group: ProfileGroup,
        direction: SwitcherProfileStore.MoveDirection
    ) {
        guard let currentIndex = group.profiles.firstIndex(where: { $0.profile.id == profile.id }) else {
            return
        }

        let targetIndex: Int
        switch direction {
        case .up:
            targetIndex = currentIndex - 1
        case .down:
            targetIndex = currentIndex + 1
        }

        guard group.profiles.indices.contains(targetIndex) else {
            return
        }

        reorderWithinGroup(
            movingProfileID: profile.id,
            in: group,
            targetIndex: targetIndex
        )
    }

    private func reorderWithinGroup(
        movingProfileID: String,
        in group: ProfileGroup,
        targetIndex: Int
    ) {
        persistGroupOrder(
            replacing: group.profiles.map(\.profile),
            in: group,
            transform: { groupOrderedProfiles in
                var updatedProfiles = groupOrderedProfiles
                guard let sourceGroupIndex = updatedProfiles.firstIndex(where: { $0.id == movingProfileID }),
                      updatedProfiles.indices.contains(targetIndex) else {
                    return groupOrderedProfiles
                }

                let movedProfile = updatedProfiles.remove(at: sourceGroupIndex)
                updatedProfiles.insert(movedProfile, at: targetIndex)
                return updatedProfiles
            }
        )
    }

    private func persistGroupOrder(
        replacing groupProfiles: [SwitcherProfileRecord],
        in group: ProfileGroup,
        transform: ([SwitcherProfileRecord]) -> [SwitcherProfileRecord]
    ) {
        var orderedProfiles = profiles
        let groupIDs = Set(groupProfiles.map(\.id))
        let currentGroupOrder = orderedProfiles.filter { groupIDs.contains($0.id) }
        let updatedGroupOrder = transform(currentGroupOrder)
        guard updatedGroupOrder.map(\.id) != currentGroupOrder.map(\.id) else {
            return
        }

        var replacementIterator = updatedGroupOrder.makeIterator()
        for index in orderedProfiles.indices where groupIDs.contains(orderedProfiles[index].id) {
            orderedProfiles[index] = replacementIterator.next() ?? orderedProfiles[index]
        }

        do {
            try dataStore.switcherStore.reorderProfiles(idsInOrder: orderedProfiles.map(\.id))
            withAnimation(DesignSystem.Animation.snappy) {
                profiles = orderedProfiles
            }
            loadProfiles()
        } catch {
            self.error = "Failed to reorder \(group.label): \(error.localizedDescription)"
            loadProfiles()
        }
    }

    private func resetForm() {
        editFormName = ""
        editFormTargetKind = .browser
        editFormBrowserType = .chrome
        editFormCLIType = .claude
        editFormProfileIdentifier = ""
        editFormWorkingDirectory = ""
        editFormAdditionalArgs = ""
        editFormEnvKeys = ""
        editFormValidationError = nil
        editFormDuplicateError = nil
        isSaving = false
    }

    private func createProfile() {
        guard validateForm(excludingID: nil) else { return }
        isSaving = true

        do {
            let record = buildProfileRecord(id: UUID().uuidString)
            _ = try dataStore.switcherStore.create(record)

            // VAL-SETTINGS-009: First profile create establishes deterministic active state
            if profiles.isEmpty {
                try dataStore.switcherStore.setActiveProfile(record.id)
                activeProfileID = record.id
            }

            showingCreateSheet = false
            loadProfiles()
        } catch {
            editFormValidationError = "Failed to create profile: \(error.localizedDescription)"
        }

        isSaving = false
    }

    private func saveProfile(_ original: SwitcherProfileRecord) {
        guard validateForm(excludingID: original.id) else { return }
        isSaving = true

        do {
            let updated = SwitcherProfileRecord(
                id: original.id,
                targetKind: editFormTargetKind,
                browserType: editFormTargetKind == .browser ? editFormBrowserType : nil,
                browserMetadata: editFormTargetKind == .browser ? SwitcherBrowserProfileMetadata(
                    profileIdentifier: editFormProfileIdentifier,
                    displayLabel: editFormName.isEmpty ? nil : editFormName,
                    accountEmail: original.browserMetadata?.accountEmail,
                    providerIdentifier: original.browserMetadata?.providerIdentifier,
                    serviceIdentities: original.browserMetadata?.serviceIdentities ?? [],
                    isDisabled: original.browserMetadata?.isDisabled ?? false
                ) : nil,
                cliType: editFormTargetKind == .cli ? editFormCLIType : nil,
                cliMetadata: editFormTargetKind == .cli ? SwitcherCLIProfileMetadata(
                    workingDirectory: editFormWorkingDirectory.isEmpty ? nil : editFormWorkingDirectory,
                    additionalArgs: editFormAdditionalArgs.isEmpty ? [] : editFormAdditionalArgs.split(separator: " ").map(String.init),
                    envKeysToPass: editFormEnvKeys.isEmpty ? [] : editFormEnvKeys.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                    displayLabel: editFormName.isEmpty ? nil : editFormName,
                    configDirectory: original.cliMetadata?.configDirectory,
                    accountDescription: original.cliMetadata?.accountDescription,
                    lastQuotaExhaustedAt: original.cliMetadata?.lastQuotaExhaustedAt,
                    exhaustedUntil: original.cliMetadata?.exhaustedUntil,
                    lastQuotaExhaustionDetail: original.cliMetadata?.lastQuotaExhaustionDetail,
                    isDisabled: original.cliMetadata?.isDisabled ?? false
                ) : nil,
                sortKey: original.sortKey,
                createdAt: original.createdAt
            )

            _ = try dataStore.switcherStore.update(updated)
            showingEditSheet = false
            profileToEdit = nil
            loadProfiles()
        } catch {
            editFormValidationError = "Failed to update profile: \(error.localizedDescription)"
        }

        isSaving = false
    }

    private func editProfile(_ profile: SwitcherProfileRecord) {
        // Initialize form state from the profile being edited so bindings
        // read from/write to mutable @State vars instead of immutable snapshots
        editFormName = profile.displayName
        editFormTargetKind = profile.targetKind
        editFormBrowserType = profile.browserType ?? .chrome
        editFormCLIType = profile.cliType ?? .claude
        editFormProfileIdentifier = profile.browserMetadata?.profileIdentifier ?? ""
        editFormWorkingDirectory = profile.cliMetadata?.workingDirectory ?? ""
        editFormAdditionalArgs = profile.cliMetadata?.additionalArgs.joined(separator: " ") ?? ""
        editFormEnvKeys = profile.cliMetadata?.envKeysToPass.joined(separator: ", ") ?? ""
        editFormValidationError = nil
        editFormDuplicateError = nil
        profileToEdit = profile
        showingEditSheet = true
    }

    private func confirmDeleteProfile(_ profile: SwitcherProfileRecord) {
        profileToDelete = profile
        showingDeleteConfirmation = true
    }

    private func deleteProfile(_ profile: SwitcherProfileRecord) {
        do {
            try dataStore.switcherStore.deleteProfile(id: profile.id)
            profileToDelete = nil

            // VAL-SETTINGS-010: Deleting active profile chooses safe fallback
            let state = try dataStore.switcherStore.fetchActiveProfileState()
            activeProfileID = state.activeProfileID

            loadProfiles()
        } catch {
            self.error = "Failed to delete profile: \(error.localizedDescription)"
        }
    }

    // MARK: - Form Validation

    /// Validates the form and sets validation/duplicate errors.
    /// Returns true if valid, false otherwise.
    private func validateForm(excludingID: String?) -> Bool {
        editFormValidationError = nil
        editFormDuplicateError = nil

        // Name validation (optional, but if provided must not be duplicate)
        if !editFormName.isEmpty {
            do {
                // More lenient duplicate check - only check display names
                if try dataStore.switcherStore.existsProfileWithNormalizedName(editFormName, excludingID: excludingID) {
                    editFormDuplicateError = "A profile with this name already exists"
                    return false
                }
            } catch {
                // Ignore duplicate check errors
            }
        }

        // Target-specific validation (VAL-SETTINGS-011)
        switch editFormTargetKind {
        case .browser:
            if editFormProfileIdentifier.isEmpty {
                editFormValidationError = "Profile identifier is required"
                return false
            }
        case .cli:
            // CLI profiles don't require profile identifier
            break
        }

        return true
    }

    private func buildProfileRecord(id: String) -> SwitcherProfileRecord {
        SwitcherProfileRecord(
            id: id,
            targetKind: editFormTargetKind,
            browserType: editFormTargetKind == .browser ? editFormBrowserType : nil,
            browserMetadata: editFormTargetKind == .browser ? SwitcherBrowserProfileMetadata(
                profileIdentifier: editFormProfileIdentifier,
                displayLabel: editFormName.isEmpty ? nil : editFormName
            ) : nil,
            cliType: editFormTargetKind == .cli ? editFormCLIType : nil,
            cliMetadata: editFormTargetKind == .cli ? SwitcherCLIProfileMetadata(
                workingDirectory: editFormWorkingDirectory.isEmpty ? nil : editFormWorkingDirectory,
                additionalArgs: editFormAdditionalArgs.isEmpty ? [] : editFormAdditionalArgs.split(separator: " ").map(String.init),
                envKeysToPass: editFormEnvKeys.isEmpty ? [] : editFormEnvKeys.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                displayLabel: editFormName.isEmpty ? nil : editFormName
            ) : nil,
            sortKey: 0
        )
    }
}

// MARK: - Profile Row View

/// Individual profile row with active indicator, account identity, and actions.
struct ProfileRowView: View {
    let profile: SwitcherProfileRecord
    let priorityIndex: Int
    let fallbackIndex: Int?          // position within its provider pool (1-based), nil if solo
    let providerColor: Color
    let quotaLookup: (AgentProvider) -> ProviderQuotaSnapshot?
    let isActive: Bool
    let isChangingAccount: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canSwap: Bool
    let canSetPrimary: Bool
    let canToggleDisabled: Bool
    let onSetActive: () -> Void
    let onSwap: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onToggleDisabled: () -> Void
    let onChangeAccount: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    // Legacy convenience init (for any call site that omits the new params)
    init(
        profile: SwitcherProfileRecord,
        priorityIndex: Int,
        fallbackIndex: Int? = nil,
        providerColor: Color = DesignSystem.Colors.textMuted,
        quotaLookup: @escaping (AgentProvider) -> ProviderQuotaSnapshot? = { _ in nil },
        isActive: Bool,
        isChangingAccount: Bool = false,
        canMoveUp: Bool,
        canMoveDown: Bool,
        canSwap: Bool = false,
        canSetPrimary: Bool = false,
        canToggleDisabled: Bool = false,
        onSetActive: @escaping () -> Void,
        onSwap: @escaping () -> Void = {},
        onMoveUp: @escaping () -> Void,
        onMoveDown: @escaping () -> Void,
        onToggleDisabled: @escaping () -> Void = {},
        onChangeAccount: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.profile = profile
        self.priorityIndex = priorityIndex
        self.fallbackIndex = fallbackIndex
        self.providerColor = providerColor
        self.quotaLookup = quotaLookup
        self.isActive = isActive
        self.isChangingAccount = isChangingAccount
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.canSwap = canSwap
        self.canSetPrimary = canSetPrimary
        self.canToggleDisabled = canToggleDisabled
        self.onSetActive = onSetActive
        self.onSwap = onSwap
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        self.onToggleDisabled = onToggleDisabled
        self.onChangeAccount = onChangeAccount
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    var body: some View {
        GlassCard(interactive: true) {
            HStack(spacing: DesignSystem.Spacing.md) {
                // Provider color accent bar + active dot
                ZStack(alignment: .center) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(providerColor.opacity(isActive ? 1.0 : 0.25))
                        .frame(width: 3, height: 36)

                    if isActive {
                        Circle()
                            .fill(DesignSystem.Colors.success)
                            .frame(width: 7, height: 7)
                            .offset(y: 22)
                    }
                }
                .frame(width: 8)

                // Profile identity
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(profile.displayName)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        if profile.isDisabled {
                            Text("Paused")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DesignSystem.Colors.textMuted.opacity(0.14))
                                .clipShape(Capsule())
                        }

                        if isConnected {
                            Text("Logged in")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DesignSystem.Colors.success)
                                .clipShape(Capsule())
                        }

                        if let idx = fallbackIndex {
                            Text(idx == 1 ? "primary" : "reserve \(idx - 1)")
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(providerColor.opacity(0.7))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(providerColor.opacity(0.10))
                                .clipShape(Capsule())
                        }
                    }

                    // Account identity line — the most important info
                    Text(accountIdentityText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(accountIdentityColor)

                    if let cliQuotaSummaryText {
                        Text(cliQuotaSummaryText)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if !browserServiceStatusLines.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(browserServiceStatusLines, id: \.id) { status in
                                Text(status.displayText)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }

                Spacer()

                // Actions (visible on hover or always for active)
                HStack(spacing: DesignSystem.Spacing.sm) {
                    if canMoveUp {
                        Button { onMoveUp() } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Move \(profile.displayName) up in priority")
                    }

                    if canMoveDown {
                        Button { onMoveDown() } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Move \(profile.displayName) down in priority")
                    }

                    if canSetPrimary {
                        Button("Make Primary") { onSetActive() }
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(providerColor)
                            .buttonStyle(.plain)
                            .accessibilityLabel("Make \(profile.displayName) the primary account for this provider")
                    }

                    if canSwap {
                        Button("Swap") { onSwap() }
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .buttonStyle(.plain)
                            .accessibilityLabel("Swap \(profile.displayName) with another account from this provider")
                    }

                    Button(profile.isDisabled ? "Enable" : "Pause") { onToggleDisabled() }
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(profile.isDisabled ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
                        .buttonStyle(.plain)
                        .disabled(!canToggleDisabled)
                        .accessibilityLabel("\(profile.isDisabled ? "Enable" : "Pause") \(profile.displayName)")

                    Button { onChangeAccount() } label: {
                        if isChangingAccount {
                            ProgressView()
                                .scaleEffect(0.55)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "person.badge.key")
                                .font(.system(size: 12))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isChangingAccount)
                    .accessibilityLabel("\(isConnected ? "Reconnect" : "Connect") account for \(profile.displayName)")

                    if profile.targetKind == .cli {
                        Button { onEdit() } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 12))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit \(profile.displayName)")
                    }

                    Button { onDelete() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignSystem.Colors.error)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete \(profile.displayName)")
                }
                .opacity(isHovered || isConnected || profile.isDisabled ? 1 : 0.55)
            }
            .padding(.vertical, DesignSystem.Spacing.sm)
            .padding(.horizontal, DesignSystem.Spacing.md)
        }
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.snappy) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.displayName), \(accountIdentityText), \(isConnected ? "logged in" : "not logged in")")
        .accessibilityHint(fallbackIndex == 1 ? "Primary account for this provider" : (canSetPrimary ? "Use Make Primary to switch this provider to this account" : "Profile available for this provider"))
    }

    // MARK: - Account identity

    private var accountIdentityText: String {
        // CLI: show accountDescription from metadata if present
        if profile.targetKind == .cli {
            if profile.isDisabled {
                return "Paused — excluded from switching until re-enabled"
            }
            if let accountDescription = profile.cliMetadata?.accountDescription,
               !accountDescription.isEmpty {
                return "Connected: \(accountDescription)"
            }
            if let exhaustedUntil = profile.cliMetadata?.exhaustedUntil,
               exhaustedUntil > Date() {
                return "Held in reserve until quota resets"
            }
            if let label = profile.cliMetadata?.displayLabel, !label.isEmpty {
                return "Not connected · \(label)"
            }
            return "Not connected"
        }

        // Browser: show display label (usually email) or generic text
        if let meta = profile.browserMetadata {
            if profile.isDisabled {
                return "Paused — excluded from browser switching until re-enabled"
            }
            var segments: [String] = []

            if let email = meta.accountEmail, !email.isEmpty {
                segments.append("\(browserIdentityLabel): \(email)")
            } else if let label = meta.displayLabel, !label.isEmpty {
                segments.append("\(browserIdentityLabel): \(label)")
            }

            if !segments.isEmpty {
                return segments.joined(separator: " · ")
            }
            if !meta.serviceIdentities.isEmpty {
                return "Web sessions detected"
            }
            return "Not signed in"
        }

        return profile.browserType?.displayName ?? "Browser"
    }

    private var isConnected: Bool {
        switch profile.targetKind {
        case .cli:
            return !profile.isDisabled && !(profile.cliMetadata?.accountDescription?.isEmpty ?? true)
        case .browser:
            guard !profile.isDisabled else { return false }
            if let email = profile.browserMetadata?.accountEmail, !email.isEmpty {
                return true
            }
            return !(profile.browserMetadata?.serviceIdentities.isEmpty ?? true)
        }
    }

    private var accountIdentityColor: Color {
        if profile.isDisabled {
            return DesignSystem.Colors.textMuted
        }
        if profile.targetKind == .cli,
           profile.cliMetadata?.accountDescription?.isEmpty == false {
            return DesignSystem.Colors.success
        }
        if profile.targetKind == .cli,
           let exhaustedUntil = profile.cliMetadata?.exhaustedUntil,
           exhaustedUntil > Date() {
            return DesignSystem.Colors.warning
        }
        if accountIdentityText != "Not signed in" {
            return DesignSystem.Colors.success
        }
        return DesignSystem.Colors.textMuted
    }

    private var browserIdentityLabel: String {
        switch profile.browserType {
        case .safari:
            return "Apple ID"
        case .chrome, .none:
            return "Google"
        }
    }

    private var browserServiceStatusLines: [BrowserServiceStatusDisplay] {
        guard let serviceIdentities = profile.browserMetadata?.serviceIdentities,
              !serviceIdentities.isEmpty else {
            return []
        }

        return browserServiceStatusDisplays(
            for: serviceIdentities,
            quotaLookup: { provider in
                guard let agentProvider = provider.agentProvider else { return nil }
                return quotaLookup(agentProvider)
            }
        )
    }

    private var cliQuotaSummaryText: String? {
        cliQuotaStatusText(for: profile, quotaLookup: quotaLookup)
    }
}

// MARK: - Profile Form View

/// Reusable form for creating and editing profiles.
/// Includes target-specific validation and OAuth boundary copy.
struct ProfileFormView: View {
    let title: String
    @Binding var name: String
    @Binding var targetKind: SwitcherProfileTargetKind
    @Binding var browserType: SwitcherBrowserProfileType
    @Binding var cliType: SwitcherCLIProfileType
    @Binding var profileIdentifier: String
    @Binding var workingDirectory: String
    @Binding var additionalArgs: String
    @Binding var envKeys: String
    @Binding var validationError: String?
    @Binding var duplicateError: String?
    let isSaving: Bool
    let boundaryCopyVisible: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            // OAuth boundary messaging (VAL-SETTINGS-016)
            if boundaryCopyVisible {
                Section {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(DesignSystem.Colors.amber)
                        Text("BurnBar stores only profile references for launching — no credentials or session data is imported.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    .listRowBackground(DesignSystem.Colors.surfaceElevated)
                }
            }

            // Target kind selection
            Section {
                Picker("Target Kind", selection: $targetKind) {
                    Text("Browser").tag(SwitcherProfileTargetKind.browser)
                    Text("CLI").tag(SwitcherProfileTargetKind.cli)
                }
                .pickerStyle(.segmented)
                .listRowBackground(DesignSystem.Colors.surfaceElevated)
            }

            // Name field
            Section {
                TextField("Display Name (optional)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .listRowBackground(DesignSystem.Colors.surfaceElevated)

                if let dupError = duplicateError {
                    Text(dupError)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.error)
                }
            } header: {
                Text("Profile Name")
            }

            // Target-specific fields
            if targetKind == .browser {
                browserFields
            } else {
                cliFields
            }

            // Validation error
            if let error = validationError {
                Section {
                    Text(error)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.error)
                }
            }

            // Action buttons
            Section {
                HStack {
                    Button("Cancel") {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button {
                        onSave()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                        } else {
                            Text("Save")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                }
                .listRowBackground(DesignSystem.Colors.surfaceElevated)
            }
        }
        .formStyle(.grouped)
    }

    private var browserFields: some View {
        Group {
            Section {
                Picker("Browser", selection: $browserType) {
                    ForEach(SwitcherBrowserProfileType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .listRowBackground(DesignSystem.Colors.surfaceElevated)
            }

            Section {
                TextField("Profile Identifier", text: $profileIdentifier)
                    .textFieldStyle(.roundedBorder)
                    .listRowBackground(DesignSystem.Colors.surfaceElevated)
            } header: {
                Text("Profile Identifier")
            } footer: {
                Text("For Chrome: the profile folder name (e.g., 'Profile 1', 'Default'). For Safari: the WebKit profile container name.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }

    private var cliFields: some View {
        Group {
            Section {
                Picker("CLI", selection: $cliType) {
                    ForEach(SwitcherCLIProfileType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .listRowBackground(DesignSystem.Colors.surfaceElevated)
            }

            Section {
                TextField("Working Directory (optional)", text: $workingDirectory)
                    .textFieldStyle(.roundedBorder)
                    .listRowBackground(DesignSystem.Colors.surfaceElevated)
            } header: {
                Text("Working Directory")
            }

            Section {
                TextField("Additional Args (optional)", text: $additionalArgs)
                    .textFieldStyle(.roundedBorder)
                    .listRowBackground(DesignSystem.Colors.surfaceElevated)
            } header: {
                Text("Additional Arguments")
            } footer: {
                Text("Space-separated list of arguments (e.g., '--verbose --no-color')")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Section {
                TextField("Environment Keys (optional)", text: $envKeys)
                    .textFieldStyle(.roundedBorder)
                    .listRowBackground(DesignSystem.Colors.surfaceElevated)
            } header: {
                Text("Environment Variables to Pass")
            } footer: {
                Text("Comma-separated list of environment variable names (e.g., 'HOME, PATH'). Values are NOT stored.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }
}

// MARK: - Account Destination Picker Sheet

private struct AccountDestinationPickerSheet: View {
    let profileName: String
    let destinations: [AccountChangeDestination]
    let onSelect: (AccountChangeDestination) -> Void
    let onCancel: () -> Void

    @State private var hoveredDestination: AccountChangeDestination?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: DesignSystem.Spacing.xs) {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.amber.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.amber)
                }

                Text("Switch Account")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Choose where to log in for \(profileName)")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.top, DesignSystem.Spacing.xl)
            .padding(.bottom, DesignSystem.Spacing.lg)

            // Destination cards
            VStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(destinations, id: \.self) { destination in
                    destinationCard(destination)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)

            Spacer()

            // Cancel
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.plain)
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .padding(.bottom, DesignSystem.Spacing.lg)
        }
        .frame(width: 340, height: destinationSheetHeight)
        .background(DesignSystem.Colors.background)
    }

    private var destinationSheetHeight: CGFloat {
        let headerHeight: CGFloat = 120
        let cardHeight: CGFloat = 72
        let cardSpacing: CGFloat = 8
        let bottomPadding: CGFloat = 50
        return headerHeight + CGFloat(destinations.count) * cardHeight + CGFloat(max(0, destinations.count - 1)) * cardSpacing + bottomPadding
    }

    @ViewBuilder
    private func destinationCard(_ destination: AccountChangeDestination) -> some View {
        let isHovered = hoveredDestination == destination

        Button {
            onSelect(destination)
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                // Provider logo
                destinationLogo(for: destination)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.label)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(destination.subtitle)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHovered ? destination.accentColor : DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(isHovered ? DesignSystem.Colors.surfaceElevated : DesignSystem.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(
                        isHovered ? destination.accentColor.opacity(0.35) : DesignSystem.Colors.borderSubtle,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hover) {
                hoveredDestination = hovering ? destination : nil
            }
        }
    }

    @ViewBuilder
    private func destinationLogo(for destination: AccountChangeDestination) -> some View {
        switch destination {
        case .openAI:
            ProviderLogoView(provider: .codex, size: 32, useFallbackColor: true)
        case .claude:
            ProviderLogoView(provider: .claudeCode, size: 32, useFallbackColor: true)
        case .googleAccount:
            ZStack {
                Circle()
                    .fill(Color.white)
                Image("GeminiCLILogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
            }
        case .appleID:
            ZStack {
                Circle()
                    .fill(Color(hex: "0071E3").opacity(0.12))
                Image(systemName: "apple.logo")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(hex: "0071E3"))
            }
        }
    }
}

struct BrowserServiceStatusDisplay: Identifiable, Equatable {
    let id: String
    let providerName: String
    let accountLabel: String
    let fiveHour: String
    let sevenDay: String

    var displayText: String {
        "\(providerName): \(accountLabel) · 5h \(fiveHour) · 7d \(sevenDay)"
    }
}

func browserServiceStatusDisplays(
    for serviceIdentities: [BrowserServiceIdentity],
    quotaLookup: (BrowserServiceProvider) -> ProviderQuotaSnapshot?
) -> [BrowserServiceStatusDisplay] {
    serviceIdentities.map { identity in
        let snapshot = quotaLookup(identity.provider)
        return BrowserServiceStatusDisplay(
            id: identity.provider.rawValue,
            providerName: identity.provider.displayName,
            accountLabel: identity.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? identity.accountLabel!.trimmingCharacters(in: .whitespacesAndNewlines)
                : "signed in",
            fiveHour: snapshot?.hourlyBucket?.remainingText ?? "--",
            sevenDay: snapshot?.weeklyBucket?.remainingText ?? "--"
        )
    }
}

func cliQuotaStatusText(
    for profile: SwitcherProfileRecord,
    quotaLookup: (AgentProvider) -> ProviderQuotaSnapshot?
) -> String? {
    guard profile.targetKind == .cli,
          !profile.isDisabled,
          profile.cliMetadata?.accountDescription?.isEmpty == false,
          let cliType = profile.cliType,
          let provider = cliType.agentProvider,
          let snapshot = quotaLookup(provider) else {
        return nil
    }

    let fiveHour = snapshot.hourlyBucket?.remainingText ?? "--"
    let sevenDay = snapshot.weeklyBucket?.remainingText ?? "--"
    return "Quota left · 5h \(fiveHour) · 7d \(sevenDay)"
}

func refreshedBrowserProfileRecord(
    profile: SwitcherProfileRecord,
    discoveredChromeProfile: ChromeProfileInfo
) -> SwitcherProfileRecord {
    SwitcherProfileRecord(
        id: profile.id,
        targetKind: .browser,
        browserType: .chrome,
        browserMetadata: SwitcherBrowserProfileMetadata(
            profileIdentifier: profile.browserMetadata?.profileIdentifier ?? discoveredChromeProfile.folderKey,
            displayLabel: discoveredChromeProfile.displayName,
            accountEmail: discoveredChromeProfile.email ?? profile.browserMetadata?.accountEmail,
            providerIdentifier: profile.browserMetadata?.providerIdentifier ?? "google",
            serviceIdentities: discoveredChromeProfile.serviceIdentities,
            isDisabled: profile.browserMetadata?.isDisabled ?? false
        ),
        sortKey: profile.sortKey,
        createdAt: profile.createdAt,
        updatedAt: profile.updatedAt
    )
}

private extension BrowserServiceProvider {
    var agentProvider: AgentProvider? {
        switch self {
        case .openAI:
            return .codex
        case .claude:
            return .claudeCode
        }
    }
}

private extension SwitcherCLIProfileType {
    var agentProvider: AgentProvider? {
        switch self {
        case .codex:
            return .codex
        case .claude:
            return .claudeCode
        case .opencode:
            return nil
        }
    }
}

private extension AccountChangeDestination {
    var browserServiceProvider: BrowserServiceProvider? {
        switch self {
        case .openAI:
            return .openAI
        case .claude:
            return .claude
        case .googleAccount, .appleID:
            return nil
        }
    }
}

enum AccountChangeDestination: Hashable {
    case openAI
    case claude
    case googleAccount
    case appleID

    var label: String {
        switch self {
        case .openAI:
            return "OpenAI / Codex"
        case .claude:
            return "Claude"
        case .googleAccount:
            return "Google Account"
        case .appleID:
            return "Apple ID"
        }
    }

    var subtitle: String {
        switch self {
        case .openAI:
            return "chatgpt.com"
        case .claude:
            return "claude.ai"
        case .googleAccount:
            return "myaccount.google.com"
        case .appleID:
            return "appleid.apple.com"
        }
    }

    var icon: String {
        switch self {
        case .openAI:
            return "bubble.left.fill"
        case .claude:
            return "bubble.right.fill"
        case .googleAccount:
            return "person.badge.key.fill"
        case .appleID:
            return "apple.logo"
        }
    }

    var accentColor: Color {
        switch self {
        case .openAI:
            return Color(hex: "00A67E")
        case .claude:
            return Color(hex: "CC785C")
        case .googleAccount:
            return Color(hex: "4285F4")
        case .appleID:
            return Color(hex: "0071E3")
        }
    }

    var requiresInteractiveAuth: Bool {
        switch self {
        case .googleAccount, .appleID:
            return true
        case .openAI, .claude:
            return false
        }
    }

    var url: URL {
        switch self {
        case .openAI:
            return URL(string: "https://chatgpt.com/")!
        case .claude:
            return URL(string: "https://claude.ai/")!
        case .googleAccount:
            return URL(string: "https://accounts.google.com/AccountChooser?continue=https://myaccount.google.com/")!
        case .appleID:
            return URL(string: "https://appleid.apple.com/sign-in")!
        }
    }
}

enum BrowserAccountChangePlanner {
    static func destinations(
        providerIdentifier: String?,
        serviceIdentities: [BrowserServiceIdentity]
    ) -> [AccountChangeDestination] {
        var ordered: [AccountChangeDestination] = []

        func append(_ destination: AccountChangeDestination) {
            guard !ordered.contains(destination) else { return }
            ordered.append(destination)
        }

        switch providerIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "apple":
            append(.appleID)
        case "google":
            append(.googleAccount)
        default:
            break
        }

        for identity in serviceIdentities {
            switch identity.provider {
            case .openAI:
                append(.openAI)
            case .claude:
                append(.claude)
            }
        }

        append(.openAI)
        append(.claude)

        if ordered.isEmpty {
            append(.openAI)
            append(.claude)
        }

        return ordered
    }
}

private final class SettingsSwitcherProfileAdapter: SwitcherProfileStoreAdapter, @unchecked Sendable {
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
