import AppKit
import OpenBurnBarKernel
import OpenBurnBarLaunchServices
import SwiftUI

// MARK: - ConnectionsSettingsView + External OAuth

extension ConnectionsSettingsView {
    func credentialNotice(for account: ExternalOAuthAccount) -> ExternalOAuthCredentialNotice? {
        guard let provider = account.cliType.agentProvider else { return nil }

        let authInfo = externalAuthInfo(for: account)
        let snapshot = exactExternalQuotaSnapshot(for: account, provider: provider)
        let kind = Self.classifyExternalCredentialNotice(
            isDisabled: account.isDisabled,
            isCurrentLogin: account.isCurrentLogin,
            hasQuotaWindows: !quotaWindows(for: account).isEmpty,
            authConnected: authInfo.map(isExternalAuthConnected),
            snapshotSource: snapshot?.sourceKind,
            snapshotConfidence: snapshot?.confidence
        )

        guard let kind else { return nil }
        switch kind {
        case .credentialMissing:
            // Prefer the most specific explanation available, mirroring the
            // previous message precedence (auth state → snapshot → default).
            if let authInfo, !isExternalAuthConnected(authInfo) {
                return .credentialMissing(
                    cliType: account.cliType,
                    message: credentialMissingMessage(for: account, authInfo: authInfo)
                )
            }
            if let snapshot {
                return .credentialMissing(
                    cliType: account.cliType,
                    message: credentialMissingMessage(
                        for: account,
                        snapshotMessage: normalizedString(snapshot.statusMessage)
                    )
                )
            }
            return .credentialMissing(cliType: account.cliType)
        case .quotaUnavailable:
            if let statusMessage = normalizedString(snapshot?.statusMessage) {
                return .quotaUnavailable(message: statusMessage)
            }
            return .quotaUnavailable(
                message: "\(account.cliType.displayName) credential is present, but no quota snapshot has been captured for this profile yet. Refresh to capture current quota."
            )
        }
    }

    /// Confirmation line shown after a manual credential refresh. Mirrors the
    /// row's own notice so the acknowledgement is truthful: a refreshed,
    /// connected credential reads as success even when the provider returns no
    /// quota — rather than promising a quota meter that will never appear.
    private func refreshConfirmationMessage(for account: ExternalOAuthAccount) -> String {
        let name = account.cliType.displayName
        guard let kind = credentialNotice(for: account)?.kind else {
            return "Credential refreshed. Quota captured for this profile."
        }
        switch kind {
        case .quotaUnavailable:
            return "Credential refreshed and connected. \(name) returned no current quota, so this profile won't show a quota meter yet."
        case .credentialMissing:
            return "Refresh finished, but no usable \(name) credential was captured for this profile. Open the \(name) login again to finish signing in."
        }
    }

    private func externalAuthInfo(for account: ExternalOAuthAccount) -> CLIAuthInfo? {
        if let profileID = account.profileID {
            return externalAuthStates[profileID]
        }
        return externalAuthStates[account.cliType.rawValue]
    }

    private func credentialMissingMessage(
        for account: ExternalOAuthAccount,
        snapshotMessage: String?
    ) -> String {
        if let snapshotMessage,
           !snapshotMessage.localizedCaseInsensitiveContains("stale") {
            return snapshotMessage
        }

        return "No \(account.cliType.displayName) OAuth credential was found for this profile. Refresh the credential to capture current quota."
    }

    private func credentialMissingMessage(
        for account: ExternalOAuthAccount,
        authInfo: CLIAuthInfo
    ) -> String {
        switch authInfo.authState {
        case .notInstalled:
            return "\(account.cliType.displayName) is not installed or not reachable from BurnBar, so this profile's credential cannot be verified."
        case .notAuthenticated:
            return "No \(account.cliType.displayName) OAuth credential was found in this saved profile. Refresh the credential to sign in again and capture current quota."
        case .authenticated, .apiKeyPresent:
            return "No \(account.cliType.displayName) OAuth credential was found for this profile. Refresh the credential to capture current quota."
        }
    }

    func exactExternalQuotaSnapshot(
        for account: ExternalOAuthAccount,
        provider: AgentProvider
    ) -> ProviderQuotaSnapshot? {
        let snapshots = quotaService.snapshots(for: provider.providerID)

        if let profileID = account.profileID {
            let normalizedProfileID = normalizedQuotaIdentifier(profileID)
            let normalizedProfileSourceIDs = Set([
                "switcher-cli:\(account.cliType.rawValue):\(profileID)",
                "switcher:\(profileID)"
            ].compactMap(normalizedQuotaIdentifier))
            return snapshots.first { snapshot in
                normalizedQuotaIdentifier(snapshot.accountID) == normalizedProfileID
                    || normalizedQuotaIdentifier(snapshot.sourceId).map { normalizedProfileSourceIDs.contains($0) } == true
            }
        }

        return snapshots.first { snapshot in
            normalizedString(snapshot.accountLabel)?.caseInsensitiveCompare(account.label) == .orderedSame
        }
    }

    func refreshExternalCredential(for account: ExternalOAuthAccount) {
        Task { @MainActor in
            await refreshExternalCredentialNow(for: account)
        }
    }

    @MainActor
    private func refreshExternalCredentialNow(for account: ExternalOAuthAccount) async {
        refreshingExternalCredentialIDs.insert(account.id)
        externalCredentialMessages[account.id] = account.isCurrentLogin
            ? "Refreshing \(account.cliType.displayName) status..."
            : "Opening \(account.cliType.displayName) login for \(account.label)..."
        defer {
            refreshingExternalCredentialIDs.remove(account.id)
        }

        if account.isCurrentLogin {
            refreshExternalAuthStates()
            // The default local Claude login lives in the ACL-locked global
            // Keychain item, which background quota refresh cannot read. Capture
            // it into the per-profile item the quota reader resolves, while this
            // user action lets macOS show the "Always Allow" prompt. Capture
            // BEFORE the quota refresh below so the same refresh reads the
            // freshly populated item. Non-fatal: a denial only defers quota, so
            // we surface the actionable ACL guidance and still refresh.
            var captureMessage: String?
            if account.cliType == .claude {
                do {
                    try SwitcherCLIAuthCoordinator.captureDefaultLoginProfileCredential(
                        configDirectory: defaultClaudeLoginConfigDirectory(for: account)
                    )
                } catch let captureError as ClaudeCodeOAuthCredentialImportError {
                    if case .accessDenied = captureError {
                        captureMessage = captureError.localizedDescription
                    }
                } catch {
                    AppLogger.shared.error(
                        "claude_default_login_credential_capture_failed",
                        metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                    )
                }
            }
            if let provider = account.cliType.agentProvider {
                await quotaService.refresh(provider: provider, dataStore: dataStore)
            }
            // Prefer the actionable ACL message (so the user knows to grant
            // access); otherwise report the routine status.
            externalCredentialMessages[account.id] = captureMessage
                ?? "Refreshed \(account.cliType.displayName) status."
            return
        }

        guard let profileID = account.profileID,
              let profile = switcherProfiles.first(where: { $0.id == profileID }) else {
            externalCredentialMessages[account.id] = "Could not find the saved \(account.cliType.displayName) profile. Reload Accounts and try again."
            loadSwitcherProfiles()
            return
        }

        let coordinator = SwitcherCLIAuthCoordinator()
        let result = await coordinator.reconnect(
            profile: profile,
            context: SwitcherCLIAuthCoordinator.ReconnectContext(
                providerSlotLabel: account.label,
                existingAccountLabels: switcherProfiles
                    .filter { $0.id != profile.id && $0.targetKind == .cli && $0.cliType == account.cliType }
                    .map { externalAccountLabel(for: $0, cliType: account.cliType) }
            )
        )

        switch result {
        case .readyToPersist(let updatedProfile), .requiresConfirmation(let updatedProfile, _, _):
            do {
                let refreshed = normalizedExternalOAuthProfile(
                    updatedProfile,
                    providerID: account.providerID.rawValue,
                    cliType: account.cliType
                )
                _ = try dataStore.switcherStore.update(refreshed)
                var captureMessage: String?
                // Reconnect no longer snapshots the route token itself (a flaky
                // Keychain must never discard a confirmed re-auth). Snapshot it
                // here, non-fatally: the profile is already saved, so a denial
                // only defers quota tracking. Surfaces the actionable ACL message
                // when macOS blocks the read.
                if account.cliType == .claude {
                    do {
                        try SwitcherCLIAuthCoordinator.persistProfileCredentialAfterConfirmedLogin(for: refreshed)
                    } catch let snapshotError as ClaudeCodeOAuthCredentialImportError {
                        if case .accessDenied = snapshotError {
                            captureMessage = snapshotError.localizedDescription
                        }
                    } catch {
                        AppLogger.shared.error(
                            "claude_route_credential_snapshot_failed",
                            metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                        )
                    }
                }
                loadSwitcherProfiles()
                refreshExternalAuthStates()
                externalCredentialMessages[account.id] = "Credential refreshed. Updating quota..."
                if let provider = account.cliType.agentProvider {
                    await quotaService.refresh(provider: provider, dataStore: dataStore)
                }
                // Re-read state after the quota refresh so the confirmation
                // reflects what actually happened — connected with quota,
                // connected without quota, or still missing — instead of
                // unconditionally promising quota that some accounts never
                // expose.
                refreshExternalAuthStates()
                externalCredentialMessages[account.id] = captureMessage ?? refreshConfirmationMessage(for: account)
            } catch {
                externalCredentialMessages[account.id] = "Failed to save refreshed credential: \(error.localizedDescription)"
            }
        case .cancelled:
            externalCredentialMessages[account.id] = "\(account.cliType.displayName) credential refresh was cancelled."
        case .failed(let message):
            externalCredentialMessages[account.id] = message
        }
    }

    private func normalizedExternalOAuthProfile(
        _ profile: SwitcherProfileRecord,
        providerID: String,
        cliType: SwitcherCLIProfileType
    ) -> SwitcherProfileRecord {
        let metadata = profile.cliMetadata ?? SwitcherCLIProfileMetadata()
        let accountDescription = normalizedString(metadata.accountDescription)
        let displayLabel = accountDescription
            ?? normalizedString(metadata.displayLabel)
            ?? externalAccountLabel(for: profile, cliType: cliType)

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
            sortKey: profile.sortKey,
            createdAt: profile.createdAt,
            updatedAt: Date()
        )
    }

    private func canonicalOAuthProviderID(for providerID: String, cliType: SwitcherCLIProfileType) -> ProviderID {
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
        case .hermes:
            return AgentProvider.hermes.providerID
        case .goose:
            return AgentProvider.goose.providerID
        case .windsurf:
            return AgentProvider.windsurf.providerID
        case .openClaude:
            return AgentProvider.openClaude.providerID
        case .openClaw:
            return AgentProvider.openClaw.providerID
        }
    }

    func isExternalAuthConnected(_ authInfo: CLIAuthInfo) -> Bool {
        switch authInfo.authState {
        case .authenticated, .apiKeyPresent:
            return true
        case .notAuthenticated, .notInstalled:
            return false
        }
    }

    func providerDisplayName(_ providerID: ProviderID) -> String {
        if let catalogProvider = BurnBarCatalogLoader.bundledCatalog.provider(id: providerID.rawValue) {
            return catalogProvider.displayName
        }
        return AgentProvider.fromProviderID(providerID)?.displayName ?? providerID.rawValue
    }

    func normalizedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The config directory whose per-profile Keychain item should hold the
    /// default Claude login's captured token. The account row carries the
    /// discovered config directory in `detail`; fall back to `~/.claude` (the
    /// canonical default) when discovery did not surface a path, so the captured
    /// item hashes to the same service the quota reader resolves for the default
    /// login.
    private func defaultClaudeLoginConfigDirectory(for account: ExternalOAuthAccount) -> String {
        normalizedString(account.detail)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
                .path
    }

    private func normalizedQuotaIdentifier(_ value: String?) -> String? {
        normalizedString(value)?.lowercased()
    }
}
