import AppKit
import SwiftUI
import OpenBurnBarCore

extension AccountSwitcherSettingsView {
    // MARK: - Data Operations

    func loadProfiles() {
        isLoading = true
        do {
            refreshLiveCLIAuthStates()
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

    func enrichAndReload() {
        do {
            refreshLiveCLIAuthStates()
            let fetchedProfiles = try dataStore.switcherStore.fetchAllProfiles()
            profiles = enrichProfilesForDisplay(fetchedProfiles)
            let state = try dataStore.switcherStore.validateAndRecoverActiveProfile()
            activeProfileID = resolvedActiveProfileID(from: state, profiles: profiles)
            activeProfileState = state
        } catch {
            self.error = "Failed to reload profiles: \(error.localizedDescription)"
        }
    }

    func refreshLiveCLIAuthStates() {
        var next: [SwitcherCLIProfileType: CLIAuthInfo] = [:]
        for cliType in [SwitcherCLIProfileType.claude, .codex, .opencode] {
            next[cliType] = CLIAuthDiscovery.discoverAuthState(for: cliType)
        }
        liveCLIAuthStates = next
    }

    func refreshQuotaSnapshotsIfNeeded() {
        Task { @MainActor in
            await quotaService.refreshIfNeeded(dataStore: dataStore)
        }
    }

    func resolvedActiveProfileID(from state: SwitcherActiveProfileState, profiles: [SwitcherProfileRecord]) -> String? {
        if let activeProfileID = state.activeProfileID,
           profiles.contains(where: { $0.id == activeProfileID && !$0.isDisabled }) {
            return activeProfileID
        }
        return profiles.first(where: { !$0.isDisabled })?.id
    }

    func refreshedBrowserProfile(
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

    func enrichProfilesForDisplay(_ fetchedProfiles: [SwitcherProfileRecord]) -> [SwitcherProfileRecord] {
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
                        providerID: metadata.providerID,
                        runtimeAccountID: metadata.runtimeAccountID,
                        subscriptionTierID: metadata.subscriptionTierID,
                        modelCapabilityClassID: metadata.modelCapabilityClassID,
                        linkedHarnessIDs: metadata.linkedHarnessIDs,
                        neverAutoSwitch: metadata.neverAutoSwitch,
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

    func addAccount(for group: ProfileGroup) async {
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

    func addCLIAccount(for group: ProfileGroup) async {
        guard let cliType = group.cliType else { return }

        let placeholder = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(displayLabel: cliType.displayName),
            sortKey: 0
        )

        let coordinator = SwitcherCLIAuthCoordinator()
        switch await coordinator.reconnect(
            profile: placeholder,
            context: SwitcherCLIAuthCoordinator.ReconnectContext(
                providerSlotLabel: "\(group.label) reserve #\(group.profiles.count)",
                existingAccountLabels: group.profiles.map { $0.profile.cliMetadata?.accountDescription ?? $0.profile.displayName }
            )
        ) {
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

    func addConfirmedCLIAccount(_ request: PendingCLIAddRequest) async {
        connectingProviderKey = request.providerKey
        cliAddResultMessage = "Terminal opened — finish \(request.providerLabel) login for \(request.nextSlotLabel). BurnBar will verify the detected account when Terminal exits."
        defer {
            connectingProviderKey = nil
            expandedProviderKeys.insert(request.providerKey)
        }

        let placeholder = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: request.cliType,
            cliMetadata: SwitcherCLIProfileMetadata(displayLabel: request.nextSlotLabel),
            sortKey: 0
        )

        let coordinator = SwitcherCLIAuthCoordinator()
        let result = await coordinator.reconnect(
            profile: placeholder,
            context: SwitcherCLIAuthCoordinator.ReconnectContext(
                providerSlotLabel: request.nextSlotLabel,
                existingAccountLabels: request.existingProfiles.map { $0.cliMetadata?.accountDescription ?? $0.displayName }
            )
        )

        switch result {
        case .readyToPersist(let updatedProfile), .requiresConfirmation(let updatedProfile, _, _):
            let detected = normalizedAccountLabel(updatedProfile.cliMetadata?.accountDescription)
            if let detected,
               let duplicate = duplicateCLIProfile(cliType: request.cliType, accountDescription: detected) {
                cliAddResultMessage = "Already added: \(duplicate.displayName) is connected to \(detected). Sign into a different \(request.providerLabel) account to create \(request.nextSlotLabel)."
                return
            }
            if persistNewCLIAccount(updatedProfile, for: request.cliType) {
                if let detected {
                    cliAddResultMessage = "Added \(request.nextSlotLabel): \(detected). Quota will refresh automatically."
                } else {
                    cliAddResultMessage = "Added \(request.nextSlotLabel). \(request.providerLabel) is connected, but it did not return an account label yet."
                }
                pendingCLIAddRequest = nil
            } else if cliAddResultMessage == nil {
                cliAddResultMessage = "Failed to save \(request.nextSlotLabel)."
            }
        case .cancelled:
            cliAddResultMessage = "\(request.providerLabel) login was cancelled. No profile was added."
        case .failed(let message):
            cliAddResultMessage = message
            error = message
        }

        enrichAndReload()
        refreshQuotaSnapshotsIfNeeded()
    }

    @discardableResult
    func persistNewCLIAccount(_ updatedProfile: SwitcherProfileRecord, for cliType: SwitcherCLIProfileType) -> Bool {
        guard let metadata = updatedProfile.cliMetadata else { return false }

        let preferredLabel: String?
        if let accountDescription = metadata.accountDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountDescription.isEmpty {
            preferredLabel = accountDescription
        } else {
            preferredLabel = metadata.displayLabel
        }

        if let accountDescription = normalizedAccountLabel(metadata.accountDescription),
           duplicateCLIProfile(cliType: cliType, accountDescription: accountDescription) != nil {
            self.error = "Already added: \(accountDescription) is already connected as a \(cliType.displayName) profile."
            return false
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
                    providerID: metadata.providerID,
                    runtimeAccountID: metadata.runtimeAccountID,
                    subscriptionTierID: metadata.subscriptionTierID,
                    modelCapabilityClassID: metadata.modelCapabilityClassID,
                    linkedHarnessIDs: metadata.linkedHarnessIDs,
                    neverAutoSwitch: metadata.neverAutoSwitch,
                    lastQuotaExhaustedAt: metadata.lastQuotaExhaustedAt,
                    exhaustedUntil: metadata.exhaustedUntil,
                    lastQuotaExhaustionDetail: metadata.lastQuotaExhaustionDetail,
                    isDisabled: metadata.isDisabled
                ),
                sortKey: 0
            )
            _ = try dataStore.switcherStore.create(newProfile)
            return true
        } catch {
            self.error = "Failed to add \(cliType.displayName) account: \(error.localizedDescription)"
            return false
        }
    }

    func duplicateCLIProfile(cliType: SwitcherCLIProfileType, accountDescription: String) -> SwitcherProfileRecord? {
        let normalizedTarget = normalizedAccountLabel(accountDescription)
        return profiles.first { profile in
            guard profile.targetKind == .cli,
                  profile.cliType == cliType,
                  let existing = normalizedAccountLabel(profile.cliMetadata?.accountDescription) else {
                return false
            }
            return existing.caseInsensitiveCompare(normalizedTarget ?? "") == .orderedSame
        }
    }

    func toggleDisabled(_ profile: SwitcherProfileRecord, in group: ProfileGroup) {
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

    func profileWithDisabledState(_ profile: SwitcherProfileRecord, isDisabled: Bool) -> SwitcherProfileRecord {
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
                    providerID: profile.cliMetadata?.providerID,
                    runtimeAccountID: profile.cliMetadata?.runtimeAccountID,
                    subscriptionTierID: profile.cliMetadata?.subscriptionTierID,
                    modelCapabilityClassID: profile.cliMetadata?.modelCapabilityClassID,
                    linkedHarnessIDs: profile.cliMetadata?.linkedHarnessIDs ?? [],
                    neverAutoSwitch: profile.cliMetadata?.neverAutoSwitch ?? false,
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

    func requestAccountChange(for profile: SwitcherProfileRecord) {
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

    func reconnectCLIProfile(_ profile: SwitcherProfileRecord) async {
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

    func persistCLIProfileUpdate(_ updatedProfile: SwitcherProfileRecord) {
        do {
            _ = try dataStore.switcherStore.update(updatedProfile)
            loadProfiles()
        } catch {
            self.error = "Failed to update CLI profile: \(error.localizedDescription)"
        }
    }

    func persistNewCLIProfile(_ pendingUpdate: PendingCLIAccountUpdate) {
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
                    providerID: metadata.providerID,
                    runtimeAccountID: metadata.runtimeAccountID,
                    subscriptionTierID: metadata.subscriptionTierID,
                    modelCapabilityClassID: metadata.modelCapabilityClassID,
                    linkedHarnessIDs: metadata.linkedHarnessIDs,
                    neverAutoSwitch: metadata.neverAutoSwitch,
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

    func pendingCLIAccountUpdateMessage(_ pendingUpdate: PendingCLIAccountUpdate) -> String {
        let previousAccount = pendingUpdate.previousAccount ?? "an unknown account"
        let detectedAccount = pendingUpdate.detectedAccount ?? "a different account"

        if pendingUpdate.canSaveAsNew {
            let cliName = pendingUpdate.updatedProfile.cliType?.displayName ?? "CLI"
            return "This profile was connected to \(previousAccount), but Terminal login detected \(detectedAccount). BurnBar can replace this profile or save the newly connected account as another \(cliName) profile."
        }

        return "This profile was connected to \(previousAccount), but Terminal login detected \(detectedAccount). Replace this profile to use the newly connected account?"
    }

    func normalizedAccountLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var deleteProfileMessage: String {
        let displayName = profileToDelete?.displayName ?? ""
        return "This will permanently delete the profile '\(displayName)'. This action cannot be undone."
    }

    func normalizedConfigDirectory(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func openAccountChangeDestination(_ destination: AccountChangeDestination, for profile: SwitcherProfileRecord) {
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

    func openExternalAccountDestination(_ destination: AccountChangeDestination) {
        guard NSWorkspace.shared.open(destination.url) else {
            error = "Failed to open \(destination.label)."
            return
        }
    }

    func availableAccountChangeDestinations(for profile: SwitcherProfileRecord) -> [AccountChangeDestination] {
        guard profile.targetKind == .browser else {
            return serviceDestinations(for: profile)
        }

        return BrowserAccountChangePlanner.destinations(
            providerIdentifier: browserProviderIdentifier(for: profile),
            serviceIdentities: profile.browserMetadata?.serviceIdentities ?? []
        )
    }

    func defaultAccountChangeDestination(for profile: SwitcherProfileRecord) -> AccountChangeDestination? {
        switch profile.cliType {
        case .codex:
            return .openAI
        case .claude:
            return .claude
        case .opencode, .none:
            return nil
        }
    }

    func preferredAccountChangeDestination(for profile: SwitcherProfileRecord) -> AccountChangeDestination? {
        let serviceDestinations = serviceDestinations(for: profile)
        return serviceDestinations.count == 1 ? serviceDestinations[0] : nil
    }

    func serviceDestinations(for profile: SwitcherProfileRecord) -> [AccountChangeDestination] {
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

    func browserProviderIdentifier(for profile: SwitcherProfileRecord) -> String {
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

    func setActiveProfile(_ profile: SwitcherProfileRecord) {
        do {
            try dataStore.switcherStore.setActiveProfile(profile.id)
            activeProfileID = profile.id
            activeProfileState = try dataStore.switcherStore.fetchActiveProfileState()
        } catch {
            self.error = "Failed to set active profile: \(error.localizedDescription)"
        }
    }

    func makePrimary(_ profile: SwitcherProfileRecord, in group: ProfileGroup) {
        guard let firstProfile = group.profiles.first?.profile,
              firstProfile.id != profile.id else {
            return
        }
        reorderWithinGroup(movingProfileID: profile.id, in: group, targetIndex: 0)
    }

    func swapProfileWithinGroup(_ profile: SwitcherProfileRecord, in group: ProfileGroup) {
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

    func moveProfile(_ profile: SwitcherProfileRecord, direction: SwitcherProfileStore.MoveDirection) {
        do {
            try dataStore.switcherStore.moveProfile(id: profile.id, direction: direction)
            loadProfiles()
        } catch {
            self.error = "Failed to reorder profile: \(error.localizedDescription)"
        }
    }

    func moveProfileWithinGroup(
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

    func reorderWithinGroup(
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

    func persistGroupOrder(
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

    func resetForm() {
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

    func createProfile() {
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

    func saveProfile(_ original: SwitcherProfileRecord) {
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
                    providerID: original.cliMetadata?.providerID,
                    runtimeAccountID: original.cliMetadata?.runtimeAccountID,
                    subscriptionTierID: original.cliMetadata?.subscriptionTierID,
                    modelCapabilityClassID: original.cliMetadata?.modelCapabilityClassID,
                    linkedHarnessIDs: original.cliMetadata?.linkedHarnessIDs ?? [],
                    neverAutoSwitch: original.cliMetadata?.neverAutoSwitch ?? false,
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

    func editProfile(_ profile: SwitcherProfileRecord) {
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

    func confirmDeleteProfile(_ profile: SwitcherProfileRecord) {
        profileToDelete = profile
        showingDeleteConfirmation = true
    }

    func deleteProfile(_ profile: SwitcherProfileRecord) {
        do {
            try SwitcherAuthStore().deleteCredentials(forProfileID: profile.id)
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
    func validateForm(excludingID: String?) -> Bool {
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

    func buildProfileRecord(id: String) -> SwitcherProfileRecord {
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
