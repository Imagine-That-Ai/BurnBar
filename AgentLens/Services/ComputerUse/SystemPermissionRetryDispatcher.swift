#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import OSLog
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Phase 14 — When `SystemPermissionMonitor` flips a TCC bucket to
/// `.granted` and a pending tool call was bound to that bucket, this
/// dispatcher asks Hermes (or any tool runner) to re-execute the failed
/// call. The actual re-exec strategy is host-specific:
///
///  * Embedded Hermes: the runner supplies a `liveRetry` closure that
///    talks to the in-process tool dispatcher.
///  * External Hermes: the runner supplies a `synthesizedRetry` closure
///    that emits a user-perspective sentinel ("Permission added on your
///    Mac. Retry the previous tool call.") through the same chat
///    pipeline so the model picks up the retry on its next turn.
///
/// The dispatcher is platform-agnostic — both strategies live behind
/// the same async closure surface. Callers attach their retry strategy
/// at startup; the daemon attaches the embedded variant when Hermes
/// runs in-process and the synthesized variant otherwise.
@MainActor
public final class SystemPermissionRetryDispatcher {
    public struct Retry: Sendable {
        public let toolCallId: String
        public let toolName: String?
        public let kind: SystemPermissionKind
        public let bundleId: String?

        public init(toolCallId: String, toolName: String?, kind: SystemPermissionKind, bundleId: String?) {
            self.toolCallId = toolCallId
            self.toolName = toolName
            self.kind = kind
            self.bundleId = bundleId
        }
    }

    public typealias RetryStrategy = @MainActor @Sendable (Retry) async -> Void

    private static let log = Logger(subsystem: "com.openburnbar.app", category: "SystemPermissionConcierge")

    public static let shared = SystemPermissionRetryDispatcher()

    private var strategies: [RetryStrategy] = []
    private let monitor: SystemPermissionMonitor

    public init(monitor: SystemPermissionMonitor = .shared) {
        self.monitor = monitor
    }

    public func register(strategy: @escaping RetryStrategy) {
        strategies.append(strategy)
    }

    public func observe(statusFrame frame: HermesRealtimeRelayFrame) async {
        guard frame.type == .controlSystemPermissionStatus,
              let status = frame.control?.systemPermissionStatus,
              status.status == .granted,
              let toolCallId = status.originatingToolCallId else { return }
        let kind = SystemPermissionKind(wire: status.kind)
        let retry = Retry(
            toolCallId: toolCallId,
            toolName: status.originatingToolName,
            kind: kind,
            bundleId: status.bundleId
        )
        Self.log.info("system_permission_retry_dispatch tool=\(retry.toolName ?? "?", privacy: .public) kind=\(retry.kind.rawValue, privacy: .public)")
        for strategy in strategies {
            await strategy(retry)
        }
        monitor.clearPendingTool(for: kind, bundleId: status.bundleId)
    }
}
#endif
