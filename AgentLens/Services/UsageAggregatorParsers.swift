import Foundation
import OpenBurnBarCore

/// Shared warm-up for disk-cache-backed parsers.
///
/// The `OpenBurnBarCore.ParserDiskCacheStore` that each of these parsers owns is self-healing on
/// write (it re-creates the support directory with intermediates and logs via
/// `AppLogger.parser.silentFailure` if persistence fails). Eagerly preparing the
/// directory in the initializer is therefore a best-effort optimization that lets
/// the *first* cache write succeed without a directory-creation round trip.
///
/// The previous optional-try form of `prepareSupportDirectory(...)` swallowed
/// every failure totally silently. A failure here is recoverable (the
/// store self-heals later) but it should be **observable**: a persistent prep
/// failure usually signals a deeper filesystem fault (revoked sandbox access,
/// migration collision, a regular file occupying the support path) that we want
/// surfaced in logs the moment it happens, not only when the first write trips it.
///
/// This does NOT fail closed — a parser must remain constructible even when its
/// scratch directory is unavailable, and it degrades gracefully by re-parsing.
enum ParserSupportDirectoryWarmUp {
    /// Prepare the OpenBurnBar support directory, logging (never throwing /
    /// crashing) on failure.
    ///
    /// - Returns: `true` when the directory is ready, `false` when preparation
    ///   failed (already logged). The boolean exists purely so the behavior is
    ///   testable; callers in initializers discard it.
    @discardableResult
    nonisolated static func prepare(
        fileManager: FileManager,
        appPaths: OpenBurnBarCore.OpenBurnBarAppPaths
    ) -> Bool {
        do {
            _ = try OpenBurnBarCore.OpenBurnBarMigration.prepareSupportDirectory(
                fileManager: fileManager,
                paths: appPaths
            )
            return true
        } catch {
            AppLogger.parser.error(
                "parser.supportDirectoryPrepFailed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            return false
        }
    }
}
