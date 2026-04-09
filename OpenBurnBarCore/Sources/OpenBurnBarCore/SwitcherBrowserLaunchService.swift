import Foundation

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

    /// Creates a new browser launch service.
    public init(profileStore: SwitcherProfileStoreAdapter) {
        self.profileStore = profileStore
        self.coordinator = BrowserLaunchCoordinator()
    }

    // MARK: - Launch Methods

    /// Launches the browser for the given profile.
    /// Returns immediately if a launch is already in progress for this profile.
    public func launchBrowser(for profileID: String) async -> LaunchOutcome {
        // Begin launch coordination
        let sequence = await coordinator.beginLaunch(profileID: profileID)
        guard sequence != nil else {
            // Launch already in progress
            return LaunchOutcome(
                success: false,
                error: .launchFailed("Launch already in progress for this profile")
            )
        }

        defer {
            Task {
                await coordinator.endLaunch(profileID: profileID, success: false)
            }
        }

        // Fetch profile
        guard let profile = profileStore.fetchProfile(id: profileID) else {
            return LaunchOutcome(
                success: false,
                error: .profileNotFound(profileID)
            )
        }

        // Validate profile is for browser
        guard profile.targetKind == .browser else {
            return LaunchOutcome(
                success: false,
                error: .profileKindMismatch(expected: .browser, actual: profile.targetKind)
            )
        }

        // Handle by browser type
        switch profile.browserType {
        case .chrome:
            return await launchChrome(profile: profile)
        case .safari:
            return await launchSafari(profile: profile)
        case .none:
            return LaunchOutcome(
                success: false,
                error: .missingProfileMetadata(profileID)
            )
        }
    }

    /// Launches Chrome for the given profile.
    private func launchChrome(profile: SwitcherProfileRecord) async -> LaunchOutcome {
        let buildResult = BrowserLaunchAdapter.buildChromeLaunch(profile: profile)

        switch buildResult {
        case .failure(let error):
            return LaunchOutcome(success: false, error: error)

        case .success(let (appURL, args)):
            // Extract profile directory from args
            let profileDir = args.first { $0.hasPrefix("--profile-directory=") }
                .flatMap { String($0.dropFirst("--profile-directory=".count)) }
                ?? "Default"

            let launchResult = await BrowserLaunchInvoker.launchChrome(
                appURL: appURL,
                profileDirectory: profileDir,
                args: args.filter { !$0.hasPrefix("--profile-directory=") }
            )

            switch launchResult {
            case .success:
                await coordinator.endLaunch(profileID: profile.id, success: true)
                return LaunchOutcome(success: true, error: nil)
            case .failure(let error):
                return LaunchOutcome(success: false, error: error)
            }
        }
    }

    /// Launches Safari for the given profile.
    private func launchSafari(profile: SwitcherProfileRecord) async -> LaunchOutcome {
        let buildResult = BrowserLaunchAdapter.buildSafariLaunch(profile: profile)

        switch buildResult {
        case .failure(let error):
            return LaunchOutcome(success: false, error: error)

        case .success(let (appURL, args)):
            let launchResult = await BrowserLaunchInvoker.launchSafari(
                appURL: appURL,
                args: args
            )

            switch launchResult {
            case .success:
                await coordinator.endLaunch(profileID: profile.id, success: true)
                return LaunchOutcome(success: true, error: nil)
            case .failure(let error):
                return LaunchOutcome(success: false, error: error)
            }
        }
    }

    // MARK: - Availability Checking

    /// Checks if a browser is installed and available.
    public func isBrowserAvailable(_ browserType: SwitcherBrowserProfileType) -> Bool {
        return BrowserLaunchAdapter.isBrowserAvailable(browserType)
    }

    /// Returns the URL for a browser if available.
    public func browserURL(for browserType: SwitcherBrowserProfileType) -> URL? {
        return BrowserLaunchAdapter.browserURL(for: browserType)
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
}

// MARK: - In-Memory Adapter for Testing

/// In-memory adapter for testing without GRDB.
public final class InMemorySwitcherProfileStoreAdapter: SwitcherProfileStoreAdapter, @unchecked Sendable {
    private var profiles: [String: SwitcherProfileRecord] = [:]
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
}
