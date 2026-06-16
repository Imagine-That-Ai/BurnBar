import Foundation

// Shared value types for the in-app updater. These are channel-agnostic and
// pure (no AppKit, no I/O) so they unit-test headlessly and so the SwiftUI
// banner, the checker, and the per-channel services all speak one vocabulary.
//
// The whole direct-download / source updater is compiled out of the sandboxed
// Mac App Store build, which has its own App Store update path.
#if !DISTRIBUTION_MAS

// MARK: - Install channel

/// How this copy of OpenBurnBar was obtained. Resolved once at launch by
/// `UpdateChannelResolver`; it decides what "stay current" means and which
/// action the update banner offers.
enum UpdateChannel: String, Sendable, Equatable {
    /// Notarized direct-download DMG installed in `/Applications`. Supports the
    /// full one-click download → verify → install → relaunch flow.
    case dmg
    /// Installed via the Homebrew cask. We never replace the bundle ourselves
    /// (that would desync the Caskroom); the banner points at `brew upgrade`.
    case homebrew
    /// Built from a git checkout. "Update" means pulling + rebuilding; the
    /// banner shows how far behind the tracked branch the build is.
    case source
    /// Anything we don't recognize (e.g. a loose build outside `/Applications`
    /// with no git root). The updater stays silent.
    case unknown
}

/// Pure resolver so channel detection is unit-testable without touching the
/// real bundle or filesystem. `DirectDownloadUpdateChecker` calls
/// `resolveFromEnvironment()`; tests call `resolve(...)` with injected inputs.
enum UpdateChannelResolver {
    /// Filesystem receipts a Homebrew cask install leaves behind (Apple Silicon
    /// and Intel prefixes). Presence is checked directly so we never depend on
    /// `brew` being on a GUI app's minimal PATH.
    static let caskroomReceiptPaths = [
        "/opt/homebrew/Caskroom/openburnbar",
        "/usr/local/Caskroom/openburnbar"
    ]

    static func resolve(
        buildChannelStamp: String?,
        sourceRootHasGit: Bool,
        isInstalledInApplications: Bool,
        hasCaskroomReceipt: Bool
    ) -> UpdateChannel {
        if buildChannelStamp == "source", sourceRootHasGit {
            return .source
        }
        if isInstalledInApplications {
            return hasCaskroomReceipt ? .homebrew : .dmg
        }
        return .unknown
    }

    /// Resolves the channel from the running bundle + filesystem.
    static func resolveFromEnvironment(bundle: Bundle = .main) -> UpdateChannel {
        let fileManager = FileManager.default
        let stamp = bundle.object(forInfoDictionaryKey: "OpenBurnBarBuildChannel") as? String
        let sourceRoot = bundle.object(forInfoDictionaryKey: "OpenBurnBarSourceRoot") as? String
        let sourceRootHasGit: Bool = {
            guard let sourceRoot, !sourceRoot.isEmpty else { return false }
            return fileManager.fileExists(atPath: sourceRoot + "/.git")
        }()

        let bundlePath = bundle.bundleURL.standardizedFileURL.path
        let userApplications = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/OpenBurnBar.app").standardizedFileURL.path
        let isInstalledInApplications =
            bundlePath == "/Applications/OpenBurnBar.app" || bundlePath == userApplications

        let hasCaskroomReceipt = caskroomReceiptPaths.contains { fileManager.fileExists(atPath: $0) }

        return resolve(
            buildChannelStamp: stamp,
            sourceRootHasGit: sourceRootHasGit,
            isInstalledInApplications: isInstalledInApplications,
            hasCaskroomReceipt: hasCaskroomReceipt
        )
    }
}

// MARK: - Source-build status

/// How far a source/git build is behind its tracked branch, from the GitHub
/// `compare` API. `behindBy == 0` means up to date.
struct SourceUpdateStatus: Equatable, Sendable {
    let behindBy: Int
    let defaultBranch: String
    let currentSHA: String
    let compareURL: URL?
}

// MARK: - Offer

/// A concrete available update, tagged by the channel that produced it.
enum UpdateOffer: Equatable, Sendable {
    case directDMG(DirectDownloadRelease)
    case homebrew(version: String)
    case source(SourceUpdateStatus)

    /// Short human label for the version/delta, shown in the banner's pill.
    var pillText: String {
        switch self {
        case let .directDMG(release):
            return release.version
        case let .homebrew(version):
            return version
        case let .source(status):
            return status.behindBy == 1 ? "1 commit" : "\(status.behindBy) commits"
        }
    }
}

// MARK: - Phase

/// The single source of truth the banner renders from. Drives every surface
/// (popover, dashboard, settings) and the menu-bar badge.
enum UpdatePhase: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(UpdateOffer)
    case downloading(progress: Double)
    case verifying
    case installing
    case relaunching
    case failed(message: String)

    /// True when an update exists or is being applied — the banner is visible
    /// and the menu-bar badge dot is shown.
    var isActionable: Bool {
        switch self {
        case .idle, .checking, .upToDate:
            return false
        case .available, .downloading, .verifying, .installing, .relaunching, .failed:
            return true
        }
    }

    /// The pending offer, if any (so views can read the version without
    /// unwrapping the phase everywhere).
    var offer: UpdateOffer? {
        if case let .available(offer) = self { return offer }
        return nil
    }
}

#endif
