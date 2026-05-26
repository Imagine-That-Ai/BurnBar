#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import AppKit
import ApplicationServices
import AVFoundation
import OSLog
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Phase 14 — Mac side of `control.system.permission.request`. Mirrors
/// `PhoneControlReceiver`: validates the signed authority envelope,
/// rejects replays / stale timestamps / hash mismatches, then dispatches
/// the appropriate macOS API for the requested permission kind. After
/// dispatch the receiver emits a `requesting` status frame so the iOS
/// sheet flips to inflight state immediately, then defers to
/// `SystemPermissionMonitor` for the eventual granted / denied poll.
@MainActor
public final class SystemPermissionReceiver {
    private static let log = Logger(subsystem: "com.openburnbar.app", category: "SystemPermissionConcierge")

    public typealias FrameSink = @MainActor @Sendable (HermesRealtimeRelayFrame) async throws -> Void

    private let validator: PhoneControlAuthorityValidator
    private let monitor: SystemPermissionMonitor
    private let denyFrameSink: FrameSink
    private let statusFrameSink: FrameSink
    private var seenClientIntentIds: Set<String> = []

    public init(
        validator: PhoneControlAuthorityValidator,
        monitor: SystemPermissionMonitor = .shared,
        denyFrameSink: @escaping FrameSink,
        statusFrameSink: @escaping FrameSink
    ) {
        self.validator = validator
        self.monitor = monitor
        self.denyFrameSink = denyFrameSink
        self.statusFrameSink = statusFrameSink
    }

    public func ingest(_ frame: HermesRealtimeRelayFrame) async {
        guard frame.type == .controlSystemPermissionRequest,
              let payload = frame.control,
              let request = payload.systemPermissionRequest else { return }

        // 1. Authority validation.
        do {
            _ = try validator.validate(
                envelope: request.authority,
                systemPermissionRequest: request,
                now: Date()
            )
        } catch let error as PhoneControlAuthorityValidator.ValidationError {
            await emitDeniedFrame(uid: frame.uid, connectionId: frame.connectionId, reason: deniedReason(for: error))
            return
        } catch {
            await emitDeniedFrame(uid: frame.uid, connectionId: frame.connectionId, reason: .signatureFailure)
            return
        }

        // 2. Replay guard on the client-intent id.
        let clientIntentId = request.clientIntentId
        guard !clientIntentId.isEmpty else {
            await emitDeniedFrame(uid: frame.uid, connectionId: frame.connectionId, reason: .signatureFailure)
            return
        }
        if seenClientIntentIds.contains(clientIntentId) {
            await emitDeniedFrame(uid: frame.uid, connectionId: frame.connectionId, reason: .counterReplay)
            return
        }
        seenClientIntentIds.insert(clientIntentId)

        // 3. Dispatch into the OS layer.
        let kind = SystemPermissionKind(wire: request.kind)
        Self.log.info("system_permission_request kind=\(kind.rawValue, privacy: .public) action=\(request.action.rawValue, privacy: .public)")

        if let toolCallId = request.originatingToolCallId {
            monitor.registerPendingTool(
                toolCallId: toolCallId,
                toolName: request.originatingToolName,
                category: nil,
                kind: kind,
                bundleId: request.bundleId
            )
        }
        if let bundleId = request.bundleId, kind == .automation {
            monitor.trackAutomation(bundleId: bundleId)
        }

        await monitor.emitRequesting(
            kind: kind,
            bundleId: request.bundleId,
            originatingToolCallId: request.originatingToolCallId,
            originatingToolName: request.originatingToolName,
            instructions: nil,
            failureCategory: nil
        )

        switch request.action {
        case .prompt, .promptAndOpenSettings:
            await runPrompt(kind: kind, bundleId: request.bundleId)
            if request.action == .promptAndOpenSettings {
                openDeepLink(for: kind)
            }
        case .openSettings:
            openDeepLink(for: kind)
        case .probeOnly:
            break
        case .retryFailedTool:
            // Mac records the retry intent — actual dispatch happens via
            // `SystemPermissionRetryDispatcher` when the monitor flips
            // the bucket to granted. Emit a status confirming the
            // intent was queued.
            await emitStatus(
                kind: kind,
                bundleId: request.bundleId,
                status: .requesting,
                uid: frame.uid,
                connectionId: frame.connectionId,
                originatingToolCallId: request.originatingToolCallId,
                originatingToolName: request.originatingToolName,
                instructions: "Queued for retry once permission lands."
            )
        }
    }

    private func runPrompt(kind: SystemPermissionKind, bundleId: String?) async {
        switch kind {
        case .screenRecording:
            #if canImport(CoreGraphics)
            _ = CGRequestScreenCaptureAccess()
            #endif
        case .accessibility:
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options)
        case .camera:
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                AVCaptureDevice.requestAccess(for: .video) { _ in cont.resume() }
            }
        case .microphone:
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { _ in cont.resume() }
            }
        case .fullDiskAccess:
            // No programmatic prompt — fall through to deep-link.
            break
        case .automation:
            guard let bundleId, !bundleId.isEmpty else { break }
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
            _ = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
        }
    }

    private func openDeepLink(for kind: SystemPermissionKind) {
        guard let urlString = kind.systemSettingsDeepLink,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func emitDeniedFrame(
        uid: String,
        connectionId: String,
        reason: HermesRealtimeRelayControlDenied.Reason,
        detail: String? = nil
    ) async {
        let payload = HermesRealtimeRelayControlPayload(
            streamClass: "control.system.permission",
            denied: HermesRealtimeRelayControlDenied(reason: reason, detail: detail)
        )
        let frame = HermesRealtimeRelayFrame(
            type: .controlDenied,
            uid: uid,
            connectionId: connectionId,
            control: payload
        )
        try? await denyFrameSink(frame)
    }

    private func emitStatus(
        kind: SystemPermissionKind,
        bundleId: String?,
        status: SystemPermissionStatus,
        uid: String,
        connectionId: String,
        originatingToolCallId: String?,
        originatingToolName: String?,
        instructions: String?
    ) async {
        let wireStatus = HermesRealtimeRelaySystemPermissionStatus(
            kind: kind.wire,
            bundleId: bundleId,
            status: status.wire,
            originatingToolCallId: originatingToolCallId,
            originatingToolName: originatingToolName,
            deepLink: kind.systemSettingsDeepLink,
            instructions: instructions
        )
        let frame = HermesRealtimeRelayFrame(
            type: .controlSystemPermissionStatus,
            uid: uid,
            connectionId: connectionId,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.system.permission",
                systemPermissionStatus: wireStatus
            )
        )
        try? await statusFrameSink(frame)
    }

    private func deniedReason(for error: PhoneControlAuthorityValidator.ValidationError) -> HermesRealtimeRelayControlDenied.Reason {
        switch error {
        case .signatureFailed, .missingPeerPubKey: return .signatureFailure
        case .counterReplay: return .counterReplay
        case .staleTimestamp: return .staleTimestamp
        case .intentHashMismatch: return .signatureFailure
        }
    }
}
#endif
