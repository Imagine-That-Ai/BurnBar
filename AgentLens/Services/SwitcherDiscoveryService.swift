import SwiftUI
import OpenBurnBarCore

// MARK: - Discovery Models

/// The source of a discovered identity.
enum DiscoverySource: Equatable {
    case chromeProfile(folderKey: String, email: String?, gaiaName: String?, serviceIdentities: [BrowserServiceIdentity])
    case safari
    case codex(executablePath: String, hasAPIKey: Bool, lastRefresh: Date?, accountDescription: String?, configDirectory: String?)
    case claudeCode(executablePath: String, isAuthenticated: Bool, accountDescription: String?, configDirectory: String?)
    case opencode(executablePath: String?)
}

/// Authentication state of a discovered identity.
enum IdentityAuthState: Equatable {
    case authenticated
    case apiKeyPresent
    case notAuthenticated
    case notInstalled
}

struct IdentityQuotaSummary: Equatable {
    let fiveHourRemaining: String?
    let weeklyRemaining: String?
}

/// A discovered identity that can be one-click added as a profile.
struct DiscoveredIdentity: Identifiable, Equatable {
    let id: String
    let source: DiscoverySource
    let displayTitle: String
    let subtitle: String
    let quotaSummary: IdentityQuotaSummary?
    let authState: IdentityAuthState
    var isAlreadyAdded: Bool
    var isAdded: Bool = false
    var isVerifying: Bool = false
    var isVerified: Bool = false
    var verificationFailed: Bool = false
}

// MARK: - Switcher Discovery Service

/// Centralized auto-discovery engine for the switcher onboarding wizard.
/// Scans Chrome profiles, Safari, CLI tools, and cross-references existing profiles.
@MainActor
final class SwitcherDiscoveryService: ObservableObject {
    @Published var discoveredIdentities: [DiscoveredIdentity] = []
    @Published var isScanning: Bool = false
    @Published var scanProgress: [String] = []
    @Published var scanErrors: [String] = []

    func scan(dataStore: DataStore) async {
        isScanning = true
        discoveredIdentities = []
        scanProgress = []
        scanErrors = []

        // Fetch existing profiles for duplicate detection
        let existingProfiles: [SwitcherProfileRecord]
        do {
            existingProfiles = try dataStore.switcherStore.fetchAllProfiles()
        } catch {
            scanErrors.append("Failed to load existing profiles: \(error.localizedDescription)")
            existingProfiles = []
        }

        // Scan Chrome profiles
        scanProgress.append("Scanning Chrome profiles...")
        let chromeProfiles = ChromeProfileDiscovery.discoverProfiles()
        if ChromeProfileDiscovery.isChromeInstalled() && chromeProfiles.isEmpty {
            scanProgress.append("Chrome installed — no signed-in profiles found")
        } else if !chromeProfiles.isEmpty {
            scanProgress.append("Chrome — \(chromeProfiles.count) profile(s) found")
        }

        for profile in chromeProfiles {
            let isDuplicate = existingProfiles.contains { existing in
                existing.targetKind == .browser
                && existing.browserType == .chrome
                && existing.browserMetadata?.profileIdentifier == profile.folderKey
            }

            let identity = DiscoveredIdentity(
                id: "chrome.\(profile.folderKey)",
                source: .chromeProfile(
                    folderKey: profile.folderKey,
                    email: profile.email,
                    gaiaName: profile.displayName,
                    serviceIdentities: profile.serviceIdentities
                ),
                displayTitle: profile.displayName,
                subtitle: "Chrome profile: \(profile.folderKey)",
                quotaSummary: nil,
                authState: profile.email != nil ? .authenticated : .notAuthenticated,
                isAlreadyAdded: isDuplicate
            )
            discoveredIdentities.append(identity)
        }

        // Scan Safari
        scanProgress.append("Scanning Safari...")
        #if canImport(AppKit)
        let safariInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") != nil
        #else
        let safariInstalled = FileManager.default.fileExists(atPath: "/Applications/Safari.app")
        #endif

        if safariInstalled {
            scanProgress.append("Safari — installed")
            let isDuplicate = existingProfiles.contains { $0.targetKind == .browser && $0.browserType == .safari }
            discoveredIdentities.append(DiscoveredIdentity(
                id: "safari",
                source: .safari,
                displayTitle: "Safari",
                subtitle: "System default browser",
                quotaSummary: nil,
                authState: .notAuthenticated,
                isAlreadyAdded: isDuplicate
            ))
        }

        // Scan CLI tools
        scanProgress.append("Scanning CLI tools...")
        let cliAuthInfos = CLIAuthDiscovery.discoverAuthStates()
        let quotaSummaries = await loadCLIQuotaSummaries(for: cliAuthInfos, dataStore: dataStore)

        for cliInfo in cliAuthInfos {
            let source: DiscoverySource
            switch cliInfo.cliType {
            case .codex:
                source = .codex(
                    executablePath: cliInfo.executablePath ?? "",
                    hasAPIKey: cliInfo.authState == .apiKeyPresent,
                    lastRefresh: nil,
                    accountDescription: cliInfo.accountDescription,
                    configDirectory: cliInfo.configDirectory
                )
            case .claude:
                source = .claudeCode(
                    executablePath: cliInfo.executablePath ?? "",
                    isAuthenticated: {
                        if case .authenticated = cliInfo.authState { return true }
                        return false
                    }(),
                    accountDescription: cliInfo.accountDescription,
                    configDirectory: cliInfo.configDirectory
                )
            case .opencode:
                source = .opencode(executablePath: cliInfo.executablePath)
            }

            guard cliInfo.isInstalled else {
                discoveredIdentities.append(DiscoveredIdentity(
                    id: "cli.\(cliInfo.cliType.rawValue)",
                    source: source,
                    displayTitle: cliInfo.cliType.displayName,
                    subtitle: "Not installed",
                    quotaSummary: nil,
                    authState: .notInstalled,
                    isAlreadyAdded: false
                ))
                continue
            }

            let isDuplicate = existingProfiles.contains { $0.cliType == cliInfo.cliType }
            let identityAuthState: IdentityAuthState

            switch cliInfo.authState {
            case .authenticated:
                identityAuthState = .authenticated
                scanProgress.append("\(cliInfo.cliType.displayName) — authenticated")
            case .apiKeyPresent:
                identityAuthState = .apiKeyPresent
                scanProgress.append("\(cliInfo.cliType.displayName) — API key detected")
            case .notAuthenticated:
                identityAuthState = .notAuthenticated
                scanProgress.append("\(cliInfo.cliType.displayName) — not authenticated")
            case .notInstalled:
                identityAuthState = .notInstalled
            }

            discoveredIdentities.append(DiscoveredIdentity(
                id: "cli.\(cliInfo.cliType.rawValue)",
                source: source,
                displayTitle: cliInfo.cliType.displayName,
                subtitle: cliInfo.executablePath ?? "Installed",
                quotaSummary: quotaSummaries[cliInfo.cliType],
                authState: identityAuthState,
                isAlreadyAdded: isDuplicate
            ))
        }

        isScanning = false
        scanProgress.append("Scan complete")
    }

    // MARK: - Add Identity

    /// Auto-creates a profile from a discovered identity.
    @discardableResult
    func addIdentity(_ identity: DiscoveredIdentity, dataStore: DataStore) -> SwitcherProfileRecord? {
        var record: SwitcherProfileRecord?

        switch identity.source {
        case .chromeProfile(let folderKey, let email, let gaiaName, let serviceIdentities):
            guard ChromeProfileDiscovery.validateProfileFolder(folderKey) else { return nil }
            record = SwitcherProfileRecord(
                targetKind: .browser,
                browserType: .chrome,
                browserMetadata: SwitcherBrowserProfileMetadata(
                    profileIdentifier: folderKey,
                    displayLabel: gaiaName ?? email,
                    accountEmail: email,
                    providerIdentifier: "google",
                    serviceIdentities: serviceIdentities
                ),
                sortKey: 0
            )

        case .safari:
            record = SwitcherProfileRecord(
                targetKind: .browser,
                browserType: .safari,
                browserMetadata: SwitcherBrowserProfileMetadata(
                    profileIdentifier: "Default",
                    displayLabel: "Safari",
                    providerIdentifier: "apple"
                ),
                sortKey: 0
            )

        case .codex(_, _, _, let accountDescription, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .codex,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Codex",
                    configDirectory: configDirectory,
                    accountDescription: accountDescription
                ),
                sortKey: 0
            )

        case .claudeCode(_, _, let accountDescription, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .claude,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Claude Code",
                    configDirectory: configDirectory,
                    accountDescription: accountDescription
                ),
                sortKey: 0
            )

        case .opencode:
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .opencode,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "OpenCode"
                ),
                sortKey: 0
            )
        }

        guard let created = record else { return nil }

        do {
            let saved = try dataStore.switcherStore.create(created)

            // First profile auto-set as active
            let existingCount = (try? dataStore.switcherStore.fetchAllProfiles().count) ?? 0
            if existingCount <= 1 {
                try? dataStore.switcherStore.setActiveProfile(saved.id)
            }

            // Update identity state
            if let index = discoveredIdentities.firstIndex(where: { $0.id == identity.id }) {
                discoveredIdentities[index].isAdded = true
            }

            return saved
        } catch {
            return nil
        }
    }

    // MARK: - Add Different Account (Browser)

    /// Signs into a different Google account via OAuth and creates a Chrome profile for it.
    @discardableResult
    func addDifferentGoogleAccount(dataStore: DataStore) async -> SwitcherProfileRecord? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }

        do {
            try await AccountManager.shared.signInWithGoogle(presentingWindow: window)
        } catch {
            scanErrors.append("Google Sign-In failed: \(error.localizedDescription)")
            return nil
        }

        // Capture the signed-in account info
        let email = AccountManager.shared.userEmail
            ?? AccountManager.shared.currentUser?.email
            ?? AccountManager.shared.lastOAuthEmail
        let displayName = AccountManager.shared.userDisplayName
            ?? AccountManager.shared.currentUser?.displayName
            ?? AccountManager.shared.lastOAuthDisplayName

        guard let email else {
            scanErrors.append("Could not retrieve email from Google Sign-In")
            return nil
        }

        // Generate a synthetic folder key for this new Chrome profile
        // The profile doesn't exist in Chrome yet, but we create a reference
        // that the browser launch service can use to open Chrome with the right account
        let folderKey = "Profile_Switcher_\(email.replacingOccurrences(of: "@", with: "_at_").prefix(30))"

        let record = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(
                profileIdentifier: folderKey,
                displayLabel: displayName ?? email,
                accountEmail: email,
                providerIdentifier: "google",
                serviceIdentities: []
            ),
            sortKey: 0
        )

        do {
            let saved = try dataStore.switcherStore.create(record)

            if let token = AccountManager.shared.lastOAuthToken, !token.isEmpty {
                let authStore = SwitcherAuthStore()
                try? authStore.storeOAuthToken(token, forProfileID: saved.id, provider: "google")
            }

            // First profile auto-set as active
            let existingCount = (try? dataStore.switcherStore.fetchAllProfiles().count) ?? 0
            if existingCount <= 1 {
                try? dataStore.switcherStore.setActiveProfile(saved.id)
            }

            // Add as a new discovered identity so UI shows it
            let newIdentity = DiscoveredIdentity(
                id: "chrome.different.\(saved.id)",
                source: .chromeProfile(
                    folderKey: folderKey,
                    email: email,
                    gaiaName: displayName,
                    serviceIdentities: []
                ),
                displayTitle: displayName ?? email,
                subtitle: email,
                quotaSummary: nil,
                authState: .authenticated,
                isAlreadyAdded: false,
                isAdded: true,
                isVerifying: false,
                isVerified: true,
                verificationFailed: false
            )
            discoveredIdentities.append(newIdentity)

            return saved
        } catch {
            scanErrors.append("Failed to save profile: \(error.localizedDescription)")
            return nil
        }
    }

    /// Signs into a different Apple account via Sign in with Apple and creates a profile for it.
    @discardableResult
    func addDifferentAppleAccount(dataStore: DataStore) async -> SwitcherProfileRecord? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }

        do {
            try await AccountManager.shared.signInWithApple(presentingWindow: window)
        } catch {
            scanErrors.append("Apple Sign-In failed: \(error.localizedDescription)")
            return nil
        }

        let email = AccountManager.shared.userEmail
            ?? AccountManager.shared.currentUser?.email
            ?? AccountManager.shared.lastOAuthEmail
        let displayName = AccountManager.shared.userDisplayName
            ?? AccountManager.shared.currentUser?.displayName
            ?? AccountManager.shared.lastOAuthDisplayName

        let record = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .safari,
            browserMetadata: SwitcherBrowserProfileMetadata(
                profileIdentifier: "Default_\(displayName ?? "Alt")",
                displayLabel: displayName ?? email ?? "Safari (Alt)",
                accountEmail: email,
                providerIdentifier: "apple",
                serviceIdentities: []
            ),
            sortKey: 0
        )

        do {
            let saved = try dataStore.switcherStore.create(record)

            if let token = AccountManager.shared.lastOAuthToken, !token.isEmpty {
                let authStore = SwitcherAuthStore()
                try? authStore.storeOAuthToken(token, forProfileID: saved.id, provider: "apple")
            }

            let existingCount = (try? dataStore.switcherStore.fetchAllProfiles().count) ?? 0
            if existingCount <= 1 {
                try? dataStore.switcherStore.setActiveProfile(saved.id)
            }

            let newIdentity = DiscoveredIdentity(
                id: "safari.different.\(saved.id)",
                source: .safari,
                displayTitle: displayName ?? email ?? "Safari (Alt)",
                subtitle: email ?? "Apple ID",
                quotaSummary: nil,
                authState: .authenticated,
                isAlreadyAdded: false,
                isAdded: true,
                isVerifying: false,
                isVerified: true,
                verificationFailed: false
            )
            discoveredIdentities.append(newIdentity)

            return saved
        } catch {
            scanErrors.append("Failed to save profile: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func refreshBrowserProfileAuthentication(
        _ profile: SwitcherProfileRecord,
        dataStore: DataStore
    ) async -> SwitcherProfileRecord? {
        guard profile.targetKind == .browser, let browserType = profile.browserType else { return nil }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }

        let providerIdentifier = resolvedBrowserProviderIdentifier(
            profile.browserMetadata?.providerIdentifier,
            browserType: browserType
        )

        do {
            switch providerIdentifier {
            case "apple":
                try await AccountManager.shared.signInWithApple(presentingWindow: window)
            default:
                try await AccountManager.shared.signInWithGoogle(presentingWindow: window)
            }
        } catch {
            scanErrors.append("\(providerIdentifier.capitalized) Sign-In failed: \(error.localizedDescription)")
            return nil
        }

        let email = AccountManager.shared.userEmail
            ?? AccountManager.shared.currentUser?.email
            ?? AccountManager.shared.lastOAuthEmail
        let displayName = AccountManager.shared.userDisplayName
            ?? AccountManager.shared.currentUser?.displayName
            ?? AccountManager.shared.lastOAuthDisplayName

        let updated = SwitcherProfileRecord(
            id: profile.id,
            targetKind: .browser,
            browserType: browserType,
            browserMetadata: SwitcherBrowserProfileMetadata(
                profileIdentifier: profile.browserMetadata?.profileIdentifier ?? defaultBrowserProfileIdentifier(for: browserType),
                displayLabel: displayName ?? email ?? profile.browserMetadata?.displayLabel,
                accountEmail: email ?? profile.browserMetadata?.accountEmail,
                providerIdentifier: providerIdentifier,
                serviceIdentities: profile.browserMetadata?.serviceIdentities ?? [],
                isDisabled: profile.browserMetadata?.isDisabled ?? false
            ),
            sortKey: profile.sortKey,
            createdAt: profile.createdAt
        )

        do {
            let saved = try dataStore.switcherStore.update(updated)
            if let token = AccountManager.shared.lastOAuthToken, !token.isEmpty {
                let authStore = SwitcherAuthStore()
                try? authStore.storeOAuthToken(token, forProfileID: saved.id, provider: providerIdentifier)
            }
            return saved
        } catch {
            scanErrors.append("Failed to update profile: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Add Different API Key (CLI)

    /// Launches the CLI login flow and saves the connected account as another profile.
    @discardableResult
    func addDifferentCLIAccount(
        cliType: SwitcherCLIProfileType,
        dataStore: DataStore
    ) async -> SwitcherProfileRecord? {
        let placeholder = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(displayLabel: cliType.displayName),
            sortKey: 0
        )

        let coordinator = SwitcherCLIAuthCoordinator()
        let updatedProfile: SwitcherProfileRecord

        switch await coordinator.reconnect(profile: placeholder) {
        case .readyToPersist(let profile), .requiresConfirmation(let profile, _, _):
            updatedProfile = profile
        case .cancelled:
            return nil
        case .failed(let message):
            scanErrors.append(message)
            return nil
        }

        guard let metadata = updatedProfile.cliMetadata else { return nil }

        let record = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: metadata.workingDirectory,
                additionalArgs: metadata.additionalArgs,
                envKeysToPass: metadata.envKeysToPass,
                displayLabel: metadata.accountDescription ?? metadata.displayLabel ?? cliType.displayName,
                configDirectory: metadata.configDirectory,
                accountDescription: metadata.accountDescription,
                lastQuotaExhaustedAt: metadata.lastQuotaExhaustedAt,
                exhaustedUntil: metadata.exhaustedUntil,
                lastQuotaExhaustionDetail: metadata.lastQuotaExhaustionDetail,
                isDisabled: metadata.isDisabled
            ),
            sortKey: 0
        )

        do {
            let saved = try dataStore.switcherStore.create(record)
            let existingCount = (try? dataStore.switcherStore.fetchAllProfiles().count) ?? 0
            if existingCount <= 1 {
                try? dataStore.switcherStore.setActiveProfile(saved.id)
            }

            await scan(dataStore: dataStore)
            if let index = discoveredIdentities.firstIndex(where: { identity in
                switch identity.source {
                case .codex(_, _, _, let accountDescription, let configDirectory):
                    return cliType == .codex
                        && accountDescription == saved.cliMetadata?.accountDescription
                        && configDirectory == saved.cliMetadata?.configDirectory
                case .claudeCode(_, _, let accountDescription, let configDirectory):
                    return cliType == .claude
                        && accountDescription == saved.cliMetadata?.accountDescription
                        && configDirectory == saved.cliMetadata?.configDirectory
                case .opencode:
                    return cliType == .opencode
                default:
                    return false
                }
            }) {
                discoveredIdentities[index].isAdded = true
                discoveredIdentities[index].isVerified = true
                discoveredIdentities[index].verificationFailed = false
            }

            return saved
        } catch {
            scanErrors.append("Failed to save \(cliType.displayName) account: \(error.localizedDescription)")
            return nil
        }
    }

    /// Adds a CLI profile with a manually entered API key (for a different account than discovered).
    @discardableResult
    func addCLIWithAPIKey(
        cliType: SwitcherCLIProfileType,
        apiKey: String,
        label: String?,
        dataStore: DataStore
    ) -> SwitcherProfileRecord? {
        let displayLabel = label ?? cliType.displayName

        let record = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: nil,
                displayLabel: displayLabel,
                accountDescription: label
            ),
            sortKey: 0
        )

        do {
            let saved = try dataStore.switcherStore.create(record)

            // Store the API key in keychain
            let authStore = SwitcherAuthStore()
            try authStore.storeAPIKey(apiKey, forProfileID: saved.id, cliType: cliType)

            let existingCount = (try? dataStore.switcherStore.fetchAllProfiles().count) ?? 0
            if existingCount <= 1 {
                try? dataStore.switcherStore.setActiveProfile(saved.id)
            }

            // Add as a new discovered identity so UI shows it
            let newIdentity = DiscoveredIdentity(
                id: "cli.apikey.\(saved.id)",
                source: cliTypeDiscoverySource(cliType, apiKey: apiKey),
                displayTitle: displayLabel,
                subtitle: "API key added",
                quotaSummary: nil,
                authState: .apiKeyPresent,
                isAlreadyAdded: false,
                isAdded: true,
                isVerifying: false,
                isVerified: true,
                verificationFailed: false
            )
            discoveredIdentities.append(newIdentity)

            return saved
        } catch {
            scanErrors.append("Failed to save CLI profile: \(error.localizedDescription)")
            return nil
        }
    }

    private func cliTypeDiscoverySource(_ cliType: SwitcherCLIProfileType, apiKey: String) -> DiscoverySource {
        switch cliType {
        case .codex:
            return .codex(executablePath: CLILaunchAdapter.executablePath(for: .codex) ?? "", hasAPIKey: true, lastRefresh: nil, accountDescription: nil, configDirectory: nil)
        case .claude:
            return .claudeCode(executablePath: CLILaunchAdapter.executablePath(for: .claude) ?? "", isAuthenticated: false, accountDescription: nil, configDirectory: nil)
        case .opencode:
            return .opencode(executablePath: CLILaunchAdapter.executablePath(for: .opencode))
        }
    }

    // MARK: - Verify Identity

    /// Quick verification after adding a profile.
    func verifyIdentity(_ identity: DiscoveredIdentity) async -> Bool {
        if let index = discoveredIdentities.firstIndex(where: { $0.id == identity.id }) {
            discoveredIdentities[index].isVerifying = true
        }

        var success = false

        switch identity.source {
        case .chromeProfile(let folderKey, _, _, _):
            success = ChromeProfileDiscovery.validateProfileFolder(folderKey)

        case .safari:
            #if canImport(AppKit)
            success = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") != nil
            #else
            success = true
            #endif

        case .codex, .claudeCode, .opencode:
            // Quick CLI version check
            let cliType: SwitcherCLIProfileType
            switch identity.source {
            case .codex: cliType = .codex
            case .claudeCode: cliType = .claude
            case .opencode: cliType = .opencode
            default: cliType = .codex
            }
            let execPath = CLILaunchAdapter.executablePath(for: cliType)
            success = execPath != nil
        }

        if let index = discoveredIdentities.firstIndex(where: { $0.id == identity.id }) {
            discoveredIdentities[index].isVerifying = false
            discoveredIdentities[index].isVerified = success
            discoveredIdentities[index].verificationFailed = !success
        }

        return success
    }

    private func loadCLIQuotaSummaries(
        for cliAuthInfos: [CLIAuthInfo],
        dataStore: DataStore
    ) async -> [SwitcherCLIProfileType: IdentityQuotaSummary] {
        let quotaService = ProviderQuotaService.shared
        var summaries: [SwitcherCLIProfileType: IdentityQuotaSummary] = [:]

        for cliInfo in cliAuthInfos where cliInfo.isInstalled {
            guard let provider = quotaProvider(for: cliInfo.cliType) else { continue }

            let existingSnapshot = quotaService.snapshot(for: provider)
            if shouldRefreshQuotaSnapshot(existingSnapshot) {
                scanProgress.append("Refreshing \(cliInfo.cliType.displayName) quota…")
                await quotaService.refresh(provider: provider, dataStore: dataStore)
            }

            guard let snapshot = quotaService.snapshot(for: provider),
                  let summary = quotaSummary(from: snapshot) else {
                continue
            }

            summaries[cliInfo.cliType] = summary

            let fiveHour = summary.fiveHourRemaining ?? "--"
            let weekly = summary.weeklyRemaining ?? "--"
            scanProgress.append("\(cliInfo.cliType.displayName) quota — 5h \(fiveHour), weekly \(weekly)")
        }

        return summaries
    }

    private func shouldRefreshQuotaSnapshot(_ snapshot: ProviderQuotaSnapshot?) -> Bool {
        guard let snapshot else { return true }
        if snapshot.buckets.isEmpty { return true }
        return snapshot.isStale()
    }

    private func quotaProvider(for cliType: SwitcherCLIProfileType) -> AgentProvider? {
        switch cliType {
        case .codex:
            return .codex
        case .claude:
            return .claudeCode
        case .opencode:
            return nil
        }
    }

    private func quotaSummary(from snapshot: ProviderQuotaSnapshot) -> IdentityQuotaSummary? {
        let fiveHourRemaining = snapshot.hourlyBucket?.remainingText
        let weeklyRemaining = snapshot.weeklyBucket?.remainingText

        guard fiveHourRemaining != nil || weeklyRemaining != nil else {
            return nil
        }

        return IdentityQuotaSummary(
            fiveHourRemaining: fiveHourRemaining,
            weeklyRemaining: weeklyRemaining
        )
    }

    private func resolvedBrowserProviderIdentifier(
        _ providerIdentifier: String?,
        browserType: SwitcherBrowserProfileType
    ) -> String {
        if let providerIdentifier {
            let normalized = providerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "google" || normalized == "apple" {
                return normalized
            }
        }

        switch browserType {
        case .chrome:
            return "google"
        case .safari:
            return "apple"
        }
    }

    private func defaultBrowserProfileIdentifier(for browserType: SwitcherBrowserProfileType) -> String {
        switch browserType {
        case .chrome, .safari:
            return "Default"
        }
    }
    // MARK: - Cap Helpers

    /// Returns the count of identities added during this session for a given provider kind.
    func sessionAddedCount(for kind: OnboardingProvider.Kind) -> Int {
        discoveredIdentities.filter { $0.isAdded && identityMatchesKind($0, kind) }.count
    }

    /// Returns the count of identities that were already added before this session for a given provider kind.
    func preExistingCount(for kind: OnboardingProvider.Kind) -> Int {
        discoveredIdentities.filter { $0.isAlreadyAdded && !$0.isAdded && identityMatchesKind($0, kind) }.count
    }

    /// Checks whether adding another account for the given provider kind would exceed the cap.
    func canAddAnother(for kind: OnboardingProvider.Kind, cap: Int = SwitcherOnboardingLimits.providerCap) -> Bool {
        (sessionAddedCount(for: kind) + preExistingCount(for: kind)) < cap
    }

    private func identityMatchesKind(_ identity: DiscoveredIdentity, _ kind: OnboardingProvider.Kind) -> Bool {
        switch (identity.source, kind) {
        case (.chromeProfile, .chrome): return true
        case (.safari, .safari): return true
        case (.codex, .codexCLI): return true
        case (.codex, .openAI): return true
        case (.claudeCode, .claudeCLI): return true
        case (.claudeCode, .claude): return true
        case (.opencode, .openCodeCLI): return true
        default: return false
        }
    }
}

// MARK: - Discovery Source Helpers

extension DiscoverySource {
    var cliType: SwitcherCLIProfileType? {
        switch self {
        case .codex: return .codex
        case .claudeCode: return .claude
        case .opencode: return .opencode
        default: return nil
        }
    }
}
