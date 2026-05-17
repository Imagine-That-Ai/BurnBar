import AppKit
import SwiftUI
import OpenBurnBarCore

extension AccountSwitcherSettingsView {
    var body: some View {
        withReconnectConfirmation(
            appliedTo: withPendingCLIAccountAlert(
                appliedTo: withDeleteProfileAlert(
                    appliedTo: bodyCore
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
                        .sheet(item: $pendingCLIAddRequest) { request in
                            CLIReserveAddSheet(
                                request: request,
                                quotaSnapshotLookup: { profile in
                                    exactCLIProfileQuotaSnapshot(for: profile)
                                },
                                resultMessage: cliAddResultMessage,
                                isLaunching: connectingProviderKey == request.providerKey,
                                onLaunch: {
                                    Task { @MainActor in
                                        await addConfirmedCLIAccount(request)
                                    }
                                },
                                onCancel: {
                                    pendingCLIAddRequest = nil
                                    cliAddResultMessage = nil
                                }
                            )
                        }
                )
            )
        )
    }

    /// Body shape changes based on `mode`. `.all` renders the legacy
    /// standalone tab. `.cliOnly` / `.browserOnly` produce embeddable
    /// content (no outer ScrollView, no boundary card) that the new Agents
    /// tab folds into its CLIs and Advanced detail pages.
    @ViewBuilder
    private var bodyCore: some View {
        switch mode {
        case .all:
            SettingsDeepLinkScrollContainer(route: .switcherRoot) { _ in
                ScrollView {
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
            }
            .background(settingsBackground)
            .scrollContentBackground(.hidden)
        case .cliOnly, .browserOnly:
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                if let error {
                    errorBanner(error)
                }
                if isLoading {
                    loadingView
                } else if filteredProfileGroups.isEmpty {
                    embeddedEmptyState
                } else {
                    ForEach(filteredProfileGroups, id: \.key) { group in
                        providerSection(group)
                    }
                }
            }
        }
    }

    /// Subset of profile groups visible for the current `mode`. The full set
    /// (`profileGroups`) lives in this same extension; embedded modes simply
    /// filter to the right half.
    var filteredProfileGroups: [ProfileGroup] {
        switch mode {
        case .all: return profileGroups
        case .cliOnly: return profileGroups.filter { $0.cliType != nil }
        case .browserOnly: return profileGroups.filter { $0.browserType != nil }
        }
    }

    @ViewBuilder
    var embeddedEmptyState: some View {
        let copy: String = {
            switch mode {
            case .cliOnly:
                return "No CLI profiles yet. Use the Connect button above on any CLI row to authenticate it, or add another profile inline once a CLI is connected."
            case .browserOnly:
                return "No browser profiles yet. Use the Switcher dashboard's add flow to register a Chrome or Safari profile and BurnBar will surface it here."
            case .all:
                return ""
            }
        }()
        Text(copy)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.25))
            )
    }

    // MARK: - Background

    func withDeleteProfileAlert<Content: View>(appliedTo content: Content) -> some View {
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

    func withPendingCLIAccountAlert<Content: View>(appliedTo content: Content) -> some View {
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

    func withReconnectConfirmation<Content: View>(appliedTo content: Content) -> some View {
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

    @ViewBuilder
    var settingsBackground: some View {
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
    var boundaryMessagingCard: some View {
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

    func errorBanner(_ message: String) -> some View {
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

    var loadingView: some View {
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
    var emptyStateView: some View {
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
                    settingsManager: settingsManager,
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
                        Text("Browser Profiles")
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .settingsAnchor(SettingsAnchor.switcherBrowser)

                        supportedTargetRow(logoName: "ChromeLogo", sfFallback: "globe", title: "Google Chrome", subtitle: "Browser profile")
                        Divider().background(DesignSystem.Colors.borderSubtle)
                        supportedTargetRow(logoName: "SafariLogo", sfFallback: "safari", title: "Safari", subtitle: "Browser profile")
                        Divider().background(DesignSystem.Colors.borderSubtle)

                        Text("CLI Profiles")
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .padding(.top, DesignSystem.Spacing.xs)
                            .settingsAnchor(SettingsAnchor.switcherCLI)

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

    func supportedTargetRow(logoName: String?, sfFallback: String, title: String, subtitle: String) -> some View {
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
    struct ProfileGroup {
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

    var profileGroups: [ProfileGroup] {
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
    var profileListView: some View {
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
            profileCategoryHeader("CLI Profiles", anchor: SettingsAnchor.switcherCLI)
            ForEach(cliProfileGroups, id: \.key) { group in
                providerSection(group)
            }

            profileCategoryHeader("Browser Profiles", anchor: SettingsAnchor.switcherBrowser)
            ForEach(browserProfileGroups, id: \.key) { group in
                providerSection(group)
            }

            Text("Codex, Claude, and OpenCode stay available at the same time. Primary and reserve order only apply within the same provider, so switching Codex accounts never deactivates Claude.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    var cliProfileGroups: [ProfileGroup] {
        profileGroups.filter { $0.cliType != nil }
    }

    var browserProfileGroups: [ProfileGroup] {
        profileGroups.filter { $0.browserType != nil }
    }

    func profileCategoryHeader(_ title: String, anchor: String) -> some View {
        Text(title)
            .font(DesignSystem.Typography.caption)
            .fontWeight(.semibold)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .textCase(.uppercase)
            .settingsAnchor(anchor)
    }

    @ViewBuilder
    func providerSection(_ group: ProfileGroup) -> some View {
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
                            if let cliType = group.cliType, cliType == .codex || cliType == .claude {
                                beginCLIAdd(for: group)
                            } else {
                                Task { @MainActor in
                                    await addAccount(for: group)
                                }
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
                                cliQuotaSnapshot: exactCLIProfileQuotaSnapshot(for: item.profile),
                                liveCLIAuthInfo: liveCLIAuthInfo(for: item.profile),
                                allowProviderQuotaFallback: false,
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

    func providerSummary(for group: ProfileGroup) -> String {
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

    func exactCLIProfileQuotaSnapshot(for profile: SwitcherProfileRecord) -> ProviderQuotaSnapshot? {
        guard profile.targetKind == .cli,
              let cliType = profile.cliType,
              let provider = cliType.agentProvider else {
            return nil
        }

        let normalizedProfileID = normalizedQuotaIdentifier(profile.id)
        let normalizedSourceIDs = Set([
            "switcher-cli:\(cliType.rawValue):\(profile.id)",
            "switcher:\(profile.id)",
        ].compactMap(normalizedQuotaIdentifier))
        return quotaService.snapshots(for: provider.providerID).first { snapshot in
            normalizedQuotaIdentifier(snapshot.accountID) == normalizedProfileID
                || normalizedQuotaIdentifier(snapshot.sourceId).map { normalizedSourceIDs.contains($0) } == true
        }
    }

    private func normalizedQuotaIdentifier(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return normalized.lowercased()
    }

    func beginCLIAdd(for group: ProfileGroup) {
        guard let cliType = group.cliType else { return }
        cliAddResultMessage = nil
        pendingCLIAddRequest = PendingCLIAddRequest(
            id: "\(group.key)-\(UUID().uuidString)",
            providerKey: group.key,
            providerLabel: group.label,
            cliType: cliType,
            providerColor: group.color,
            existingProfiles: group.profiles.map(\.profile)
        )
    }

    func toggleProviderExpansion(_ key: String) {
        if expandedProviderKeys.contains(key) {
            expandedProviderKeys.remove(key)
        } else {
            expandedProviderKeys.insert(key)
        }
    }

    func isConnectedProfile(_ profile: SwitcherProfileRecord) -> Bool {
        switch profile.targetKind {
        case .cli:
            guard !profile.isDisabled else { return false }
            if normalizedString(profile.cliMetadata?.accountDescription) != nil { return true }
            guard let authInfo = liveCLIAuthInfo(for: profile) else { return false }
            return isConnected(authInfo)
        case .browser:
            if let email = profile.browserMetadata?.accountEmail,
               !email.isEmpty {
                return true
            }
            return !(profile.browserMetadata?.serviceIdentities.isEmpty ?? true)
        }
    }

    func liveCLIAuthInfo(for profile: SwitcherProfileRecord) -> CLIAuthInfo? {
        guard profile.targetKind == .cli,
              let cliType = profile.cliType else {
            return nil
        }

        if let configDirectory = normalizedString(profile.cliMetadata?.configDirectory) {
            let scoped = CLIAuthDiscovery.discoverAuthState(
                for: cliType,
                configDirectoryOverride: configDirectory
            )
            if isConnected(scoped) || normalizedString(scoped.accountDescription) != nil {
                return scoped
            }
        }

        guard let current = liveCLIAuthStates[cliType] else { return nil }
        if let profileDirectory = normalizedString(profile.cliMetadata?.configDirectory),
           let currentDirectory = normalizedString(current.configDirectory),
           profileDirectory != currentDirectory {
            return nil
        }
        return current
    }

    func isConnected(_ authInfo: CLIAuthInfo) -> Bool {
        switch authInfo.authState {
        case .authenticated, .apiKeyPresent:
            return true
        case .notAuthenticated, .notInstalled:
            return false
        }
    }

    func normalizedString(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    // MARK: - Create Profile Sheet

    var createProfileSheet: some View {
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

    func editProfileSheet(profile: SwitcherProfileRecord) -> some View {
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
}

private struct CLIReserveAddSheet: View {
    let request: AccountSwitcherSettingsView.PendingCLIAddRequest
    let quotaSnapshotLookup: (SwitcherProfileRecord) -> ProviderQuotaSnapshot?
    let resultMessage: String?
    let isLaunching: Bool
    let onLaunch: () -> Void
    let onCancel: () -> Void

    private var provider: AgentProvider? { request.cliType.agentProvider }
    private var existingAccounts: [String] {
        request.existingProfiles.map { profile in
            profile.cliMetadata?.accountDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? profile.cliMetadata!.accountDescription!
                : profile.displayName
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header
            existingAccountsPanel
            instructionCallout

            if let resultMessage {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: resultMessage.localizedCaseInsensitiveContains("failed") || resultMessage.localizedCaseInsensitiveContains("couldn’t") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(resultMessage.localizedCaseInsensitiveContains("failed") || resultMessage.localizedCaseInsensitiveContains("couldn’t") ? DesignSystem.Colors.warning : DesignSystem.Colors.success)
                    Text(resultMessage)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DesignSystem.Spacing.md)
                .background(DesignSystem.Colors.surface.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            }

            Spacer()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)

                Spacer()

                Button {
                    onLaunch()
                } label: {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        if isLaunching {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "terminal")
                        }
                        Text("Launch \(request.providerLabel) login for \(request.nextSlotLabel)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(request.providerColor)
                .font(DesignSystem.Typography.caption)
                .disabled(isLaunching)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(width: 520, height: 520)
        .background(DesignSystem.Colors.background)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ProviderLogoView(provider: provider ?? .codex, size: 42, useFallbackColor: true)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Add \(request.nextSlotLabel)")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("BurnBar will create an isolated auth directory for this slot and verify the account Terminal logs in to.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var instructionCallout: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(request.providerColor)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Use a different account")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("If Terminal opens already logged in as one of the accounts below, sign out or switch accounts before completing login. Otherwise BurnBar will report that the account is already added.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(request.providerColor.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(request.providerColor.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    private var existingAccountsPanel: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("Existing \(request.providerLabel) accounts")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                Text("\(request.existingProfiles.count) connected")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.success)
            }

            if request.existingProfiles.isEmpty {
                Text("No accounts yet. This will become the primary \(request.providerLabel) profile.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(DesignSystem.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignSystem.Colors.surface.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            } else {
                VStack(spacing: DesignSystem.Spacing.xs) {
                    ForEach(Array(request.existingProfiles.enumerated()), id: \.element.id) { index, profile in
                        existingAccountRow(profile: profile, index: index)
                    }
                }
            }
        }
    }

    private func existingAccountRow(profile: SwitcherProfileRecord, index: Int) -> some View {
        let account = profile.cliMetadata?.accountDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? profile.cliMetadata!.accountDescription!
            : "Account label unavailable"
        let windows = cliQuotaWindowDisplays(for: profile, snapshot: quotaSnapshotLookup(profile)) ?? []

        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text(index == 0 ? "PRIMARY" : "RESERVE \(index)")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(request.providerColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(request.providerColor.opacity(0.12))
                    .clipShape(Capsule())

                Text(account)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }

            if windows.isEmpty {
                Text("Quota signal unavailable until the provider reports usage for this account.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            } else {
                ForEach(windows) { window in
                    Text("\(window.label) left \(window.remaining) · \(window.resetText)")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.surface.opacity(0.78))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }
}
