import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Plan Strategy

// Save and delete actions.
// Extracted from ProviderPlanWizardView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension ProviderPlanWizardView {

    func normalizedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalizedQuotaIdentifier(_ value: String?) -> String? {
        normalizedString(value)?.lowercased()
    }

    func loginCommands(for cliType: SwitcherCLIProfileType, executablePath: String) -> [String] {
        let candidates: [[String]]
        switch cliType {
        case .codex:
            candidates = [["login"], ["auth", "login"]]
        case .claude:
            candidates = [["auth", "login"], ["login"]]
        case .opencode, .droid, .forge, .antigravity, .grok, .cursorAgent, .gemini, .kimi, .pi, .omp, .junie, .primeAgent, .fx, .hermes, .goose, .windsurf, .openClaude, .openClaw:
            candidates = []
        }

        return candidates.map { args in
            ([executablePath] + args).map(shellEscape).joined(separator: " ")
        }
    }

    func makeLoginScript(command: String, title: String) throws -> URL {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))-\(UUID().uuidString).command")
        let contents = """
        #!/bin/zsh
        \(command)
        printf '\\nPress Enter to close...'
        read
        """
        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    func externalAuthStatusSummary(for authInfo: CLIAuthInfo) -> String {
        guard authInfo.isInstalled else {
            return "\(authInfo.cliType.displayName) is not installed."
        }

        switch authInfo.authState {
        case .authenticated:
            if let accountDescription = authInfo.accountDescription {
                return "Connected as \(accountDescription)."
            }
            return "Connected."
        case .apiKeyPresent:
            return "API key detected in the local CLI config."
        case .notAuthenticated:
            return "Installed, but not signed in yet."
        case .notInstalled:
            return "Not installed."
        }
    }

    func savePlan() {
        guard let providerID = selectedProviderID ?? activeProviderID,
              let method = selectedAuthMethod else { return }

        let label = planLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let storageCredential = credentialStorageOverrideVisibleToken == apiKey
            ? (credentialStorageOverride ?? apiKey)
            : apiKey
        if method.usesExternalLogin {
            refreshExternalAuthStateIfNeeded()
            guard externalAuthInfo?.isWizardConnected == true else {
                saveError = "Finish local sign-in, then refresh this check."
                return
            }
            activeProviderID = providerID
            navigateToStep(.dashboard)
            return
        }

        guard !apiKey.isEmpty, !method.storage.usesDaemonSlot || !label.isEmpty else { return }
        guard !method.validate(apiKey).isWarning else {
            saveError = method.validate(apiKey).message ?? "Enter a valid credential before saving."
            return
        }
        if providerID == "mimo", method.id == "mimo-token-plan", localMimoRegion == .global {
            saveError = "Select a Token Plan cluster (China, Singapore, or Europe)."
            return
        }

        isSaving = true
        saveError = nil

        Task {
            do {
                let mimoMetadata = mimoSlotMetadata(for: method, providerID: providerID)
                let newSlotID: String?
                if method.storage.usesDaemonSlot {
                    if let editingCredentialSlot,
                       editingCredentialSlot.providerID == providerID {
                        try await daemonManager.updateProviderCredentialSlotOrThrow(
                            providerID: providerID,
                            slotID: editingCredentialSlot.slotID,
                            label: label,
                            isEnabled: selectedStrategy != .backup,
                            apiKey: storageCredential,
                            endpointProfileID: mimoMetadata.endpointProfileID,
                            region: mimoMetadata.region,
                            tokenPlanTier: mimoMetadata.tokenPlanTier,
                            tokenPlanBillingCycle: mimoMetadata.tokenPlanBillingCycle,
                            authMethodID: mimoMetadata.authMethodID
                        )
                        newSlotID = editingCredentialSlot.slotID
                    } else {
                        newSlotID = try await daemonManager.addProviderCredentialSlotReturningID(
                            providerID: providerID,
                            label: label,
                            apiKey: storageCredential,
                            isEnabled: selectedStrategy != .backup,
                            endpointProfileID: mimoMetadata.endpointProfileID,
                            region: mimoMetadata.region,
                            tokenPlanTier: mimoMetadata.tokenPlanTier,
                            tokenPlanBillingCycle: mimoMetadata.tokenPlanBillingCycle,
                            authMethodID: mimoMetadata.authMethodID
                        )
                    }
                } else {
                    newSlotID = nil
                }

                if let mirrorAccount = method.storage.mirrorAccountIdentifier {
                    do {
                        try await MainActor.run {
                            try ProviderAPIKeyStore.shared.setAPIKey(storageCredential, for: mirrorAccount)
                        }
                    } catch {
                        AppLogger.dataStore.silentFailure(
                            "ProviderPlanWizardView: failed to mirror credential to keychain",
                            error: error
                        )
                        if !method.storage.usesDaemonSlot {
                            throw error
                        }
                    }
                }

                if let newSlotID {
                    switch selectedStrategy {
                    case .auto:
                        break
                    case .preferred:
                        try await daemonManager.setPreferredProviderCredentialSlotOrThrow(
                            providerID: providerID,
                            slotID: newSlotID
                        )
                    case .backup:
                        break
                    }

                    await daemonManager.refreshProviderCredentialSlotQuotas(providerID: providerID)
                }
                await refreshGatewayAdvertisementState()

                if providerID == "mimo", method.id == "mimo-token-plan" {
                    await MainActor.run {
                        daemonManager.settingsManager.mimoTokenPlanRegion = localMimoRegion
                        daemonManager.settingsManager.mimoTokenPlanTier = localMimoTier
                        daemonManager.settingsManager.mimoTokenPlanBillingCycle = localMimoBillingCycle
                    }
                }

                await MainActor.run {
                    Analytics.shared.track(.quotaSetupSaved, [
                        "provider_name": .string(providerID),
                        "setup_type": .string(method.storage.usesDaemonSlot ? "daemon_slot" : "api_key_store")
                    ])
                    isSaving = false
                    editingCredentialSlot = nil
                    activeProviderID = providerID
                    navigateToStep(.dashboard)
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        }
    }

    func deleteSlot(_ target: SlotDeleteTarget) {
        pendingDeletion = nil
        guard deletingAccountID != target.slotID else { return }
        deletingAccountID = target.slotID
        externalAccountActionMessage = "Removing \(target.slotLabel)…"
        Task {
            let removed = await daemonManager.removeProviderCredentialSlotReporting(
                providerID: target.providerID,
                slotID: target.slotID
            )
            if removed {
                let accountID = DaemonCredentialSlotAccountProjection.accountID(
                    daemonProviderID: target.providerID,
                    slotID: target.slotID
                )
                try? await dataStore.deleteProviderAccount(id: accountID)
            }
            await refreshGatewayAdvertisementState()
            await MainActor.run {
                deletingAccountID = nil
                if removed {
                    externalAccountActionMessage = "Removed \(target.slotLabel)."
                } else {
                    let reason = daemonManager.lastError ?? "the daemon rejected the change."
                    externalAccountActionMessage = "Couldn't remove \(target.slotLabel): \(reason) Try again."
                }
            }
        }
    }

    func deleteExternalAccount(_ target: ExternalAccountDeleteTarget) {
        pendingDeletion = nil
        do {
            try SwitcherAuthStore().deleteCredentials(forProfileID: target.profileID)
            try dataStore.switcherStore.deleteProfile(id: target.profileID)
            externalAccountActionMessage = "Removed \(target.label)."
            loadSwitcherProfiles()
            refreshDashboardExternalAuthStates()
            refreshExternalAuthStateIfNeeded()
            if let provider = target.cliType.agentProvider {
                Task { await quotaService.refresh(provider: provider, dataStore: dataStore) }
            }
        } catch {
            externalAccountActionMessage = "Failed to remove \(target.label): \(error.localizedDescription)"
        }
    }

    var mimoTokenPlanConnectFields: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Token Plan cluster")
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Picker("", selection: $localMimoRegion) {
                Text("China").tag(ProviderEndpointRegion.cn)
                Text("Singapore").tag(ProviderEndpointRegion.sgp)
                Text("Europe (Amsterdam)").tag(ProviderEndpointRegion.ams)
            }
            .pickerStyle(.menu)

            Text("Subscription tier (for BurnBar credit tracking when vendor remains is unavailable)")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Picker("", selection: $localMimoTier) {
                ForEach(MimoTokenPlanTier.allCases) { tier in
                    Text(tier.displayName).tag(tier)
                }
            }
            .pickerStyle(.menu)

            Picker("", selection: $localMimoBillingCycle) {
                Text("Monthly").tag(MimoTokenPlanBillingCycle.monthly)
                Text("Annual").tag(MimoTokenPlanBillingCycle.annual)
            }
            .pickerStyle(.segmented)
        }
        .padding(.top, DesignSystem.Spacing.xs)
    }

    struct MimoSlotMetadata {
        let endpointProfileID: String?
        let region: ProviderEndpointRegion?
        let tokenPlanTier: MimoTokenPlanTier?
        let tokenPlanBillingCycle: MimoTokenPlanBillingCycle?
        let authMethodID: String?
    }
    func mimoSlotMetadata(
        for method: BurnBarProviderAuthMethod,
        providerID: String
    ) -> MimoSlotMetadata {
        guard providerID == "mimo" else {
            return MimoSlotMetadata(
                endpointProfileID: nil,
                region: nil,
                tokenPlanTier: nil,
                tokenPlanBillingCycle: nil,
                authMethodID: nil
            )
        }

        switch method.id {
        case "mimo-token-plan":
            let profile = ProviderEndpointProfileRegistry.mimoTokenPlan(region: localMimoRegion)
            return MimoSlotMetadata(
                endpointProfileID: profile.id,
                region: localMimoRegion,
                tokenPlanTier: localMimoTier,
                tokenPlanBillingCycle: localMimoBillingCycle,
                authMethodID: method.id
            )
        case "mimo-payg":
            let profile = ProviderEndpointProfileRegistry.mimoPayg
            return MimoSlotMetadata(
                endpointProfileID: profile.id,
                region: .global,
                tokenPlanTier: nil,
                tokenPlanBillingCycle: nil,
                authMethodID: method.id
            )
        default:
            return MimoSlotMetadata(
                endpointProfileID: nil,
                region: nil,
                tokenPlanTier: nil,
                tokenPlanBillingCycle: nil,
                authMethodID: method.id
            )
        }
    }
}
