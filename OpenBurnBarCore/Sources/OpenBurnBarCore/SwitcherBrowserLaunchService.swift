import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Browser Availability Provider

/// Protocol for checking browser availability and constructing launch configurations.
/// This abstracts browser-specific logic so it can be replaced in tests.
public protocol BrowserAvailabilityProviding: Sendable {
    /// Checks if a browser is installed and available for launching.
    func isBrowserAvailable(_ browserType: SwitcherBrowserProfileType) -> Bool

    /// Returns the URL for a browser application, if available.
    func browserURL(for browserType: SwitcherBrowserProfileType) -> URL?

    /// Returns the bundle identifier for a browser type.
    func bundleIdentifier(for browserType: SwitcherBrowserProfileType) -> String?

    /// Checks if a browser is available and returns the app URL if so.
    func resolveBrowserURL(_ browserType: SwitcherBrowserProfileType) -> Result<URL, BrowserLaunchError>

    /// Checks if the browser for the given profile is available.
    func isProfileBrowserAvailable(_ profile: SwitcherProfileRecord) -> Bool
}

// MARK: - Production Browser Availability Provider

/// Production implementation that uses NSWorkspace to resolve browser availability.
public struct ProductionBrowserAvailabilityProvider: BrowserAvailabilityProviding {
    public init() {}

    public func isBrowserAvailable(_ browserType: SwitcherBrowserProfileType) -> Bool {
        guard let bundleID = browserType.bundleIdentifier else { return false }
        #if canImport(AppKit)
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        #else
        return false
        #endif
    }

    public func browserURL(for browserType: SwitcherBrowserProfileType) -> URL? {
        guard let bundleID = browserType.bundleIdentifier else { return nil }
        #if canImport(AppKit)
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        #else
        return nil
        #endif
    }

    public func bundleIdentifier(for browserType: SwitcherBrowserProfileType) -> String? {
        return browserType.bundleIdentifier
    }

    public func resolveBrowserURL(_ browserType: SwitcherBrowserProfileType) -> Result<URL, BrowserLaunchError> {
        guard let url = browserURL(for: browserType) else {
            return .failure(.browserNotInstalled(browserType))
        }
        return .success(url)
    }

    public func isProfileBrowserAvailable(_ profile: SwitcherProfileRecord) -> Bool {
        guard profile.targetKind == .browser, let browserType = profile.browserType else {
            return false
        }
        return isBrowserAvailable(browserType)
    }
}

// MARK: - Switcher Browser Launch Service

/// High-level service for browser launch orchestration.
/// Combines profile resolution, launch validation, concurrency handling, and error typing.
///
/// Security invariants:
/// - Never mutates browser profile, session, or auth files
/// - Uses only allowlisted launch arguments
/// - Typed errors for all failure modes
/// - Serialized launches via coordinator
public final class SwitcherBrowserLaunchService: @unchecked Sendable {
    private let profileStore: SwitcherProfileStoreAdapter
    private let coordinator: BrowserLaunchCoordinator
    private let browserProvider: BrowserAvailabilityProviding

    /// Creates a new browser launch service.
    /// - Parameters:
    ///   - profileStore: The profile store to use for profile lookups.
    ///   - browserProvider: The browser availability provider. Defaults to production NSWorkspace-based resolution.
    public init(profileStore: SwitcherProfileStoreAdapter, browserProvider: BrowserAvailabilityProviding = ProductionBrowserAvailabilityProvider()) {
        self.profileStore = profileStore
        self.browserProvider = browserProvider
        self.coordinator = BrowserLaunchCoordinator()
    }

    // MARK: - Launch Methods

    /// Launches the browser for the given profile.
    /// Returns immediately if a launch is already in progress for this profile.
    public func launchBrowser(for profileID: String, opening urls: [URL] = []) async -> LaunchOutcome {
        // Begin launch coordination
        let sequence = await coordinator.beginLaunch(profileID: profileID)
        guard sequence != nil else {
            // Launch already in progress
            return LaunchOutcome(
                success: false,
                error: .launchFailed("Launch already in progress for this profile")
            )
        }

        // Fetch profile
        guard let profile = profileStore.fetchProfile(id: profileID) else {
            await coordinator.endLaunch(profileID: profileID, success: false)
            return LaunchOutcome(
                success: false,
                error: .profileNotFound(profileID)
            )
        }

        // Validate profile is for browser
        guard profile.targetKind == .browser else {
            await coordinator.endLaunch(profileID: profileID, success: false)
            return LaunchOutcome(
                success: false,
                error: .profileKindMismatch(expected: .browser, actual: profile.targetKind)
            )
        }

        // Handle by browser type
        switch profile.browserType {
        case .chrome:
            return await launchChrome(profile: profile, urls: urls)
        case .safari:
            return await launchSafari(profile: profile, urls: urls)
        case .none:
            await coordinator.endLaunch(profileID: profileID, success: false)
            return LaunchOutcome(
                success: false,
                error: .missingProfileMetadata(profileID)
            )
        }
    }

    /// Launches the browser for the current active profile.
    /// This method reads the active profile ID from the store and launches it
    /// without requiring an explicit profile ID override.
    ///
    /// This is the key method for active-state routing - it proves that
    /// the launch adapter consumes the final committed global active profile.
    ///
    /// Returns `.noActiveProfile` if no profile is currently active.
    public func launchUsingActiveProfile() async -> LaunchOutcome {
        // Fetch the active profile ID from global state
        guard let activeProfileID = profileStore.fetchActiveProfileID() else {
            return LaunchOutcome(
                success: false,
                error: .noActiveProfile
            )
        }

        // Launch using the active profile ID
        return await launchBrowser(for: activeProfileID)
    }

    /// Launches Chrome for the given profile.
    private func launchChrome(profile: SwitcherProfileRecord, urls: [URL]) async -> LaunchOutcome {
        // First check browser availability using our injectable provider
        let urlResult = browserProvider.resolveBrowserURL(.chrome)

        switch urlResult {
        case .failure(let error):
            await coordinator.endLaunch(profileID: profile.id, success: false)
            return LaunchOutcome(success: false, error: error)

        case .success(let appURL):
            // Build Chrome-specific arguments using the adapter
            let buildResult = BrowserLaunchAdapter.buildChromeLaunch(
                profile: profile,
                browserURL: appURL
            )

            switch buildResult {
            case .failure(let error):
                await coordinator.endLaunch(profileID: profile.id, success: false)
                return LaunchOutcome(success: false, error: error)

            case .success(let (_, launchArgs)):
                // Extract profile directory from args
                let profileDir = launchArgs.first { $0.hasPrefix("--profile-directory=") }
                    .flatMap { String($0.dropFirst("--profile-directory=".count)) }
                    ?? "Default"

                let launchResult = await BrowserLaunchInvoker.launchChrome(
                    appURL: appURL,
                    profileDirectory: profileDir,
                    args: launchArgs.filter { !$0.hasPrefix("--profile-directory=") },
                    urls: urls
                )

                switch launchResult {
                case .success:
                    await coordinator.endLaunch(profileID: profile.id, success: true)
                    return LaunchOutcome(success: true, error: nil)
                case .failure(let error):
                    await coordinator.endLaunch(profileID: profile.id, success: false)
                    return LaunchOutcome(success: false, error: error)
                }
            }
        }
    }

    /// Launches Safari for the given profile.
    private func launchSafari(profile: SwitcherProfileRecord, urls: [URL]) async -> LaunchOutcome {
        // First check browser availability using our injectable provider
        let urlResult = browserProvider.resolveBrowserURL(.safari)

        switch urlResult {
        case .failure(let error):
            await coordinator.endLaunch(profileID: profile.id, success: false)
            return LaunchOutcome(success: false, error: error)

        case .success(let appURL):
            // Build Safari-specific arguments using the adapter
            let buildResult = BrowserLaunchAdapter.buildSafariLaunch(
                profile: profile,
                browserURL: appURL
            )

            switch buildResult {
            case .failure(let error):
                await coordinator.endLaunch(profileID: profile.id, success: false)
                return LaunchOutcome(success: false, error: error)

            case .success(let (_, launchArgs)):
                let launchResult = await BrowserLaunchInvoker.launchSafari(
                    appURL: appURL,
                    args: launchArgs,
                    urls: urls
                )

                switch launchResult {
                case .success:
                    await coordinator.endLaunch(profileID: profile.id, success: true)
                    return LaunchOutcome(success: true, error: nil)
                case .failure(let error):
                    await coordinator.endLaunch(profileID: profile.id, success: false)
                    return LaunchOutcome(success: false, error: error)
                }
            }
        }
    }

    // MARK: - Availability Checking

    /// Checks if a browser is installed and available.
    public func isBrowserAvailable(_ browserType: SwitcherBrowserProfileType) -> Bool {
        return browserProvider.isBrowserAvailable(browserType)
    }

    /// Returns the URL for a browser if available.
    public func browserURL(for browserType: SwitcherBrowserProfileType) -> URL? {
        return browserProvider.browserURL(for: browserType)
    }

    /// Returns the last attempted profile ID from the coordinator, for test verification.
    /// This allows tests to verify that the correct profile ID was routed through
    /// the launch service, not just that an error occurred.
    public func getLastAttemptedProfileID() async -> String? {
        return await coordinator.getLastAttemptedProfileID()
    }
}

// MARK: - Launch Outcome

/// Result of a browser launch attempt with typed error.
public struct LaunchOutcome: Equatable, Sendable {
    public let success: Bool
    public let error: BrowserLaunchError?

    public init(success: Bool, error: BrowserLaunchError?) {
        self.success = success
        self.error = error
    }

    public static func == (lhs: LaunchOutcome, rhs: LaunchOutcome) -> Bool {
        return lhs.success == rhs.success && lhs.error == rhs.error
    }
}

// MARK: - Profile Store Adapter

/// Protocol for accessing profile data.
/// This abstracts the actual storage so we can test without GRDB dependencies.
public protocol SwitcherProfileStoreAdapter: Sendable {
    func fetchProfile(id: String) -> SwitcherProfileRecord?
    func fetchAllProfiles() -> [SwitcherProfileRecord]
    /// Returns the currently active profile ID, if any.
    func fetchActiveProfileID() -> String?
    /// Sets the active profile ID. Pass nil to clear.
    func setActiveProfileID(_ profileID: String?)
    /// Persists an updated profile record.
    func updateProfile(_ profile: SwitcherProfileRecord)
}

// MARK: - In-Memory Adapter for Testing

/// In-memory adapter for testing without GRDB.
public final class InMemorySwitcherProfileStoreAdapter: SwitcherProfileStoreAdapter, @unchecked Sendable {
    private var profiles: [String: SwitcherProfileRecord] = [:]
    private var activeProfileID: String?
    private let lock = NSLock()

    public init() {}

    public func addProfile(_ profile: SwitcherProfileRecord) {
        lock.lock()
        defer { lock.unlock() }
        profiles[profile.id] = profile
    }

    public func fetchProfile(id: String) -> SwitcherProfileRecord? {
        lock.lock()
        defer { lock.unlock() }
        return profiles[id]
    }

    public func fetchAllProfiles() -> [SwitcherProfileRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(profiles.values).sorted { $0.sortKey < $1.sortKey }
    }

    public func fetchActiveProfileID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return activeProfileID
    }

    public func setActiveProfileID(_ profileID: String?) {
        lock.lock()
        defer { lock.unlock() }
        activeProfileID = profileID
    }

    public func updateProfile(_ profile: SwitcherProfileRecord) {
        lock.lock()
        defer { lock.unlock() }
        profiles[profile.id] = profile
    }
}
