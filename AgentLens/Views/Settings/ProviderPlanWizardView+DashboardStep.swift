import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Plan Strategy

// Dashboard step view.
// Extracted from ProviderPlanWizardView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension ProviderPlanWizardView {

    @ViewBuilder
    func progressNode(_ step: ProviderPlanWizardStep) -> some View {
        let isCurrent = step == currentStep
        let isPast = step.rawValue < currentStep.rawValue
        let accent = stepAccentGradient

        ZStack {
            Circle()
                .fill(isPast || isCurrent ? AnyShapeStyle(accent) : AnyShapeStyle(DesignSystem.Colors.surfaceElevated))
                .frame(width: 22, height: 22)
                .overlay(
                    Circle().stroke(
                        isCurrent ? DesignSystem.Colors.blaze : DesignSystem.Colors.border,
                        lineWidth: isCurrent ? 1.5 : 0.5
                    )
                )

            if isPast {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white)
            } else if let index = step.stepIndex {
                Text("\(index)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isCurrent ? .white : DesignSystem.Colors.textSecondary)
            }
        }
        .accessibilityLabel("Step \(step.stepIndex.map(String.init) ?? "") \(step.shortTitle)")
    }

    @ViewBuilder
    func progressConnector(after step: ProviderPlanWizardStep) -> some View {
        let isCompleted = step.rawValue < currentStep.rawValue
        Rectangle()
            .fill(isCompleted ? AnyShapeStyle(stepAccentGradient) : AnyShapeStyle(DesignSystem.Colors.border))
            .frame(width: 26, height: 2)
            .padding(.horizontal, 2)
    }

    var stepAccentGradient: LinearGradient {
        if let provider = selectedProvider {
            let primary = ProviderBrand.colorForProviderID(provider.providerID)
            return LinearGradient(
                colors: [primary.opacity(0.95), DesignSystem.Colors.blaze.opacity(0.95)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [DesignSystem.Colors.blaze, DesignSystem.Colors.blaze.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    var stepContent: some View {
        switch currentStep {
        case .dashboard: dashboardStep
        case .provider: providerSelectionStep
        case .auth: authMethodStep
        case .credential: credentialEntryStep
        case .strategy: strategySelectionStep
        case .confirm: confirmStep
        }
    }

    @ViewBuilder
    var dashboardStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            if eligibleProviders.isEmpty {
                emptyDaemonNotice
            } else if let provider = activeProvider {
                providerHero(provider)
                gatewayAdvertisementNotice(provider)
                if let error = switcherProfileLoadError {
                    errorCallout(error)
                }
                if let externalAccountActionMessage {
                    miniHintCard(
                        symbol: externalAccountActionMessage.localizedCaseInsensitiveContains("failed")
                            ? "exclamationmark.triangle.fill"
                            : "info.circle.fill",
                        text: externalAccountActionMessage
                    )
                }
                providerSlotList(provider)
                addPlanCTA(providerID: provider.providerID)
            } else {
                Text("Select a provider to manage its accounts, or bring a key for a new one. You can keep adding accounts so OpenBurnBar can fail over when one runs out.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Button {
                    selectedProviderID = nil
                    selectedAuthMethodID = nil
                    credentialStorageOverride = nil
                    credentialStorageOverrideVisibleToken = nil
                    navigateToStep(.provider)
                } label: {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Add an account")
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.sm + 2)
                    .background(stepAccentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    var emptyDaemonNotice: some View {
        ContentUnavailableView {
            Label("Daemon not ready", systemImage: "exclamationmark.bubble")
        } description: {
            Text("OpenBurnBar's daemon hasn't returned a provider list yet. Make sure it's installed and running.")
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSystem.Spacing.xl)
        .background(DesignSystem.Colors.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    func errorCallout(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.warning)
                .padding(.top, 1)
            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.warning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    @ViewBuilder
    func providerHero(_ provider: OpenBurnBarDaemonProviderConfiguration) -> some View {
        let descriptor = self.descriptor(for: provider.providerID)
        let primary = ProviderBrand.colorForProviderID(provider.providerID)
        let proxyChip = proxyReadinessChip(for: provider)
        let gradient = LinearGradient(
            colors: [primary.opacity(0.32), primary.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(gradient)
                        .frame(width: 56, height: 56)
                    CatalogProviderLogoView(brand: provider.brand, size: 36)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.displayName)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(descriptor.summary)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(2)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { provider.isEnabled },
                    set: { enabled in
                        Task {
                            await daemonManager.updateProviderConfiguration(
                                providerID: provider.providerID,
                                isEnabled: enabled
                            )
                            await refreshGatewayAdvertisementState()
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: DesignSystem.Colors.blaze))
            }

            HStack(spacing: 6) {
                if descriptor.supportsProxyRouting && provider.hasRoutingCapability {
                    capabilityChip(label: proxyChip.label, system: proxyChip.system, tint: proxyChip.tint)
                }
                if descriptor.supportsQuotaRefresh {
                    capabilityChip(label: "Live quota", system: "gauge.with.needle", tint: DesignSystem.Colors.success)
                }
                if !descriptor.supportsProxyRouting && !provider.hasRoutingCapability {
                    capabilityChip(label: "Tracking only", system: "chart.bar.doc.horizontal", tint: DesignSystem.Colors.textMuted)
                }
                Spacer()
                Text(provider.baseURL.isEmpty ? "Daemon-managed" : provider.baseURL)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [primary.opacity(0.6), primary.opacity(0.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }

    func proxyReadinessChip(
        for provider: OpenBurnBarDaemonProviderConfiguration
    ) -> (label: String, system: String, tint: Color) {
        guard provider.hasRoutingCapability else {
            return ("Tracking only", "chart.bar.doc.horizontal", DesignSystem.Colors.textMuted)
        }

        if !provider.isEnabled {
            return ("Proxy off", "power", DesignSystem.Colors.textMuted)
        }

        if !provider.routeReadyCredentialSlots.isEmpty {
            if let advertisedProviderIDs = gatewayAdvertisedProviderIDs {
                if !advertisedProviderIDs.contains(ProviderID.normalize(provider.providerID)),
                   let issue = gatewayProviderRouteIssues[ProviderID.normalize(provider.providerID)] {
                    return (gatewayRouteIssueLabel(for: issue), "exclamationmark.triangle.fill", DesignSystem.Colors.warning)
                }
                return advertisedProviderIDs.contains(ProviderID.normalize(provider.providerID))
                    ? ("Advertised", "checkmark.seal.fill", DesignSystem.Colors.success)
                    : ("Not advertised", "exclamationmark.triangle.fill", DesignSystem.Colors.warning)
            }

            if gatewayAdvertisementError != nil {
                return ("Gateway unverified", "questionmark.circle.fill", DesignSystem.Colors.warning)
            }

            return ("Proxy credential saved", "checkmark.seal.fill", DesignSystem.Colors.success)
        }

        if provider.credentialSlots.isEmpty {
            return ("Proxy needs credential", "key.fill", DesignSystem.Colors.warning)
        }

        return ("Proxy blocked", "exclamationmark.triangle.fill", DesignSystem.Colors.warning)
    }

    @ViewBuilder
    func gatewayAdvertisementNotice(_ provider: OpenBurnBarDaemonProviderConfiguration) -> some View {
        if !provider.routeReadyCredentialSlots.isEmpty,
           let advertisedProviderIDs = gatewayAdvertisedProviderIDs,
           !advertisedProviderIDs.contains(ProviderID.normalize(provider.providerID)) {
            let issue = gatewayProviderRouteIssues[ProviderID.normalize(provider.providerID)]
                ?? "The live /v1/models gateway is not advertising this provider yet. Refresh or repair the daemon, then test again."
            errorCallout("\(provider.displayName) is not routable. \(issue)")
        } else if !provider.routeReadyCredentialSlots.isEmpty,
                  let gatewayAdvertisementError {
            errorCallout("BurnBar has a route credential saved for \(provider.displayName), but the local gateway catalog check did not finish. \(gatewayAdvertisementError)")
        }
    }

    @ViewBuilder
    func capabilityChip(label: String, system: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: system).font(.system(size: 9, weight: .semibold))
            Text(label).font(DesignSystem.Typography.tiny).fontWeight(.medium)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.14))
        .foregroundStyle(tint)
        .clipShape(Capsule())
    }

    @ViewBuilder
    func providerSlotList(_ provider: OpenBurnBarDaemonProviderConfiguration) -> some View {
        let externalAccounts = visibleExternalOAuthAccounts(for: provider)

        if provider.credentialSlots.isEmpty && externalAccounts.isEmpty {
            VStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: provider.hasRoutingCapability ? "key.slash" : "tray")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(provider.hasRoutingCapability ? "No route credentials yet" : "No accounts yet")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text(emptyAccountCopy(for: provider))
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(DesignSystem.Spacing.xl)
            .background(DesignSystem.Colors.surfaceElevated.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        } else {
            VStack(spacing: DesignSystem.Spacing.sm) {
                if provider.credentialSlots.isEmpty {
                    errorCallout(routeCredentialMissingMessage(for: provider))
                }
                ForEach(provider.credentialSlots) { slot in
                    planCard(slot, provider: provider)
                }
                if !externalAccounts.isEmpty {
                    if !provider.credentialSlots.isEmpty {
                        HStack {
                            Text("Local OAuth sign-ins")
                                .font(DesignSystem.Typography.tiny)
                                .fontWeight(.semibold)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                            Spacer()
                        }
                        .padding(.top, DesignSystem.Spacing.xs)
                    }
                    ForEach(externalAccounts) { account in
                        externalOAuthAccountCard(account, provider: provider)
                    }
                }
            }
        }
    }

    func emptyAccountCopy(for provider: OpenBurnBarDaemonProviderConfiguration) -> String {
        if supportsExternalOAuth(for: provider.providerID) {
            return routeCredentialMissingMessage(for: provider)
        }
        return "Add a credential to start using this provider through OpenBurnBar."
    }

    func routeCredentialMissingMessage(for provider: OpenBurnBarDaemonProviderConfiguration) -> String {
        if !provider.hasRoutingCapability {
            return "This provider is for account and quota tracking only."
        }
        return "\(provider.displayName) is switched on, but BurnBar has no route credential saved for it. Add an API key or provider OAuth bearer to make the local proxy serve this provider. Local CLI sign-ins below are only for account and quota status."
    }

    func providerAccountCount(_ provider: OpenBurnBarDaemonProviderConfiguration) -> Int {
        provider.credentialSlots.count
    }

    func supportsExternalOAuth(for providerID: String) -> Bool {
        if externalCLIType(forProviderID: providerID) != nil {
            return true
        }
        return descriptor(for: providerID).methods.contains { method in
            method.usesExternalLogin && externalCLIType(forProviderID: providerID) != nil
        }
    }

    func visibleExternalOAuthAccounts(for provider: OpenBurnBarDaemonProviderConfiguration) -> [ExternalOAuthAccount] {
        guard supportsExternalOAuth(for: provider.providerID),
              let cliType = externalCLIType(forProviderID: provider.providerID) else {
            return []
        }

        let storedAccounts = switcherProfiles
            .filter { $0.targetKind == .cli && $0.cliType == cliType }
            .map { profile in
                ExternalOAuthAccount(
                    id: profile.id,
                    cliType: cliType,
                    label: externalAccountLabel(for: profile, cliType: cliType),
                    detail: normalizedString(profile.cliMetadata?.configDirectory),
                    statusText: "Local \(cliType.displayName) profile for account and quota status. Add it as an OpenBurnBar credential to route requests.",
                    isCurrentLogin: false,
                    isDisabled: profile.isDisabled,
                    profile: profile
                )
            }

        let current = dashboardExternalAuthStates[cliType.rawValue]
            ?? CLIAuthDiscovery.discoverAuthState(for: cliType)
        guard current.isWizardConnected,
              !storedProfileDuplicatesCurrentAuth(cliType: cliType, authInfo: current) else {
            return storedAccounts
        }

        let currentAccount = ExternalOAuthAccount(
            id: "current-\(cliType.rawValue)-\(normalizedString(current.accountDescription) ?? normalizedString(current.configDirectory) ?? "default")",
            cliType: cliType,
            label: normalizedString(current.accountDescription) ?? "Current \(cliType.displayName) login",
            detail: normalizedString(current.configDirectory),
            statusText: current.authState == .apiKeyPresent
                ? "Detected from the default local \(cliType.displayName) API-key config for account status. Add it as an OpenBurnBar credential to route requests."
                : "Detected from the default local \(cliType.displayName) OAuth sign-in for account status. Add a provider OAuth credential to route requests.",
            isCurrentLogin: true,
            isDisabled: false,
            profile: nil
        )
        return [currentAccount] + storedAccounts
    }

    func storedProfileDuplicatesCurrentAuth(cliType: SwitcherCLIProfileType, authInfo: CLIAuthInfo) -> Bool {
        let authDirectory = normalizedString(authInfo.configDirectory)

        return switcherProfiles.contains { profile in
            guard profile.targetKind == .cli,
                  profile.cliType == cliType else {
                return false
            }

            if let authDirectory,
               let profileDirectory = normalizedString(profile.cliMetadata?.configDirectory),
               profileDirectory == authDirectory {
                return true
            }

            return false
        }
    }

    func externalAccountLabel(for profile: SwitcherProfileRecord, cliType: SwitcherCLIProfileType) -> String {
        let accountDescription = normalizedString(profile.cliMetadata?.accountDescription)
        let displayLabel = normalizedString(profile.cliMetadata?.displayLabel)
        if let accountDescription,
           let displayLabel,
           displayLabel != accountDescription,
           displayLabel.localizedCaseInsensitiveContains(accountDescription) {
            return displayLabel
        }
        return accountDescription
            ?? displayLabel
            ?? normalizedString(profile.displayName)
            ?? "\(cliType.displayName) OAuth profile"
    }

    @ViewBuilder
    func externalOAuthAccountCard(_ account: ExternalOAuthAccount, provider: OpenBurnBarDaemonProviderConfiguration) -> some View {
        let tint = account.isDisabled ? DesignSystem.Colors.textMuted : DesignSystem.Colors.warning

        VStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(tint.opacity(0.35), lineWidth: 4)
                            .frame(width: 16, height: 16)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.label)
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.medium)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(account.isCurrentLogin ? "CLI login only" : "CLI profile only")
                            .font(DesignSystem.Typography.tiny)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.12))
                            .foregroundStyle(tint)
                            .clipShape(Capsule())

                        if account.isDisabled {
                            Text("Disabled")
                                .font(DesignSystem.Typography.tiny)
                                .fixedSize()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DesignSystem.Colors.textMuted.opacity(0.12))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .clipShape(Capsule())
                        }
                    }

                    Text(account.statusText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                    if let detail = account.detail {
                        Text(detail)
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    if account.isCurrentLogin {
                        slotButton("arrow.clockwise", help: "Refresh local OAuth status") {
                            refreshDashboardExternalAuthStates()
                            Task {
                                if let provider = account.cliType.agentProvider {
                                    await quotaService.refresh(provider: provider, dataStore: dataStore)
                                }
                            }
                        }
                    } else if let profile = account.profile {
                        slotButton("person.crop.circle.badge.checkmark", help: "Reconnect this OAuth profile") {
                            reconnectExternalOAuthProfile(profile, providerID: provider.providerID)
                        }
                        slotButton("trash", help: "Remove this OAuth profile", tint: DesignSystem.Colors.error) {
                            externalAccountToDelete = ExternalAccountDeleteTarget(
                                profileID: profile.id,
                                label: account.label,
                                cliType: account.cliType
                            )
                        }
                    }
                }
                .fixedSize()
            }

            let quotaWindows = externalOAuthQuotaWindows(for: account)
            if !quotaWindows.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        ForEach(quotaWindows) { window in
                            externalQuotaPill(window)
                        }
                        Spacer(minLength: 0)
                    }
                    FlowLayout(
                        horizontalSpacing: DesignSystem.Spacing.xs,
                        verticalSpacing: DesignSystem.Spacing.xs
                    ) {
                        ForEach(quotaWindows) { window in
                            externalQuotaPill(window)
                        }
                    }
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    func externalOAuthQuotaWindows(for account: ExternalOAuthAccount) -> [SwitcherQuotaWindowDisplay] {
        guard let provider = account.cliType.agentProvider else { return [] }

        if let accountSnapshot = exactExternalQuotaSnapshot(for: account, provider: provider) {
            let windows = switcherQuotaWindowDisplays(snapshot: accountSnapshot)
            if !windows.isEmpty { return windows }
        }

        if account.isCurrentLogin {
            return switcherQuotaWindowDisplays(snapshot: quotaService.snapshot(for: provider))
        }

        return []
    }

    func exactExternalQuotaSnapshot(
        for account: ExternalOAuthAccount,
        provider: AgentProvider
    ) -> ProviderQuotaSnapshot? {
        let snapshots = quotaService.snapshots(for: provider.providerID)

        if let profile = account.profile {
            let normalizedProfileID = normalizedQuotaIdentifier(profile.id)
            let normalizedProfileSourceIDs = Set([
                "switcher-cli:\(account.cliType.rawValue):\(profile.id)",
                "switcher:\(profile.id)"
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

    @ViewBuilder
    func externalQuotaPill(_ window: SwitcherQuotaWindowDisplay) -> some View {
        HStack(spacing: 4) {
            Text(window.label)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(window.remaining)
                .font(DesignSystem.Typography.monoTiny)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.success)
            Text(window.resetText)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.72))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5))
    }

    @ViewBuilder
    func planCard(_ slot: OpenBurnBarDaemonProviderConfiguration.CredentialSlot, provider: OpenBurnBarDaemonProviderConfiguration) -> some View {
        let effectiveStatus = slot.effectiveRoutingStatus()
        VStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(slotStatusColor(for: effectiveStatus))
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(slotStatusColor(for: effectiveStatus).opacity(0.35), lineWidth: 4)
                            .frame(width: 16, height: 16)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(slot.label)
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.medium)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if provider.preferredCredentialSlotID == slot.slotID {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill").font(.system(size: 9))
                                Text("Preferred").font(DesignSystem.Typography.tiny)
                            }
                            .fixedSize()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(DesignSystem.Colors.blaze.opacity(0.14))
                            .foregroundStyle(DesignSystem.Colors.blaze)
                            .clipShape(Capsule())
                        }

                        if !slot.isEnabled {
                            Text("Disabled")
                                .font(DesignSystem.Typography.tiny)
                                .fixedSize()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(DesignSystem.Colors.textMuted.opacity(0.12))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .clipShape(Capsule())
                        }
                    }
                    slotStatusLine(slot)
                }

                Spacer()

                slotActionRow(slot, provider: provider)
                    .fixedSize()
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    @ViewBuilder
    func slotStatusLine(_ slot: OpenBurnBarDaemonProviderConfiguration.CredentialSlot) -> some View {
        if let percent = slot.lastQuotaRemainingPercent {
            HStack(spacing: 4) {
                Text("\(Int(percent.rounded()))% remaining")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(percent > 20 ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.warning)
                if let resets = slot.lastQuotaResetsAt {
                    Text("· resets \(resets.formatted(date: .abbreviated, time: .shortened))")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
        } else if slot.status == .missingSecret {
            VStack(alignment: .leading, spacing: 2) {
                Text("Missing API key")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)
                if let message = slot.lastStatusMessage, !message.isEmpty, message != "Missing API key" {
                    Text(message)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Replace the credential to route Ollama Cloud.")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
        } else {
            Text("Quota will refresh after first use")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    @ViewBuilder
    func slotActionRow(_ slot: OpenBurnBarDaemonProviderConfiguration.CredentialSlot, provider: OpenBurnBarDaemonProviderConfiguration) -> some View {
        HStack(spacing: 4) {
            if slot.status == .missingSecret {
                slotButton("key.fill", help: "Replace missing credential", tint: DesignSystem.Colors.blaze) {
                    startCredentialRepairFlow(provider: provider, slot: slot)
                }
            }

            if provider.preferredCredentialSlotID != slot.slotID && slot.isEnabled {
                let actionID = preferredSlotActionID(providerID: provider.providerID, slotID: slot.slotID)
                slotButton(
                    preferredSlotActionIDs.contains(actionID) ? "hourglass" : "star",
                    help: "Mark preferred",
                    disabled: preferredSlotActionIDs.contains(actionID)
                ) {
                    markCredentialSlotPreferred(slot, provider: provider)
                }
            }

            slotButton(slot.isEnabled ? "pause.circle" : "play.circle",
                       help: slot.isEnabled ? "Pause" : "Resume") {
                Task {
                    await daemonManager.updateProviderCredentialSlot(
                        providerID: provider.providerID,
                        slotID: slot.slotID,
                        isEnabled: !slot.isEnabled
                    )
                }
            }

            slotButton("arrow.clockwise", help: "Refresh quota") {
                Task {
                    await daemonManager.refreshProviderCredentialSlotQuotas(
                        providerID: provider.providerID
                    )
                }
            }

            slotButton("trash", help: "Delete plan", tint: DesignSystem.Colors.error) {
                slotToDelete = SlotDeleteTarget(
                    providerID: provider.providerID,
                    slotID: slot.slotID,
                    slotLabel: slot.label
                )
            }
        }
    }

    func preferredSlotActionID(providerID: String, slotID: String) -> String {
        "\(ProviderID.normalize(providerID)):\(slotID)"
    }

    func markCredentialSlotPreferred(
        _ slot: OpenBurnBarDaemonProviderConfiguration.CredentialSlot,
        provider: OpenBurnBarDaemonProviderConfiguration
    ) {
        let actionID = preferredSlotActionID(providerID: provider.providerID, slotID: slot.slotID)
        guard !preferredSlotActionIDs.contains(actionID) else { return }

        preferredSlotActionIDs.insert(actionID)
        externalAccountActionMessage = "Switching \(provider.displayName) to drain \(slot.label)..."

        Task {
            do {
                try await daemonManager.setPreferredProviderCredentialSlotOrThrow(
                    providerID: provider.providerID,
                    slotID: slot.slotID
                )

                guard daemonManager.providerConfigurations.first(where: {
                    ProviderID.normalize($0.providerID) == ProviderID.normalize(provider.providerID)
                })?.preferredCredentialSlotID == slot.slotID else {
                    throw ProviderPlanWizardError.message(
                        "The daemon accepted the request, but \(provider.displayName) still reports a different preferred account. Refresh Accounts and try again."
                    )
                }

                await refreshGatewayAdvertisementState()

                await MainActor.run {
                    preferredSlotActionIDs.remove(actionID)
                    externalAccountActionMessage = "\(provider.displayName) now drains \(slot.label) first."
                }
            } catch {
                await MainActor.run {
                    preferredSlotActionIDs.remove(actionID)
                    externalAccountActionMessage = "Failed to switch \(provider.displayName) to \(slot.label): \(error.localizedDescription)"
                }
            }
        }
    }
}
