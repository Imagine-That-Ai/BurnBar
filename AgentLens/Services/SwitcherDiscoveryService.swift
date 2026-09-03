import AppKit
import Combine
import Foundation
import OpenBurnBarCore

// MARK: - Discovery Models

/// The source of a discovered identity.
enum DiscoverySource: Equatable {
    case chromeProfile(folderKey: String, email: String?, gaiaName: String?, serviceIdentities: [BrowserServiceIdentity])
    case safari
    case codex(executablePath: String, hasAPIKey: Bool, lastRefresh: Date?, accountDescription: String?, configDirectory: String?)
    case claudeCode(executablePath: String, isAuthenticated: Bool, accountDescription: String?, configDirectory: String?)
    case opencode(executablePath: String?)
    case droid(executablePath: String?, configDirectory: String?)
    case grok(executablePath: String?, configDirectory: String?)
    case forge(executablePath: String?, configDirectory: String?)
    case antigravity(executablePath: String?, configDirectory: String?)
    case cursorAgent(executablePath: String?, configDirectory: String?)
    case gemini(executablePath: String?, configDirectory: String?)
    case kimi(executablePath: String?, configDirectory: String?)
    case pi(executablePath: String?, configDirectory: String?)
    case junie(executablePath: String?, configDirectory: String?)
    case fx(executablePath: String?, configDirectory: String?)
    case muse(executablePath: String?, configDirectory: String?)
    case omp(executablePath: String?, configDirectory: String?)
    case primeAgent(executablePath: String?, configDirectory: String?)
    case hermes(executablePath: String?, configDirectory: String?)
    case goose(executablePath: String?, configDirectory: String?)
    case windsurf(executablePath: String?, configDirectory: String?)
    case openClaude(executablePath: String?, configDirectory: String?)
    case openClaw(executablePath: String?, configDirectory: String?)
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
    let fiveHourReset: String?
    let weeklyReset: String?

    init(
        fiveHourRemaining: String?,
        weeklyRemaining: String?,
        fiveHourReset: String? = nil,
        weeklyReset: String? = nil
    ) {
        self.fiveHourRemaining = fiveHourRemaining
        self.weeklyRemaining = weeklyRemaining
        self.fiveHourReset = fiveHourReset
        self.weeklyReset = weeklyReset
    }
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

    /// Factory for the credential store used when persisting OAuth tokens.
    /// Injectable so fault-injection tests can prove the fail-closed credential
    /// path (a profile must never be left advertising authentication it cannot
    /// back with a stored token). Defaults to the live Keychain-backed store.
    private let makeAuthStore: @Sendable () -> SwitcherAuthStore
    private let accountManagerProvider: @MainActor () -> AccountManager

    /// `nonisolated` so the service can be constructed from non-MainActor
    /// contexts (and from tests) without an actor-isolation hop. Stored
    /// properties carry their own defaults, so the seam is purely additive.
    nonisolated init(
        accountManagerProvider: @escaping @MainActor () -> AccountManager = { .shared },
        makeAuthStore: @escaping @Sendable () -> SwitcherAuthStore = { SwitcherAuthStore() }
    ) {
        self.accountManagerProvider = accountManagerProvider
        self.makeAuthStore = makeAuthStore
    }

    func scan(dataStore: DataStore) async {
        isScanning = true
        discoveredIdentities = []
        scanProgress = []
        scanErrors = []

        // Fetch existing profiles for duplicate detection
        let existingProfiles: [SwitcherProfileRecord]
        do {
            existingProfiles = try dataStore.fetchSwitcherProfiles()
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
        // Discovery is a local, user-facing setup step. Do not hold the wizard
        // open on live quota HTTP calls: a provider outage or slow endpoint
        // must never leave the screen stuck on “Scanning…”. The normal quota
        // refresh lifecycle will fill missing/stale summaries after setup.
        let quotaSummaries = loadCLIQuotaSummaries(for: cliAuthInfos)

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
            case .droid:
                source = .droid(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .grok:
                source = .grok(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .forge:
                source = .forge(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .antigravity:
                source = .antigravity(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .cursorAgent:
                source = .cursorAgent(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .gemini:
                source = .gemini(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .kimi:
                source = .kimi(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .pi:
                source = .pi(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .junie:
                source = .junie(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .fx:
                source = .fx(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .muse:
                source = .muse(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .omp:
                source = .omp(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .primeAgent:
                source = .primeAgent(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .hermes:
                source = .hermes(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .goose:
                source = .goose(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .windsurf:
                source = .windsurf(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .openClaude:
                source = .openClaude(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
            case .openClaw:
                source = .openClaw(executablePath: cliInfo.executablePath, configDirectory: cliInfo.configDirectory)
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
        case .droid(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .droid,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Droid",
                    configDirectory: configDirectory,
                    accountDescription: "Factory Droid local profile"
                ),
                sortKey: 0
            )
        case .grok(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .grok,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Grok Build",
                    configDirectory: configDirectory,
                    accountDescription: "Grok Build local profile"
                ),
                sortKey: 0
            )
        case .forge(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .forge,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Forge",
                    configDirectory: configDirectory,
                    accountDescription: "Forge local profile"
                ),
                sortKey: 0
            )
        case .antigravity(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .antigravity,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Antigravity",
                    configDirectory: configDirectory,
                    accountDescription: "Google Antigravity local profile"
                ),
                sortKey: 0
            )
        case .cursorAgent(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .cursorAgent,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Cursor Agent",
                    configDirectory: configDirectory,
                    accountDescription: "Cursor Agent local profile"
                ),
                sortKey: 0
            )
        case .gemini(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .gemini,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Gemini CLI",
                    configDirectory: configDirectory,
                    accountDescription: "Gemini CLI local profile"
                ),
                sortKey: 0
            )
        case .kimi(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .kimi,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Kimi",
                    configDirectory: configDirectory,
                    accountDescription: "Kimi local profile"
                ),
                sortKey: 0
            )
        case .pi(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .pi,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Pi",
                    configDirectory: configDirectory,
                    accountDescription: "Pi local profile"
                ),
                sortKey: 0
            )
        case .junie(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .junie,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    envKeysToPass: identity.authState == .apiKeyPresent ? ["JUNIE_API_KEY"] : [],
                    displayLabel: "Junie",
                    configDirectory: configDirectory,
                    accountDescription: "Junie local profile"
                ),
                sortKey: 0
            )
        case .fx(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .fx,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "fx",
                    configDirectory: configDirectory,
                    accountDescription: "fx local profile"
                ),
                sortKey: 0
            )
        case .muse(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .muse,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Muse Code",
                    configDirectory: configDirectory,
                    accountDescription: "Muse Code local profile"
                ),
                sortKey: 0
            )
        case .omp(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .omp,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "OMP",
                    configDirectory: configDirectory,
                    accountDescription: "OMP local profile"
                ),
                sortKey: 0
            )
        case .primeAgent(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .primeAgent,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Prime Agent",
                    configDirectory: configDirectory,
                    accountDescription: "Prime Agent local profile"
                ),
                sortKey: 0
            )
        case .hermes(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .hermes,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Hermes",
                    configDirectory: configDirectory,
                    accountDescription: "Hermes local profile"
                ),
                sortKey: 0
            )
        case .goose(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .goose,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Goose",
                    configDirectory: configDirectory,
                    accountDescription: "Goose local profile"
                ),
                sortKey: 0
            )
        case .windsurf(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .windsurf,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Windsurf",
                    configDirectory: configDirectory,
                    accountDescription: "Windsurf local profile"
                ),
                sortKey: 0
            )
        case .openClaude(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .openClaude,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "OpenClaude",
                    configDirectory: configDirectory,
                    accountDescription: "OpenClaude local profile"
                ),
                sortKey: 0
            )
        case .openClaw(_, let configDirectory):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .openClaw,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "OpenClaw",
                    configDirectory: configDirectory,
                    accountDescription: "OpenClaw local profile"
                ),
                sortKey: 0
            )
        }

        guard let created = record else { return nil }

        do {
            let saved = try dataStore.switcherStore.create(created)

            // First profile auto-set as active (fail-closed: never steals the
            // active pointer if the count read fails).
            activateIfFirstProfile(saved.id, dataStore: dataStore)

            // Update identity state
            if let index = discoveredIdentities.firstIndex(where: { $0.id == identity.id }) {
                discoveredIdentities[index].isAdded = true
            }

            return saved
        } catch {
            AppLogger.sync.error("switcher_discovery_failed", metadata: ["error": error.localizedDescription])
            return nil
        }
    }

    // MARK: - Add Different Account (Browser)

    /// Signs into a different Google account via OAuth and creates a Chrome profile for it.
    @discardableResult
    func addDifferentGoogleAccount(dataStore: DataStore) async -> SwitcherProfileRecord? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        let accountManager = accountManagerProvider()

        do {
            try await accountManager.signInWithGoogle(presentingWindow: window)
        } catch {
            scanErrors.append("Google Sign-In failed: \(error.localizedDescription)")
            return nil
        }

        // Capture the signed-in account info
        let email = accountManager.userEmail
            ?? accountManager.currentUser?.email
            ?? accountManager.lastOAuthEmail
        let displayName = accountManager.userDisplayName
            ?? accountManager.currentUser?.displayName
            ?? accountManager.lastOAuthDisplayName

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

        let saved: SwitcherProfileRecord
        do {
            saved = try dataStore.switcherStore.create(record)
        } catch {
            scanErrors.append("Failed to save profile: \(error.localizedDescription)")
            return nil
        }

        // Fail closed: the profile advertises a Google provider, so a dropped
        // OAuth token must not leave it claiming sign-in with no credential.
        // Roll the new profile back and report the failure instead.
        do {
            try persistOAuthTokenIfPresent(forProfileID: saved.id, provider: "google")
        } catch {
            AppLogger.dataStore.error(
                "switcher_oauth_token_store_failed",
                metadata: ["provider": "google", "errorClass": "\(String(describing: type(of: error)))"]
            )
            rollBackOrphanedProfile(saved.id, dataStore: dataStore)
            scanErrors.append("Could not securely store the Google credential — profile not added.")
            return nil
        }

        // First profile auto-set as active (fail-closed count read).
        activateIfFirstProfile(saved.id, dataStore: dataStore)

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
    }

    /// Signs into a different Apple account via Sign in with Apple and creates a profile for it.
    @discardableResult
    func addDifferentAppleAccount(dataStore: DataStore) async -> SwitcherProfileRecord? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        let accountManager = accountManagerProvider()

        do {
            try await accountManager.signInWithApple(presentingWindow: window)
        } catch {
            scanErrors.append("Apple Sign-In failed: \(error.localizedDescription)")
            return nil
        }

        let email = accountManager.userEmail
            ?? accountManager.currentUser?.email
            ?? accountManager.lastOAuthEmail
        let displayName = accountManager.userDisplayName
            ?? accountManager.currentUser?.displayName
            ?? accountManager.lastOAuthDisplayName

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

        let saved: SwitcherProfileRecord
        do {
            saved = try dataStore.switcherStore.create(record)
        } catch {
            scanErrors.append("Failed to save profile: \(error.localizedDescription)")
            return nil
        }

        // Fail closed on a dropped Apple credential (see Google flow rationale).
        do {
            try persistOAuthTokenIfPresent(forProfileID: saved.id, provider: "apple")
        } catch {
            AppLogger.dataStore.error(
                "switcher_oauth_token_store_failed",
                metadata: ["provider": "apple", "errorClass": "\(String(describing: type(of: error)))"]
            )
            rollBackOrphanedProfile(saved.id, dataStore: dataStore)
            scanErrors.append("Could not securely store the Apple credential — profile not added.")
            return nil
        }

        activateIfFirstProfile(saved.id, dataStore: dataStore)

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
    }

    @discardableResult
    func refreshBrowserProfileAuthentication(
        _ profile: SwitcherProfileRecord,
        dataStore: DataStore
        ) async -> SwitcherProfileRecord? {
        guard profile.targetKind == .browser, let browserType = profile.browserType else { return nil }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        let accountManager = accountManagerProvider()

        let providerIdentifier = resolvedBrowserProviderIdentifier(
            profile.browserMetadata?.providerIdentifier,
            browserType: browserType
        )

        do {
            switch providerIdentifier {
            case "apple":
                try await accountManager.signInWithApple(presentingWindow: window)
            default:
                try await accountManager.signInWithGoogle(presentingWindow: window)
            }
        } catch {
            scanErrors.append("\(providerIdentifier.capitalized) Sign-In failed: \(error.localizedDescription)")
            return nil
        }

        let email = accountManager.userEmail
            ?? accountManager.currentUser?.email
            ?? accountManager.lastOAuthEmail
        let displayName = accountManager.userDisplayName
            ?? accountManager.currentUser?.displayName
            ?? accountManager.lastOAuthDisplayName

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

        let saved: SwitcherProfileRecord
        do {
            saved = try dataStore.switcherStore.update(updated)
        } catch {
            scanErrors.append("Failed to update profile: \(error.localizedDescription)")
            return nil
        }

        // Fail closed: a refresh whose new token can't be persisted would leave
        // the profile's stored credential stale/absent while its metadata claims
        // a fresh sign-in. Report the failure rather than pretend it succeeded.
        // The profile already existed, so there is nothing to roll back.
        do {
            try persistOAuthTokenIfPresent(forProfileID: saved.id, provider: providerIdentifier)
        } catch {
            AppLogger.dataStore.error(
                "switcher_oauth_token_store_failed",
                metadata: ["provider": providerIdentifier, "errorClass": "\(String(describing: type(of: error)))"]
            )
            scanErrors.append("Could not securely store the refreshed credential — please try again.")
            return nil
        }

        return saved
    }

    // MARK: - Add Different API Key (CLI)

    /// Launches the CLI login flow and saves the connected account as another profile.
    @discardableResult
    func addDifferentCLIAccount(
        cliType: SwitcherCLIProfileType,
        dataStore: DataStore
    ) async -> SwitcherProfileRecord? {
        // Fail closed: this list backs the duplicate-directory guard below. A
        // swallowed read that defaulted to `[]` would silently bypass dedup and
        // let a duplicate CLI profile through (state corruption), so we surface
        // the failure instead of guessing the user has no existing profiles.
        let allProfiles: [SwitcherProfileRecord]
        do {
            allProfiles = try dataStore.fetchSwitcherProfiles()
        } catch {
            AppLogger.dataStore.error(
                "switcher_existing_profiles_read_failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            scanErrors.append("Could not read existing profiles — please try again.")
            return nil
        }
        let existingProfiles = allProfiles
            .filter { $0.targetKind == .cli && $0.cliType == cliType }
        let placeholder = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: existingProfiles.isEmpty
                    ? "\(cliType.displayName) primary"
                    : "\(cliType.displayName) reserve #\(existingProfiles.count)"
            ),
            sortKey: 0
        )

        let coordinator = SwitcherCLIAuthCoordinator()
        let updatedProfile: SwitcherProfileRecord

        switch await coordinator.reconnect(
            profile: placeholder,
            context: SwitcherCLIAuthCoordinator.ReconnectContext(
                providerSlotLabel: placeholder.cliMetadata?.displayLabel,
                existingAccountLabels: existingProfiles.map { $0.cliMetadata?.accountDescription ?? $0.displayName }
            )
        ) {
        case .readyToPersist(let profile), .requiresConfirmation(let profile, _, _):
            updatedProfile = profile
        case .cancelled:
            return nil
        case .failed(let message):
            scanErrors.append(message)
            return nil
        }

        guard let metadata = updatedProfile.cliMetadata else { return nil }
        if let detectedDirectory = normalized(metadata.configDirectory),
           existingProfiles.contains(where: { normalized($0.cliMetadata?.configDirectory) == detectedDirectory }) {
            scanErrors.append("Already added: this local auth directory is already saved as a \(cliType.displayName) profile. Reconnect that profile instead of saving the same directory twice.")
            return nil
        }

        let detectedAccountDescription = normalized(metadata.accountDescription)
        let fallbackDisplayLabel = normalized(metadata.displayLabel) ?? cliType.displayName
        let hasMatchingIdentity = detectedAccountDescription.map { detected in
            existingProfiles.contains {
                normalized($0.cliMetadata?.accountDescription)?.caseInsensitiveCompare(detected) == .orderedSame
            }
        } ?? false
        let displayLabel = detectedAccountDescription.map { detected in
            hasMatchingIdentity ? "\(detected) · \(fallbackDisplayLabel)" : detected
        } ?? fallbackDisplayLabel

        let record = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: metadata.workingDirectory,
                additionalArgs: metadata.additionalArgs,
                envKeysToPass: metadata.envKeysToPass,
                displayLabel: displayLabel,
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

        do {
            let saved = try dataStore.switcherStore.create(record)
            var aclDeniedMessage: String?
            // Reconnect no longer snapshots the route token itself, so a flaky
            // Keychain can never discard a confirmed login. Snapshot it here,
            // non-fatally: the profile is already saved, so a denial only defers
            // quota tracking. The actionable ACL guidance is surfaced via
            // scanErrors; other faults are logged.
            if cliType == .claude {
                do {
                    try SwitcherCLIAuthCoordinator.persistProfileCredentialAfterConfirmedLogin(for: saved)
                } catch let snapshotError as ClaudeCodeOAuthCredentialImportError {
                    if case .accessDenied = snapshotError {
                        aclDeniedMessage = snapshotError.localizedDescription
                    }
                } catch {
                    AppLogger.dataStore.error(
                        "claude_route_credential_snapshot_failed",
                        metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                    )
                }
            }
            activateIfFirstProfile(saved.id, dataStore: dataStore)

            await scan(dataStore: dataStore)
            if let aclDeniedMessage {
                scanErrors.append(aclDeniedMessage)
            }
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
                case .droid(_, let configDirectory):
                    return cliType == .droid
                        && configDirectory == saved.cliMetadata?.configDirectory
                case .forge(_, let configDirectory):
                    return cliType == .forge
                        && configDirectory == saved.cliMetadata?.configDirectory
                case .antigravity(_, let configDirectory):
                    return cliType == .antigravity
                        && configDirectory == saved.cliMetadata?.configDirectory
                case .grok(_, let configDirectory):
                    return cliType == .grok
                        && configDirectory == saved.cliMetadata?.configDirectory
                case .cursorAgent(_, let configDirectory):
                    return cliType == .cursorAgent
                        && configDirectory == saved.cliMetadata?.configDirectory
                case .gemini(_, let configDirectory):
                    return cliType == .gemini
                        && configDirectory == saved.cliMetadata?.configDirectory
                case .kimi(_, let configDirectory):
                    return cliType == .kimi
                        && configDirectory == saved.cliMetadata?.configDirectory
                case .pi(_, let configDirectory):
                    return cliType == .pi
                        && configDirectory == saved.cliMetadata?.configDirectory
                case .junie(_, let configDirectory):
                    return cliType == .junie
                        && configDirectory == saved.cliMetadata?.configDirectory
                case .fx(_, let configDirectory):
                    return cliType == .fx
                        && configDirectory == saved.cliMetadata?.configDirectory
                case .muse(_, let configDirectory):
                    return cliType == .muse
                        && configDirectory == saved.cliMetadata?.configDirectory
                case .omp(_, let configDirectory):
                    return cliType == .omp
                        && configDirectory == saved.cliMetadata?.configDirectory
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
                envKeysToPass: apiKeyEnvironmentKeys(for: cliType),
                displayLabel: displayLabel,
                accountDescription: label
            ),
            sortKey: 0
        )

        let saved: SwitcherProfileRecord
        do {
            saved = try dataStore.switcherStore.create(record)
        } catch {
            scanErrors.append("Failed to save CLI profile: \(error.localizedDescription)")
            return nil
        }

        // Fail closed: the identity is published as `apiKeyPresent`, so a profile
        // whose API key never reached the Keychain would lie about being usable.
        // Roll the orphan back and report instead of leaving a credential-less
        // profile that advertises a key it does not have.
        do {
            try makeAuthStore().storeAPIKey(apiKey, forProfileID: saved.id, cliType: cliType)
        } catch {
            AppLogger.dataStore.error(
                "switcher_api_key_store_failed",
                metadata: ["cliType": cliType.rawValue, "errorClass": "\(String(describing: type(of: error)))"]
            )
            rollBackOrphanedProfile(saved.id, dataStore: dataStore)
            scanErrors.append("Could not securely store the API key — profile not added.")
            return nil
        }

        activateIfFirstProfile(saved.id, dataStore: dataStore)

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
    }

    private func cliTypeDiscoverySource(_ cliType: SwitcherCLIProfileType, apiKey: String) -> DiscoverySource {
        switch cliType {
        case .codex:
            return .codex(executablePath: CLILaunchAdapter.executablePath(for: .codex) ?? "", hasAPIKey: true, lastRefresh: nil, accountDescription: nil, configDirectory: nil)
        case .claude:
            return .claudeCode(executablePath: CLILaunchAdapter.executablePath(for: .claude) ?? "", isAuthenticated: false, accountDescription: nil, configDirectory: nil)
        case .opencode:
            return .opencode(executablePath: CLILaunchAdapter.executablePath(for: .opencode))
        case .droid:
            return .droid(executablePath: CLILaunchAdapter.executablePath(for: .droid), configDirectory: nil)
        case .forge:
            return .forge(executablePath: CLILaunchAdapter.executablePath(for: .forge), configDirectory: nil)
        case .antigravity:
            return .antigravity(executablePath: CLILaunchAdapter.executablePath(for: .antigravity), configDirectory: nil)
        case .grok:
            return .grok(executablePath: CLILaunchAdapter.executablePath(for: .grok), configDirectory: nil)
        case .cursorAgent:
            return .cursorAgent(executablePath: CLILaunchAdapter.executablePath(for: .cursorAgent), configDirectory: nil)
        case .gemini:
            return .gemini(executablePath: CLILaunchAdapter.executablePath(for: .gemini), configDirectory: nil)
        case .kimi:
            return .kimi(executablePath: CLILaunchAdapter.executablePath(for: .kimi), configDirectory: nil)
        case .pi:
            return .pi(executablePath: CLILaunchAdapter.executablePath(for: .pi), configDirectory: nil)
        case .junie:
            return .junie(executablePath: CLILaunchAdapter.executablePath(for: .junie), configDirectory: nil)
        case .fx:
            return .fx(executablePath: CLILaunchAdapter.executablePath(for: .fx), configDirectory: nil)
        case .muse:
            return .muse(executablePath: CLILaunchAdapter.executablePath(for: .muse), configDirectory: nil)
        case .omp:
            return .omp(executablePath: CLILaunchAdapter.executablePath(for: .omp), configDirectory: nil)
        case .primeAgent:
            return .primeAgent(executablePath: CLILaunchAdapter.executablePath(for: .primeAgent), configDirectory: nil)
        case .hermes:
            return .hermes(executablePath: CLILaunchAdapter.executablePath(for: .hermes), configDirectory: nil)
        case .goose:
            return .goose(executablePath: CLILaunchAdapter.executablePath(for: .goose), configDirectory: nil)
        case .windsurf:
            return .windsurf(executablePath: CLILaunchAdapter.executablePath(for: .windsurf), configDirectory: nil)
        case .openClaude:
            return .openClaude(executablePath: CLILaunchAdapter.executablePath(for: .openClaude), configDirectory: nil)
        case .openClaw:
            return .openClaw(executablePath: CLILaunchAdapter.executablePath(for: .openClaw), configDirectory: nil)
        }
    }

    private func apiKeyEnvironmentKeys(for cliType: SwitcherCLIProfileType) -> [String] {
        switch cliType {
        case .junie:
            return ["JUNIE_API_KEY"]
        default:
            return []
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

        case .codex, .claudeCode, .opencode, .droid, .forge, .antigravity, .grok, .cursorAgent, .gemini, .kimi, .pi, .omp, .junie, .primeAgent, .fx, .muse, .hermes, .goose, .windsurf, .openClaude, .openClaw:
            // Quick CLI version check
            let cliType: SwitcherCLIProfileType
            switch identity.source {
            case .codex: cliType = .codex
            case .claudeCode: cliType = .claude
            case .opencode: cliType = .opencode
            case .droid: cliType = .droid
            case .forge: cliType = .forge
            case .antigravity: cliType = .antigravity
            case .grok: cliType = .grok
            case .cursorAgent: cliType = .cursorAgent
            case .gemini: cliType = .gemini
            case .kimi: cliType = .kimi
            case .pi: cliType = .pi
            case .junie: cliType = .junie
            case .fx: cliType = .fx
            case .muse: cliType = .muse
            case .omp: cliType = .omp
            case .primeAgent: cliType = .primeAgent
            case .hermes: cliType = .hermes
            case .goose: cliType = .goose
            case .windsurf: cliType = .windsurf
            case .openClaude: cliType = .openClaude
            case .openClaw: cliType = .openClaw
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
        for cliAuthInfos: [CLIAuthInfo]
    ) -> [SwitcherCLIProfileType: IdentityQuotaSummary] {
        let quotaService = ProviderQuotaService.shared
        var summaries: [SwitcherCLIProfileType: IdentityQuotaSummary] = [:]
        var deferredRefreshes = 0

        for cliInfo in cliAuthInfos where cliInfo.isInstalled {
            guard let provider = quotaProvider(for: cliInfo.cliType) else { continue }

            let existingSnapshot = quotaService.snapshot(for: provider)
            guard let snapshot = quotaService.snapshot(for: provider),
                  let summary = quotaSummary(from: snapshot) else {
                if shouldRefreshQuotaSnapshot(existingSnapshot) {
                    deferredRefreshes += 1
                }
                continue
            }

            summaries[cliInfo.cliType] = summary

            let fiveHour = summary.fiveHourRemaining ?? "--"
            let weekly = summary.weeklyRemaining ?? "--"
            scanProgress.append("\(cliInfo.cliType.displayName) quota — 5h \(fiveHour), weekly \(weekly)")
        }

        if deferredRefreshes > 0 {
            scanProgress.append(
                "\(deferredRefreshes) quota refresh\(deferredRefreshes == 1 ? "" : "es") deferred until after setup"
            )
        }

        return summaries
    }

    private func shouldRefreshQuotaSnapshot(_ snapshot: ProviderQuotaSnapshot?) -> Bool {
        guard let snapshot else { return true }
        if !snapshot.hasDisplayableQuotaSignal { return true }
        return snapshot.isStale()
    }

    private func quotaProvider(for cliType: SwitcherCLIProfileType) -> AgentProvider? {
        switch cliType {
        case .codex:
            return .codex
        case .claude:
            return .claudeCode
        case .opencode:
            return .openCode
        case .droid:
            return .factory
        case .forge:
            return .forgeDev
        case .antigravity:
            return .antigravity
        case .grok:
            return .xAI
        case .cursorAgent:
            return .cursorAgent
        case .gemini:
            return .geminiCLI
        case .kimi:
            return .kimi
        case .pi:
            return .piAgent
        case .junie:
            return .junie
        case .fx:
            // fx has no quota signal; usage is tracked from local sessions.
            return nil
        case .muse:
            // Muse has no quota signal; usage is tracked from local sessions.
            return nil
        case .omp:
            return .omp
        case .primeAgent:
            return .primeAgent
        case .hermes:
            return .hermes
        case .goose:
            return .goose
        case .windsurf:
            return .windsurf
        case .openClaude:
            return .openClaude
        case .openClaw:
            return .openClaw
        }
    }

    private func quotaSummary(from snapshot: ProviderQuotaSnapshot) -> IdentityQuotaSummary? {
        let fiveHourRemaining = snapshot.hourlyBucket?.remainingText
        let weeklyRemaining = snapshot.weeklyBucket?.remainingText
        let fiveHourReset = snapshot.hourlyBucket?.resetsAtDisplay.map { "resets \($0.relative)" }
        let weeklyReset = snapshot.weeklyBucket?.resetsAtDisplay.map { "resets \($0.relative)" }

        guard fiveHourRemaining != nil || weeklyRemaining != nil else {
            return nil
        }

        return IdentityQuotaSummary(
            fiveHourRemaining: fiveHourRemaining,
            weeklyRemaining: weeklyRemaining,
            fiveHourReset: fiveHourReset,
            weeklyReset: weeklyReset
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

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Active-Profile Activation

    /// Auto-activates `savedID` only when it is genuinely the first profile.
    ///
    /// The previous `(try? fetchAllProfiles().count) ?? 0` swallowed read
    /// failures by defaulting the count to `0`, which made `count <= 1` true and
    /// silently *stole* the active profile from whatever the user had selected —
    /// a fail-open on user-facing state. This fails closed instead: if the count
    /// can't be read, we log and skip activation rather than clobber the
    /// existing active pointer. The activation write itself is also logged on
    /// failure so a created-but-not-activated profile is observable.
    private func activateIfFirstProfile(_ savedID: String, dataStore: DataStore) {
        let existingCount: Int
        do {
            existingCount = try dataStore.countSwitcherProfiles()
        } catch {
            AppLogger.dataStore.error(
                "switcher_active_profile_count_read_failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            return
        }

        guard existingCount <= 1 else { return }

        do {
            try dataStore.setActiveSwitcherProfile(savedID)
        } catch {
            AppLogger.dataStore.error(
                "switcher_set_active_profile_failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
        }
    }

    // MARK: - OAuth Token Persistence (fail-closed)

    /// Persists the most recent OAuth token for `profileID` under `provider`,
    /// throwing on a genuine Keychain fault.
    ///
    /// This is deliberately throwing (not `try?`): a browser profile is created
    /// with a `providerIdentifier` that advertises it as authenticated, so a
    /// silently dropped token would leave a profile that *claims* sign-in but has
    /// no credential to launch with — a security/correctness fail-open. Callers
    /// run this inside their create/update `do` block so the failure unwinds to
    /// the same fail-closed path that surfaces an error and returns `nil`.
    private func persistOAuthTokenIfPresent(forProfileID profileID: String, provider: String) throws {
        guard let token = accountManagerProvider().lastOAuthToken, !token.isEmpty else { return }
        try makeAuthStore().storeOAuthToken(token, forProfileID: profileID, provider: provider)
    }

    /// Deletes a profile that was created but could not be fully provisioned
    /// (e.g. its OAuth credential failed to persist), so the store never holds a
    /// half-initialized, credential-less profile. A delete failure here is
    /// logged but not fatal — the caller has already decided to fail the add.
    private func rollBackOrphanedProfile(_ profileID: String, dataStore: DataStore) {
        do {
            try dataStore.switcherStore.deleteProfile(id: profileID)
        } catch {
            AppLogger.dataStore.error(
                "switcher_orphan_profile_rollback_failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
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
        case (.droid, .droidCLI): return true
        case (.forge, .forgeCLI): return true
        case (.antigravity, .antigravityCLI): return true
        case (.grok, .grokCLI): return true
        case (.cursorAgent, .cursorAgentCLI): return true
        case (.gemini, .geminiCLI): return true
        case (.kimi, .kimiCLI): return true
        case (.pi, .piCLI): return true
        case (.junie, .junieCLI): return true
        case (.fx, .fxCLI): return true
        case (.muse, .museCLI): return true
        case (.omp, .ompCLI): return true
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
        case .droid: return .droid
        case .forge: return .forge
        case .antigravity: return .antigravity
        case .grok: return .grok
        case .cursorAgent: return .cursorAgent
        case .gemini: return .gemini
        case .kimi: return .kimi
        case .pi: return .pi
        case .junie: return .junie
        case .fx: return .fx
        case .muse: return .muse
        case .omp: return .omp
        case .primeAgent: return .primeAgent
        case .hermes: return .hermes
        case .goose: return .goose
        case .windsurf: return .windsurf
        case .openClaude: return .openClaude
        case .openClaw: return .openClaw
        default: return nil
        }
    }
}
