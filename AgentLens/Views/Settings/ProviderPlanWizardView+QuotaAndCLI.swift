import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Plan Strategy

// Quota probe and external CLI login.
// Extracted from ProviderPlanWizardView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension ProviderPlanWizardView {

    func externalCLIType(forProviderID providerID: String) -> SwitcherCLIProfileType? {
        switch ProviderID.normalize(providerID) {
        case "openai", "codex":
            return .codex
        case "anthropic", "claude", "claude-code":
            return .claude
        case "opencode", "open-code":
            return .opencode
        default:
            return nil
        }
    }

    func primeStepIfNeeded(_ step: ProviderPlanWizardStep) {
        if step == .credential, planLabel.isEmpty {
            let provider = selectedProvider ?? activeProvider
            if let provider {
                let count = provider.credentialSlots.count
                planLabel = count == 0 ? "Default" : "Plan \(count + 1)"
            }
        }
    }

    func navigateBack() {
        let previous: ProviderPlanWizardStep
        switch currentStep {
        case .auth: previous = .provider
        case .credential:
            previous = (selectedDescriptor?.methods.count ?? 0) > 1 ? .auth : .provider
        case .strategy: previous = .credential
        case .confirm: previous = .strategy
        case .provider, .dashboard: return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            currentStep = previous
        }
    }

    func navigateToStep(_ step: ProviderPlanWizardStep) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            currentStep = step
        }
    }

    func startCredentialRepairFlow(
        provider: OpenBurnBarDaemonProviderConfiguration,
        slot: OpenBurnBarDaemonProviderConfiguration.CredentialSlot
    ) {
        let descriptor = self.descriptor(for: provider.providerID)
        selectedProviderID = provider.providerID
        selectedAuthMethodID = descriptor.primaryMethod.id
        planLabel = slot.label
        apiKeyInput = ""
        credentialStorageOverride = nil
        credentialStorageOverrideVisibleToken = nil
        editingCredentialSlot = EditingCredentialSlot(
            providerID: provider.providerID,
            slotID: slot.slotID
        )
        showAPIKey = false
        quotaProbeResult = nil
        quotaProbeError = nil
        quotaProbePercent = nil
        externalAuthInfo = nil
        externalAuthMessage = nil
        externalAccountActionMessage = nil
        isOpeningExternalLogin = false
        isAddingExternalAccount = false
        selectedStrategy = slot.isEnabled ? .preferred : .backup
        saveError = nil
        navigateToStep(.credential)
    }

    func scheduleQuotaProbe() {
        quotaProbeTask?.cancel()
        quotaProbeResult = nil
        quotaProbeError = nil
        quotaProbePercent = nil

        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty,
              let providerID = selectedProviderID,
              let method = selectedAuthMethod,
              method.unlocksQuotaRefresh,
              let quotaProvider = quotaProbeProvider(for: providerID) else {
            return
        }

        if quotaProvider == .openCode {
            quotaProbeResult = "Format accepted - local quota refresh runs from OpenCode CLI stats after save."
            return
        }

        quotaProbeTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run { isProbingQuota = true }

            do {
                let snapshot = try await ProviderQuotaService.shared.fetchSnapshot(
                    for: quotaProvider,
                    apiKeyOverride: trimmedKey
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isProbingQuota = false
                    if let bucket = snapshot.primaryDisplayableBucket {
                        let pct = bucket.remainingPercent
                        quotaProbePercent = pct
                        if let pct {
                            let label = bucket.label.isEmpty ? "" : " (\(bucket.label))"
                            quotaProbeResult = "\(Int(pct.rounded()))% remaining\(label)"
                        } else {
                            quotaProbeResult = bucket.remainingText
                        }
                    } else if snapshot.confidence == .unavailable {
                        quotaProbeError = snapshot.statusMessage
                    } else {
                        quotaProbeResult = "Connected — quota will populate after first use."
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isProbingQuota = false
                    quotaProbeError = "Probe failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Writes the freshly signed-in Claude account's token into its
    /// profile-scoped Keychain item so the subsequent route-token import (and
    /// background quota refresh) read a per-account copy instead of Claude
    /// Code's shared global item. Best-effort: the switcher profile is already
    /// saved, so any failure only defers route tracking. Returns an actionable
    /// message when macOS blocks the Keychain read, otherwise `nil`.
    @discardableResult
    func snapshotClaudeProfileCredential(for profile: SwitcherProfileRecord) -> String? {
        do {
            try SwitcherCLIAuthCoordinator.persistProfileCredentialAfterConfirmedLogin(for: profile)
            return nil
        } catch let snapshotError as ClaudeCodeOAuthCredentialImportError {
            switch snapshotError {
            case .accessDenied:
                return snapshotError.localizedDescription
            case .missing, .malformed, .expired:
                return nil
            }
        } catch {
            AppLogger.shared.error(
                "claude_route_credential_snapshot_failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            return nil
        }
    }

    func importClaudeCodeOAuthBearer(
        configDirectory: String? = nil,
        accountLabel: String? = nil,
        allowDefaultKeychainFallback: Bool = true
    ) {
        guard selectedAuthMethod?.isClaudeOAuthBearer == true else { return }

        isImportingCredential = true
        credentialImportMessage = nil
        credentialStorageOverride = nil
        credentialStorageOverrideVisibleToken = nil
        quotaProbeError = nil
        quotaProbeResult = nil

        Task {
            do {
                let credentials = try ClaudeCodeOAuthCredentialImporter(
                    configDirectory: configDirectory,
                    allowDefaultKeychainFallback: allowDefaultKeychainFallback
                ).load(allowUserInteraction: true)
                await MainActor.run {
                    apiKeyInput = credentials.accessToken
                    credentialStorageOverride = credentials.routeCredentialStoragePayload()
                    credentialStorageOverrideVisibleToken = credentials.accessToken
                    if let accountLabel, !accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let message = configDirectory == nil
                            ? "Imported \(accountLabel)'s Claude OAuth token. The token is hidden below; continue and Save & Connect so Claude is advertised as route-ready."
                            : "Imported \(accountLabel)'s Claude OAuth token from Claude Code's macOS keychain. The token is hidden below; continue and Save & Connect so Claude is advertised as route-ready."
                        credentialImportMessage = message
                        externalAccountActionMessage = message
                    } else {
                        credentialImportMessage = "Imported the signed-in Claude Code OAuth token. The token is hidden below; continue and Save & Connect so Claude is advertised as route-ready."
                    }
                    isImportingCredential = false
                    scheduleQuotaProbe()
                }
            } catch {
                await MainActor.run {
                    isImportingCredential = false
                    if configDirectory != nil {
                        let message = "\(error.localizedDescription) The separate Claude login was added for account switching, but Claude did not expose a route token BurnBar could import. Use current Claude login, sign in again, or paste a bearer token to route through BurnBar."
                        credentialImportMessage = message
                        externalAccountActionMessage = message
                    } else if let method = selectedAuthMethod {
                        credentialImportMessage = "\(error.localizedDescription) Opening Claude Code login; finish sign-in, then press Use current Claude login again."
                        openExternalLogin(for: method)
                    }
                }
            }
        }
    }

    func importOpenCodeAuthJSON() {
        guard selectedAuthMethod?.isOpenCodeAuthJSON == true else { return }

        isImportingCredential = true
        credentialImportMessage = nil
        credentialStorageOverride = nil
        credentialStorageOverrideVisibleToken = nil
        quotaProbeError = nil
        quotaProbeResult = nil

        Task {
            do {
                let authURL = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent(".local/share/opencode/auth.json", isDirectory: false)
                let data = try Data(contentsOf: authURL)
                guard let json = String(data: data, encoding: .utf8),
                      json.localizedCaseInsensitiveContains("opencode-go"),
                      json.localizedCaseInsensitiveContains("\"key\"") else {
                    throw ProviderPlanWizardError.message("OpenCode auth.json did not contain an opencode-go route key.")
                }
                await MainActor.run {
                    apiKeyInput = json
                    credentialStorageOverride = nil
                    credentialStorageOverrideVisibleToken = nil
                    credentialImportMessage = "Imported the signed-in OpenCode auth.json. The token is hidden below; continue and Save & Connect so OpenCode models are route-ready."
                    isImportingCredential = false
                    scheduleQuotaProbe()
                }
            } catch {
                await MainActor.run {
                    isImportingCredential = false
                    credentialImportMessage = "Could not read ~/.local/share/opencode/auth.json. Sign in to OpenCode, or paste another account's opencode-go auth JSON."
                }
            }
        }
    }

    func refreshExternalAuthStateIfNeeded() {
        guard let method = selectedAuthMethod, method.usesExternalLogin else {
            externalAuthInfo = nil
            externalAuthMessage = nil
            return
        }

        guard let cliType = externalCLIType(for: method) else {
            externalAuthInfo = nil
            externalAuthMessage = "OpenBurnBar does not know which local CLI handles this sign-in method."
            return
        }

        let authInfo = CLIAuthDiscovery.discoverAuthState(for: cliType)
        externalAuthInfo = authInfo
        externalAuthMessage = externalAuthStatusSummary(for: authInfo)
    }

    func externalCLIType(for method: BurnBarProviderAuthMethod) -> SwitcherCLIProfileType? {
        let providerID = (selectedProviderID ?? activeProviderID ?? "").lowercased()
        let methodID = method.id.lowercased()

        if let cliType = externalCLIType(forProviderID: providerID) {
            return cliType
        }
        if methodID.contains("codex") {
            return .codex
        }
        if methodID.contains("claude") {
            return .claude
        }
        if methodID.contains("opencode") {
            return .opencode
        }
        return nil
    }

    func openExternalLogin(for method: BurnBarProviderAuthMethod) {
        guard let cliType = externalCLIType(for: method) else {
            externalAuthMessage = "OpenBurnBar does not know which local CLI handles this sign-in method."
            return
        }
        guard let executablePath = CLILaunchAdapter.executablePath(for: cliType) else {
            externalAuthMessage = "\(cliType.displayName) is not installed."
            return
        }

        let command = loginCommands(for: cliType, executablePath: executablePath).first
        guard let command else {
            externalAuthMessage = "No login command is available for \(cliType.displayName)."
            return
        }

        isOpeningExternalLogin = true
        do {
            let scriptURL = try makeLoginScript(command: command, title: cliType.displayName)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [scriptURL],
                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                configuration: configuration
            ) { _, error in
                Task { @MainActor in
                    isOpeningExternalLogin = false
                    if let error {
                        externalAuthMessage = "Could not open Terminal: \(error.localizedDescription)"
                    } else {
                        externalAuthMessage = "Opened \(cliType.displayName) login. Finish sign-in, then refresh this check."
                        refreshDashboardExternalAuthStates()
                    }
                }
            }
        } catch {
            isOpeningExternalLogin = false
            externalAuthMessage = "Could not prepare login command: \(error.localizedDescription)"
        }
    }

    func addExternalAccountLabel(for cliType: SwitcherCLIProfileType?) -> String {
        guard let cliType else { return "Add OAuth Account" }
        let existingCount = switcherProfiles.filter { $0.targetKind == .cli && $0.cliType == cliType }.count
        let currentCount = dashboardExternalAuthStates[cliType.rawValue]?.isWizardConnected == true ? 1 : 0
        return existingCount + currentCount > 0 ? "Add Another OAuth Account" : "Add OAuth Account"
    }

    func startDifferentClaudeOAuthLogin(for method: BurnBarProviderAuthMethod) {
        guard method.isClaudeOAuthBearer else { return }
        Task {
            await addExternalOAuthAccount(for: method)
        }
    }

    func addExternalOAuthAccount(for method: BurnBarProviderAuthMethod) async {
        guard let providerID = selectedProviderID ?? activeProviderID,
              let cliType = externalCLIType(for: method) else {
            externalAccountActionMessage = "OpenBurnBar does not know which local CLI handles this sign-in method."
            return
        }

        isAddingExternalAccount = true
        externalAccountActionMessage = "Terminal will open an isolated \(cliType.displayName) login. Use a different account; this will not overwrite your current login."
        defer { isAddingExternalAccount = false }

        let existingProfiles = switcherProfiles.filter { $0.targetKind == .cli && $0.cliType == cliType }
        let slotLabel = nextExternalSlotLabel(providerID: providerID, cliType: cliType)
        let placeholder = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: slotLabel,
                providerID: canonicalOAuthProviderID(for: providerID, cliType: cliType),
                linkedHarnessIDs: [cliType.rawValue]
            ),
            sortKey: 0
        )

        let coordinator = SwitcherCLIAuthCoordinator()
        let result = await coordinator.reconnect(
            profile: placeholder,
            context: SwitcherCLIAuthCoordinator.ReconnectContext(
                providerSlotLabel: slotLabel,
                existingAccountLabels: existingProfiles.map { externalAccountLabel(for: $0, cliType: cliType) }
            )
        )

        switch result {
        case .readyToPersist(let updatedProfile), .requiresConfirmation(let updatedProfile, _, _):
            do {
                let saved = try persistExternalOAuthProfile(updatedProfile, providerID: providerID, cliType: cliType)
                let label = externalAccountLabel(for: saved, cliType: cliType)
                externalAccountActionMessage = "Added \(label) as a separate \(cliType.displayName) login."
                loadSwitcherProfiles()
                refreshDashboardExternalAuthStates()
                refreshExternalAuthStateIfNeeded()
                if let provider = cliType.agentProvider {
                    await quotaService.refresh(provider: provider, dataStore: dataStore)
                }
                if selectedAuthMethod?.isClaudeOAuthBearer == true,
                   let configDirectory = saved.cliMetadata?.configDirectory {
                    planLabel = planLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? label : planLabel
                    // Snapshot the freshly signed-in account's token into THIS
                    // profile's scoped Keychain item before importing. On macOS
                    // every Claude account shares one global Keychain item, so we
                    // must capture now (while this account owns it) and read back
                    // from the per-profile copy — never the global item, which
                    // would resolve to whichever account logged in last.
                    if let snapshotMessage = snapshotClaudeProfileCredential(for: saved) {
                        // macOS blocked the Keychain read — keep the actionable
                        // "Always Allow" guidance instead of attempting a readback
                        // that would fail with a generic message.
                        externalAccountActionMessage = snapshotMessage
                        return
                    }
                    importClaudeCodeOAuthBearer(
                        configDirectory: configDirectory,
                        accountLabel: label,
                        allowDefaultKeychainFallback: false
                    )
                    externalAccountActionMessage = "Added \(label). Claude Code stores route tokens in macOS Keychain, so BurnBar imported that freshly signed-in token into a per-account store."
                    return
                }
                activeProviderID = providerID
                navigateToStep(.dashboard)
            } catch {
                externalAccountActionMessage = error.localizedDescription
                saveError = error.localizedDescription
            }
        case .cancelled:
            externalAccountActionMessage = "\(cliType.displayName) login was cancelled. No OAuth account was added."
        case .failed(let message):
            externalAccountActionMessage = message
            saveError = message
        }
    }

    func reconnectExternalOAuthProfile(_ profile: SwitcherProfileRecord, providerID: String) {
        guard let cliType = profile.cliType else { return }

        Task {
            isAddingExternalAccount = true
            externalAccountActionMessage = "Opening \(cliType.displayName) login for \(externalAccountLabel(for: profile, cliType: cliType))."
            defer { isAddingExternalAccount = false }

            let coordinator = SwitcherCLIAuthCoordinator()
            let result = await coordinator.reconnect(
                profile: profile,
                context: SwitcherCLIAuthCoordinator.ReconnectContext(
                    providerSlotLabel: externalAccountLabel(for: profile, cliType: cliType),
                    existingAccountLabels: switcherProfiles
                        .filter { $0.id != profile.id && $0.targetKind == .cli && $0.cliType == cliType }
                        .map { externalAccountLabel(for: $0, cliType: cliType) }
                )
            )

            switch result {
            case .readyToPersist(let updatedProfile), .requiresConfirmation(let updatedProfile, _, _):
                do {
                    let refreshed = normalizedExternalOAuthProfile(
                        updatedProfile,
                        providerID: providerID,
                        cliType: cliType,
                        preserveIDForUpdate: true
                    )
                    _ = try dataStore.switcherStore.update(refreshed)
                    externalAccountActionMessage = "Reconnected \(externalAccountLabel(for: refreshed, cliType: cliType))."
                    loadSwitcherProfiles()
                    refreshDashboardExternalAuthStates()
                    refreshExternalAuthStateIfNeeded()
                    if let provider = cliType.agentProvider {
                        await quotaService.refresh(provider: provider, dataStore: dataStore)
                    }
                } catch {
                    externalAccountActionMessage = "Failed to update \(cliType.displayName) OAuth account: \(error.localizedDescription)"
                }
            case .cancelled:
                externalAccountActionMessage = "\(cliType.displayName) reconnect was cancelled."
            case .failed(let message):
                externalAccountActionMessage = message
            }
        }
    }

    func persistExternalOAuthProfile(
        _ updatedProfile: SwitcherProfileRecord,
        providerID: String,
        cliType: SwitcherCLIProfileType
    ) throws -> SwitcherProfileRecord {
        if let configDirectory = normalizedString(updatedProfile.cliMetadata?.configDirectory),
           let duplicate = duplicateExternalOAuthProfile(cliType: cliType, configDirectory: configDirectory, excludingID: updatedProfile.id) {
            throw ProviderPlanWizardError.message("Already added: \(externalAccountLabel(for: duplicate, cliType: cliType)) uses this local auth directory. Reconnect that OAuth profile instead of saving the same directory twice.")
        }

        let profile = normalizedExternalOAuthProfile(
            updatedProfile,
            providerID: providerID,
            cliType: cliType,
            preserveIDForUpdate: false
        )
        return try dataStore.switcherStore.create(profile)
    }

    func normalizedExternalOAuthProfile(
        _ profile: SwitcherProfileRecord,
        providerID: String,
        cliType: SwitcherCLIProfileType,
        preserveIDForUpdate: Bool
    ) -> SwitcherProfileRecord {
        let metadata = profile.cliMetadata ?? SwitcherCLIProfileMetadata()
        let accountDescription = normalizedString(metadata.accountDescription)
        let fallbackSlotLabel = normalizedString(metadata.displayLabel)
            ?? nextExternalSlotLabel(providerID: providerID, cliType: cliType)
        let duplicateIdentityCount = accountDescription.map {
            matchingExternalOAuthIdentityCount(
                cliType: cliType,
                accountDescription: $0,
                excludingID: preserveIDForUpdate ? profile.id : nil
            )
        } ?? 0
        let displayLabel: String = {
            guard let accountDescription else { return fallbackSlotLabel }
            if duplicateIdentityCount > 0 {
                return "\(accountDescription) · \(fallbackSlotLabel)"
            }
            return accountDescription
        }()

        return SwitcherProfileRecord(
            id: profile.id,
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: metadata.workingDirectory,
                additionalArgs: metadata.additionalArgs,
                envKeysToPass: metadata.envKeysToPass,
                displayLabel: displayLabel,
                configDirectory: metadata.configDirectory,
                accountDescription: metadata.accountDescription,
                providerID: canonicalOAuthProviderID(for: providerID, cliType: cliType),
                runtimeAccountID: metadata.runtimeAccountID,
                subscriptionTierID: metadata.subscriptionTierID,
                modelCapabilityClassID: metadata.modelCapabilityClassID,
                linkedHarnessIDs: metadata.linkedHarnessIDs.isEmpty ? [cliType.rawValue] : metadata.linkedHarnessIDs,
                neverAutoSwitch: metadata.neverAutoSwitch,
                lastQuotaExhaustedAt: metadata.lastQuotaExhaustedAt,
                exhaustedUntil: metadata.exhaustedUntil,
                lastQuotaExhaustionDetail: metadata.lastQuotaExhaustionDetail,
                isDisabled: metadata.isDisabled
            ),
            sortKey: preserveIDForUpdate ? profile.sortKey : 0,
            createdAt: preserveIDForUpdate ? profile.createdAt : Date(),
            updatedAt: Date()
        )
    }

    func duplicateExternalOAuthProfile(
        cliType: SwitcherCLIProfileType,
        configDirectory: String,
        excludingID: String?
    ) -> SwitcherProfileRecord? {
        switcherProfiles.first { profile in
            guard profile.id != excludingID,
                  profile.targetKind == .cli,
                  profile.cliType == cliType,
                  let existing = normalizedString(profile.cliMetadata?.configDirectory) else {
                return false
            }
            return existing == configDirectory
        }
    }

    func matchingExternalOAuthIdentityCount(
        cliType: SwitcherCLIProfileType,
        accountDescription: String,
        excludingID: String?
    ) -> Int {
        var count = switcherProfiles.filter { profile in
            guard profile.id != excludingID,
                  profile.targetKind == .cli,
                  profile.cliType == cliType,
                  let existing = normalizedString(profile.cliMetadata?.accountDescription) else {
                return false
            }
            return existing.caseInsensitiveCompare(accountDescription) == .orderedSame
        }.count

        if let current = dashboardExternalAuthStates[cliType.rawValue],
           current.isWizardConnected,
           let currentAccount = normalizedString(current.accountDescription),
           currentAccount.caseInsensitiveCompare(accountDescription) == .orderedSame {
            count += 1
        }

        return count
    }

    func nextExternalSlotLabel(providerID: String, cliType: SwitcherCLIProfileType) -> String {
        let providerName = daemonManager.providerConfigurations
            .first { $0.providerID == providerID }?.displayName ?? cliType.displayName
        let count = switcherProfiles.filter { $0.targetKind == .cli && $0.cliType == cliType }.count
        return count == 0 ? "\(providerName) OAuth primary" : "\(providerName) OAuth reserve #\(count)"
    }

    func canonicalOAuthProviderID(for providerID: String, cliType: SwitcherCLIProfileType) -> ProviderID {
        switch cliType {
        case .codex:
            return .openAI
        case .claude:
            return .anthropic
        case .opencode:
            return .openCode
        case .droid:
            return .factory
        case .forge:
            return ProviderID(rawValue: "forge")
        case .antigravity:
            return .antigravity
        case .grok:
            return .xAI
        case .cursorAgent:
            return ProviderID(rawValue: "cursor-agent")
        case .gemini:
            return AgentProvider.geminiCLI.providerID
        case .kimi:
            return .kimi
        case .pi:
            return AgentProvider.piAgent.providerID
        case .junie:
            return AgentProvider.junie.providerID
        case .fx:
            return AgentProvider.fx.providerID
        case .omp:
            return AgentProvider.omp.providerID
        case .primeAgent:
            return AgentProvider.primeAgent.providerID
        }
    }
}
