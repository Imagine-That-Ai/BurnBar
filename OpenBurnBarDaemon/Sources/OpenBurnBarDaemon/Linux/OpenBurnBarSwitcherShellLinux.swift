#if os(Linux)
import Foundation
import OpenBurnBarCore

public enum BurnBarSwitcherShellError: LocalizedError, Equatable {
    case unsupportedCLI(String)
    case missingRequestedProfile(String)
    case requestedProfileMismatch(expected: SwitcherCLIProfileType, actual: SwitcherCLIProfileType?)
    case noProfilesConfigured(SwitcherCLIProfileType)
    case terminalSpawnFailed(String)
    case terminalExited(Int32, detail: String?)
    case quotaExhausted(String)
    case shimInstallFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedCLI(let name):
            return name
        case .missingRequestedProfile(let profileID):
            return "Switcher profile '\(profileID)' was not found."
        case .requestedProfileMismatch(let expected, let actual):
            return "Requested profile does not match \(expected.displayName). Found \(actual?.displayName ?? "unknown")."
        case .noProfilesConfigured(let cliType):
            return "No \(cliType.displayName) switcher profiles are configured yet."
        case .terminalSpawnFailed(let detail):
            return detail
        case .terminalExited(let status, let detail):
            return detail ?? "CLI exited with status \(status)."
        case .quotaExhausted(let detail):
            return detail
        case .shimInstallFailed(let detail):
            return detail
        }
    }
}

public struct BurnBarCLIShellExecutionResult: Equatable, Sendable {
    public let exitCode: Int32
    public let launchedProfileID: String?
    public let attemptedProfileIDs: [String]
    public let fallbackTriggered: Bool

    public init(
        exitCode: Int32,
        launchedProfileID: String?,
        attemptedProfileIDs: [String],
        fallbackTriggered: Bool
    ) {
        self.exitCode = exitCode
        self.launchedProfileID = launchedProfileID
        self.attemptedProfileIDs = attemptedProfileIDs
        self.fallbackTriggered = fallbackTriggered
    }
}

public struct BurnBarCLIShellLaunchRequest: Equatable, Sendable {
    public let cliType: SwitcherCLIProfileType
    public let forwardedArguments: [String]
    public let requestedProfileID: String?

    public init(
        cliType: SwitcherCLIProfileType,
        forwardedArguments: [String],
        requestedProfileID: String? = nil
    ) {
        self.cliType = cliType
        self.forwardedArguments = forwardedArguments
        self.requestedProfileID = requestedProfileID
    }
}

public protocol BurnBarCLIShellExecuting: Sendable {
    func execute(_ request: BurnBarCLIShellLaunchRequest) async throws -> BurnBarCLIShellExecutionResult
}

public protocol BurnBarSwitcherProfileStoreProviding: Sendable {
    func fetchProfile(id: String) -> SwitcherProfileRecord?
    func fetchAllProfiles() -> [SwitcherProfileRecord]
    func fetchActiveProfileID() -> String?
    func setActiveProfileID(_ profileID: String?)
    func updateProfile(_ profile: SwitcherProfileRecord)
}

public final class BurnBarSwitcherSQLiteProfileStore: BurnBarSwitcherProfileStoreProviding, Sendable {
    public init(databaseURL: URL = BurnBarDaemonPaths.supportDirectoryURL.appendingPathComponent("openburnbar.sqlite")) throws {
        _ = databaseURL
    }

    public func fetchProfile(id: String) -> SwitcherProfileRecord? {
        _ = id
        return nil
    }

    public func fetchAllProfiles() -> [SwitcherProfileRecord] {
        []
    }

    public func fetchActiveProfileID() -> String? {
        nil
    }

    public func setActiveProfileID(_ profileID: String?) {
        _ = profileID
    }

    public func updateProfile(_ profile: SwitcherProfileRecord) {
        _ = profile
    }
}

public final class BurnBarCLIShellExecutor: BurnBarCLIShellExecuting, Sendable {
    private let profileStore: any BurnBarSwitcherProfileStoreProviding

    public init(profileStore: any BurnBarSwitcherProfileStoreProviding) {
        self.profileStore = profileStore
    }

    public func execute(_ request: BurnBarCLIShellLaunchRequest) async throws -> BurnBarCLIShellExecutionResult {
        _ = profileStore
        throw BurnBarSwitcherShellError.unsupportedCLI(
            "CLI switcher shell execution is unavailable on Linux."
        )
    }
}

public struct BurnBarCLIShellShimInstallResult: Equatable, Sendable {
    public let installDirectory: URL
    public let installedCommands: [String]
}

public protocol BurnBarCLIShellShimInstalling: Sendable {
    func installShims(invokedExecutablePath: String) throws -> BurnBarCLIShellShimInstallResult
}

public struct BurnBarCLIShellShimInstaller: BurnBarCLIShellShimInstalling, Sendable {
    public static let defaultInstallDirectory = BurnBarDaemonPaths.supportDirectoryURL
        .appendingPathComponent("bin", isDirectory: true)

    public init() {}

    public func installShims(invokedExecutablePath: String) throws -> BurnBarCLIShellShimInstallResult {
        _ = invokedExecutablePath
        throw BurnBarSwitcherShellError.shimInstallFailed(
            "Shell shims are unavailable on Linux because the switcher shell surface is excluded from this compile gate."
        )
    }
}
#endif
