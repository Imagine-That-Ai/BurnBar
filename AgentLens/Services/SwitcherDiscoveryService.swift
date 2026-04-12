import SwiftUI
import OpenBurnBarCore

// MARK: - Discovery Models

/// The source of a discovered identity.
enum DiscoverySource: Equatable {
    case chromeProfile(folderKey: String, email: String?, gaiaName: String?)
    case safari
    case codex(executablePath: String, hasAPIKey: Bool, lastRefresh: Date?)
    case claudeCode(executablePath: String, isAuthenticated: Bool)
    case opencode(executablePath: String?)
}

/// Authentication state of a discovered identity.
enum IdentityAuthState: Equatable {
    case authenticated
    case apiKeyPresent
    case notAuthenticated
    case notInstalled
}

/// A discovered identity that can be one-click added as a profile.
struct DiscoveredIdentity: Identifiable, Equatable {
    let id: String
    let source: DiscoverySource
    let displayTitle: String
    let subtitle: String
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
                    gaiaName: profile.displayName
                ),
                displayTitle: profile.displayName,
                subtitle: profile.email ?? "Profile: \(profile.folderKey)",
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
                authState: .authenticated,
                isAlreadyAdded: isDuplicate
            ))
        }

        // Scan CLI tools
        scanProgress.append("Scanning CLI tools...")
        let cliAuthInfos = CLIAuthDiscovery.discoverAuthStates()

        for cliInfo in cliAuthInfos {
            let source: DiscoverySource
            switch cliInfo.cliType {
            case .codex:
                source = .codex(
                    executablePath: cliInfo.executablePath ?? "",
                    hasAPIKey: cliInfo.authState == .apiKeyPresent,
                    lastRefresh: nil
                )
            case .claude:
                source = .claudeCode(
                    executablePath: cliInfo.executablePath ?? "",
                    isAuthenticated: {
                        if case .authenticated = cliInfo.authState { return true }
                        return false
                    }()
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
        case .chromeProfile(let folderKey, _, let gaiaName):
            guard ChromeProfileDiscovery.validateProfileFolder(folderKey) else { return nil }
            record = SwitcherProfileRecord(
                targetKind: .browser,
                browserType: .chrome,
                browserMetadata: SwitcherBrowserProfileMetadata(
                    profileIdentifier: folderKey,
                    displayLabel: gaiaName
                ),
                sortKey: 0
            )

        case .safari:
            record = SwitcherProfileRecord(
                targetKind: .browser,
                browserType: .safari,
                browserMetadata: SwitcherBrowserProfileMetadata(
                    profileIdentifier: "Default",
                    displayLabel: "Safari"
                ),
                sortKey: 0
            )

        case .codex(let execPath, _, _):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .codex,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Codex"
                ),
                sortKey: 0
            )

        case .claudeCode(let execPath, _):
            record = SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .claude,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: nil,
                    displayLabel: "Claude Code"
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

    // MARK: - Verify Identity

    /// Quick verification after adding a profile.
    func verifyIdentity(_ identity: DiscoveredIdentity) async -> Bool {
        if let index = discoveredIdentities.firstIndex(where: { $0.id == identity.id }) {
            discoveredIdentities[index].isVerifying = true
        }

        var success = false

        switch identity.source {
        case .chromeProfile(let folderKey, _, _):
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
