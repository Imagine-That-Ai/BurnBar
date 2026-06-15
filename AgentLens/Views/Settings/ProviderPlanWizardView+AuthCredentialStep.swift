import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Plan Strategy

// Auth-method and credential steps.
// Extracted from ProviderPlanWizardView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension ProviderPlanWizardView {

    @ViewBuilder
    func miniChip(_ label: String, system: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: system).font(.system(size: 8, weight: .semibold))
            Text(label).font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tint.opacity(0.14))
        .foregroundStyle(tint)
        .clipShape(Capsule())
    }

    @ViewBuilder
    var authMethodStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            if let provider = selectedProvider {
                providerStripHeader(provider)
            }

            if let descriptor = selectedDescriptor {
                Text("Choose how you'll authenticate")
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text(descriptor.summary)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.bottom, DesignSystem.Spacing.xs)

                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(descriptor.methods) { method in
                        authMethodCard(method)
                    }
                }

                if let proxy = descriptor.proxyHint {
                    miniHintCard(symbol: "arrow.triangle.swap", text: proxy)
                }
                if let quota = descriptor.quotaHint {
                    miniHintCard(symbol: "gauge.with.needle", text: quota)
                }
            }
        }
    }

    @ViewBuilder
    func providerStripHeader(_ provider: OpenBurnBarDaemonProviderConfiguration) -> some View {
        let primary = ProviderBrand.colorForProviderID(provider.providerID)
        HStack(spacing: DesignSystem.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: [primary.opacity(0.4), primary.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 32, height: 32)
                CatalogProviderLogoView(brand: provider.brand, size: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(descriptor(for: provider.providerID).displayName)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer()
            Button {
                withAnimation { selectedProviderID = nil }
                navigateToStep(.provider)
            } label: {
                Text("Change")
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.blaze)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(DesignSystem.Colors.blaze.opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, DesignSystem.Spacing.xs)
    }

    @ViewBuilder
    func authMethodCard(_ method: BurnBarProviderAuthMethod) -> some View {
        let isSelected = selectedAuthMethodID == method.id
        let primary: Color = {
            if let id = selectedProviderID {
                return ProviderBrand.colorForProviderID(id)
            }
            return DesignSystem.Colors.blaze
        }()

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedAuthMethodID = method.id
                apiKeyInput = ""
                credentialStorageOverride = nil
                credentialStorageOverrideVisibleToken = nil
                quotaProbeResult = nil
                quotaProbeError = nil
                externalAuthInfo = nil
                externalAuthMessage = nil
                externalAccountActionMessage = nil
            }
        } label: {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: isSelected
                                ? [primary, primary.opacity(0.6)]
                                : [DesignSystem.Colors.surfaceElevated, DesignSystem.Colors.surfaceElevated],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 44, height: 44)
                    Image(systemName: method.kind.symbolName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : DesignSystem.Colors.textSecondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(method.displayName)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(method.summary)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        if method.unlocksProxyRouting {
                            miniChip("Unlocks routing", system: "arrow.triangle.swap", tint: DesignSystem.Colors.blaze)
                        }
                        if method.unlocksQuotaRefresh {
                            miniChip("Live quota", system: "gauge.with.needle", tint: DesignSystem.Colors.success)
                        }
                        if !method.unlocksProxyRouting && !method.unlocksQuotaRefresh {
                            miniChip("Tracking only", system: "chart.bar.doc.horizontal", tint: DesignSystem.Colors.textMuted)
                        }
                    }
                }
                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(primary)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(isSelected ? primary.opacity(0.08) : DesignSystem.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(
                        isSelected ? primary : DesignSystem.Colors.border,
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
    }

    @ViewBuilder
    func miniHintCard(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .padding(.top, 1)
            Text(text)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    @ViewBuilder
    var credentialEntryStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            if let provider = selectedProvider {
                providerStripHeader(provider)
            }

            if let method = selectedAuthMethod {
                methodHeroCard(method)
                if method.usesExternalLogin {
                    externalLoginPanel(method)
                } else {
                    planLabelField
                    credentialField(method)
                    if method.isClaudeOAuthBearer, let externalAccountActionMessage {
                        miniHintCard(
                            symbol: externalAccountActionMessage.localizedCaseInsensitiveContains("failed")
                                ? "exclamationmark.triangle.fill"
                                : "person.crop.circle.badge.checkmark",
                            text: externalAccountActionMessage
                        )
                    }
                    liveValidationView(method)
                    liveQuotaProbeView()
                }
            }
        }
        .task(id: selectedAuthMethodID) {
            refreshExternalAuthStateIfNeeded()
        }
    }

    @ViewBuilder
    func methodHeroCard(_ method: BurnBarProviderAuthMethod) -> some View {
        let primary: Color = selectedProviderID
            .map { ProviderBrand.colorForProviderID($0) } ?? DesignSystem.Colors.blaze

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [primary, primary.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 32, height: 32)
                    Image(systemName: method.kind.symbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(method.displayName)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                if let descriptor = selectedDescriptor, descriptor.methods.count > 1 {
                    Button {
                        navigateToStep(.auth)
                    } label: {
                        Text("Change method")
                            .font(DesignSystem.Typography.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.blaze)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(method.helperText)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if method.isClaudeOAuthBearer {
                HStack(spacing: 8) {
                    Button {
                        importClaudeCodeOAuthBearer()
                    } label: {
                        HStack(spacing: 4) {
                            if isImportingCredential {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            Text(isImportingCredential ? "Checking Claude Code" : "Use current Claude login")
                                .font(DesignSystem.Typography.tiny)
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(primary.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isImportingCredential)

                    Button {
                        startDifferentClaudeOAuthLogin(for: method)
                    } label: {
                        HStack(spacing: 4) {
                            if isAddingExternalAccount {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "person.crop.circle.badge.plus")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            Text(isAddingExternalAccount ? "Opening login" : "Sign in different account")
                                .font(DesignSystem.Typography.tiny)
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(DesignSystem.Colors.surfaceElevated)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isAddingExternalAccount)
                }
            } else if let url = method.dashboardURL.flatMap(URL.init(string:)) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10, weight: .semibold))
                        Text(method.dashboardLabel ?? "Open dashboard")
                            .font(DesignSystem.Typography.tiny)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(primary.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
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
    var planLabelField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Plan label")
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            TextField("Personal, Work, Team A…", text: $planLabel)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm + 2)
                .background(DesignSystem.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        }
    }

    @ViewBuilder
    func externalLoginPanel(_ method: BurnBarProviderAuthMethod) -> some View {
        let cliType = externalCLIType(for: method)
        let authInfo = externalAuthInfo
        let statusColor = authInfo?.wizardStateColor ?? DesignSystem.Colors.textMuted

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(statusColor.opacity(0.14))
                        .frame(width: 42, height: 42)
                    Image(systemName: authInfo?.isWizardConnected == true ? "checkmark.seal.fill" : "person.crop.circle.badge.plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(cliType?.displayName ?? method.displayName)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(externalAuthMessage ?? "Checking local sign-in…")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let accountDescription = authInfo?.accountDescription, !accountDescription.isEmpty {
                        Text(accountDescription)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }

                    if let configDirectory = authInfo?.configDirectory {
                        Text(configDirectory)
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .textSelection(.enabled)
                    }
                }

                Spacer()
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    refreshExternalAuthStateIfNeeded()
                    refreshDashboardExternalAuthStates()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button {
                    openExternalLogin(for: method)
                } label: {
                    if isOpeningExternalLogin {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Opening…")
                        }
                    } else {
                        Label(authInfo?.isWizardConnected == true ? "Reconnect" : "Open Login", systemImage: "terminal")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.blaze)
                .disabled(cliType == nil || isOpeningExternalLogin)

                Button {
                    Task { await addExternalOAuthAccount(for: method) }
                } label: {
                    if isAddingExternalAccount {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Adding…")
                        }
                    } else {
                        Label(addExternalAccountLabel(for: cliType), systemImage: "person.2.badge.plus")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(cliType == nil || isAddingExternalAccount)
            }

            if let externalAccountActionMessage {
                miniHintCard(
                    symbol: externalAccountActionMessage.localizedCaseInsensitiveContains("failed")
                        ? "exclamationmark.triangle.fill"
                        : "info.circle.fill",
                    text: externalAccountActionMessage
                )
            }

            if authInfo?.isWizardConnected == true {
                miniHintCard(
                    symbol: "checkmark.circle.fill",
                    text: "\(cliType?.displayName ?? "Local CLI") is signed in and now appears in Accounts. Use Add OAuth Account to create an isolated additional login."
                )
            } else {
                miniHintCard(
                    symbol: "info.circle.fill",
                    text: "Use Open Login for the default local CLI login, or Add OAuth Account to create an isolated additional profile."
                )
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(statusColor.opacity(0.45), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    @ViewBuilder
    func credentialField(_ method: BurnBarProviderAuthMethod) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(method.kind == .sessionToken ? "Session token" : (method.kind == .cookie ? "Cookie payload" : "Credential"))
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                Button {
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        apiKeyInput = pasted
                        credentialStorageOverride = nil
                        credentialStorageOverrideVisibleToken = nil
                        credentialImportMessage = nil
                        scheduleQuotaProbe()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Paste")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(DesignSystem.Colors.surfaceElevated)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                if method.isClaudeOAuthBearer {
                    Button {
                        importClaudeCodeOAuthBearer()
                    } label: {
                        HStack(spacing: 3) {
                            if isImportingCredential {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            Text(isImportingCredential ? "Checking" : "Use current Claude")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(DesignSystem.Colors.blaze)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(DesignSystem.Colors.blaze.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isImportingCredential)

                    Button {
                        startDifferentClaudeOAuthLogin(for: method)
                    } label: {
                        HStack(spacing: 3) {
                            if isAddingExternalAccount {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "person.crop.circle.badge.plus")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            Text(isAddingExternalAccount ? "Opening" : "Different account")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(DesignSystem.Colors.surfaceElevated)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isAddingExternalAccount)
                }
                if method.isOpenCodeAuthJSON {
                    Button {
                        importOpenCodeAuthJSON()
                    } label: {
                        HStack(spacing: 3) {
                            if isImportingCredential {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            Text(isImportingCredential ? "Checking" : "Use current OpenCode")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(DesignSystem.Colors.blaze)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(DesignSystem.Colors.blaze.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isImportingCredential)
                }
                Button {
                    withAnimation(.snappy) { showAPIKey.toggle() }
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                Group {
                    if showAPIKey {
                        TextField(method.placeholder, text: $apiKeyInput)
                            .textFieldStyle(.plain)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .onChange(of: apiKeyInput) { _, _ in scheduleQuotaProbe() }
                    } else {
                        SecureField(method.placeholder, text: $apiKeyInput)
                            .textFieldStyle(.plain)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .onChange(of: apiKeyInput) { _, _ in scheduleQuotaProbe() }
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm + 2)
            }
            .background(DesignSystem.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(
                        method.validate(apiKeyInput).isWarning ? DesignSystem.Colors.warning :
                            (method.validate(apiKeyInput).isOK ? DesignSystem.Colors.success : DesignSystem.Colors.border),
                        lineWidth: method.validate(apiKeyInput).message == nil ? 0.5 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .animation(.snappy, value: apiKeyInput)

            if selectedProviderID == "mimo", method.id == "mimo-token-plan" {
                mimoTokenPlanConnectFields
            }

            if let credentialImportMessage {
                miniHintCard(
                    symbol: credentialImportMessage.localizedCaseInsensitiveContains("imported")
                        ? "checkmark.circle.fill"
                        : "info.circle.fill",
                    text: credentialImportMessage
                )
                .padding(.top, DesignSystem.Spacing.xs)

                if method.isClaudeOAuthBearer,
                   !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   canProceedFromCredential {
                    Button {
                        navigateForward()
                    } label: {
                        Label("Continue to save", systemImage: "arrow.right.circle.fill")
                            .font(DesignSystem.Typography.tiny)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.blaze)
                    .padding(.top, DesignSystem.Spacing.xs)
                }
            }
        }
    }
}
