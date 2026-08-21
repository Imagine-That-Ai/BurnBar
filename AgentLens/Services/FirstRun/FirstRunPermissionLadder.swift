#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import OpenBurnBarComputerUseCore

/// The one door between BurnBar and a macOS permission dialog.
///
/// The rule this enforces, from `docs/PRODUCT_FOCUS_AND_ONBOARDING_PLAN.md` and
/// `docs/product-focus/ONBOARDING_SPEC.md` §6: **nothing is asked before the value it
/// buys, and BurnBar always speaks first.** macOS's wording for these grants is the
/// harshest possible narration -- "wants to record this computer's screen", "wants to
/// control this computer" -- and a user who meets that sentence cold, before the app
/// has said anything, reasonably concludes they installed spyware.
///
/// So every user-facing request goes through ``request(_:bundleId:)``, which shows
/// BurnBar's own explanation first and only reaches the OS if the user chooses to
/// continue. Routing this through one object is what makes the invariant testable
/// (see `FirstRunPermissionLadderTests`) instead of a convention the next person to
/// add a permission surface silently breaks.
///
/// Two paths deliberately do *not* come through here:
/// - `SystemPermissionReceiver` (phone-initiated). The phone has already shown its own
///   explanation; a second modal on a Mac the user is not sitting at would block a
///   remote flow with a dialog nobody is there to answer.
/// - The capture pipelines (`ScreenCapturePipeline`, `CameraCapturePipeline`). They have
///   no window context to present from, and by the time they run the user has already
///   started a call or a session.
@MainActor
final class FirstRunPermissionLadder {
    /// Deliberately not a singleton. `budgets/singleton-baseline.json` is a shrink-only
    /// ratchet, and its failure message is the right instruction: "use runtime-context
    /// injection instead of adding global shared access". The process-wide instance every
    /// surface shares lives on `AppCommandRouter`, which is already the app-wide hub
    /// views reach for actions like this.

    /// Shows BurnBar's own explanation. Returns `true` when the user chose to continue
    /// to the macOS dialog. Injected so tests can drive it without a window.
    typealias Explainer = @MainActor (SystemPermissionKind, String?) async -> Bool

    /// Fires the actual macOS prompt for a kind. Injected so tests can assert it is
    /// never reached without a preceding explanation.
    typealias Prompter = @MainActor (SystemPermissionKind, String?) async -> Void

    /// Reports the current grant state, so an already-granted kind never re-explains.
    typealias StatusReader = @MainActor (SystemPermissionKind, String?) -> SystemPermissionStatus?

    var explainer: Explainer?
    var prompter: Prompter
    var statusReader: StatusReader

    /// Kinds already explained in this process. A user who declines and later clicks the
    /// same button gets straight to the OS dialog rather than reading the same card twice.
    private var explained: Set<String> = []

    init(
        prompter: @escaping Prompter = FirstRunPermissionLadder.livePrompter,
        statusReader: @escaping StatusReader = FirstRunPermissionLadder.liveStatusReader
    ) {
        self.prompter = prompter
        self.statusReader = statusReader
    }

    /// Explain, then (only with the user's agreement) ask macOS.
    ///
    /// - Returns: `true` when the OS prompt was actually shown.
    @discardableResult
    func request(_ kind: SystemPermissionKind, bundleId: String? = nil) async -> Bool {
        // Already granted: asking again would be noise, and macOS would not show a
        // dialog anyway.
        if statusReader(kind, bundleId) == .granted { return false }

        let token = Self.token(kind: kind, bundleId: bundleId)
        if !explained.contains(token) {
            guard let explainer else {
                // Fail closed. An unwired explainer must not silently degrade into the
                // old behaviour of firing OS dialogs unannounced -- that is the exact
                // regression this type exists to prevent.
                AppLogger.chat.error(
                    "permission_ladder_missing_explainer",
                    metadata: ["kind": kind.rawValue]
                )
                return false
            }
            let shouldContinue = await explainer(kind, bundleId)
            explained.insert(token)
            guard shouldContinue else { return false }
        }

        await prompter(kind, bundleId)
        return true
    }

    /// Test/reset hook: forget which kinds have been explained.
    func resetExplainedForTesting() {
        explained.removeAll()
    }

    private static func token(kind: SystemPermissionKind, bundleId: String?) -> String {
        bundleId.map { "\(kind.rawValue)|\($0)" } ?? kind.rawValue
    }

    // MARK: - Live wiring

    private static let liveStatusReader: StatusReader = { kind, bundleId in
        let key = SystemPermissionMonitor.Snapshot(
            kind: kind,
            bundleId: bundleId,
            status: .unknown
        ).key
        return SystemPermissionMonitor.shared.snapshots[key]?.status
    }

    private static let livePrompter: Prompter = { kind, bundleId in
        await SystemPermissionPromptRunner.run(kind: kind, bundleId: bundleId)
    }
}
#endif
