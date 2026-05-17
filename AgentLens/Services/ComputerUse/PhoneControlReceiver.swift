#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import CryptoKit
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Mac side of the Phase 12 `control.input` stream. Receives a
/// `HermesRealtimeRelayFrame` (already classified as
/// `.controlInputIntent` by `IrohRelayRequestHandler`'s
/// `controlDispatcher`), validates the embedded authority envelope via
/// `ComputerUsePhoneControlSigner`, translates the normalized intent
/// into a typed `ComputerUseAction`, and dispatches via the run
/// coordinator.
///
/// On any validation failure the receiver writes a `control.denied`
/// frame back over the same connection so the iOS overlay knows the
/// intent did not execute and surfaces the deny reason to the user.
public final class PhoneControlReceiver: @unchecked Sendable {
    public typealias DispatchHandler = @Sendable (
        _ action: ComputerUseAction,
        _ sessionId: ComputerUseSessionID
    ) async -> Void

    public typealias FrameSink = @Sendable (HermesRealtimeRelayFrame) async throws -> Void

    public typealias DisplayBoundsProvider = @Sendable () -> [MacInputCore.DisplayBounds]

    public let sessionId: ComputerUseSessionID
    public let validator: PhoneControlAuthorityValidator
    public let signer: ComputerUsePhoneControlSigner
    private let dispatchHandler: DispatchHandler
    private let denyFrameSink: FrameSink
    private let displayBoundsProvider: DisplayBoundsProvider

    public init(
        sessionId: ComputerUseSessionID,
        validator: PhoneControlAuthorityValidator,
        signer: ComputerUsePhoneControlSigner = ComputerUsePhoneControlSigner(),
        displayBoundsProvider: @escaping DisplayBoundsProvider,
        dispatchHandler: @escaping DispatchHandler,
        denyFrameSink: @escaping FrameSink
    ) {
        self.sessionId = sessionId
        self.validator = validator
        self.signer = signer
        self.dispatchHandler = dispatchHandler
        self.denyFrameSink = denyFrameSink
        self.displayBoundsProvider = displayBoundsProvider
    }

    /// Entry point bound to the `ControlFrameDispatcher` closure on
    /// `IrohRelayRequestHandler`. The handler ignores frames whose
    /// `control.inputIntent` is absent.
    public func ingest(_ frame: HermesRealtimeRelayFrame) async {
        guard frame.type == .controlInputIntent,
              let payload = frame.control,
              let intent = payload.inputIntent else { return }

        // Validate the authority envelope.
        do {
            _ = try validator.validate(
                envelope: intent.authority,
                intent: intent,
                now: Date()
            )
        } catch let error as PhoneControlAuthorityValidator.ValidationError {
            await emitDeniedFrame(reason: deniedReason(for: error), uid: frame.uid, connectionId: frame.connectionId)
            return
        } catch {
            await emitDeniedFrame(reason: .signatureFailure, uid: frame.uid, connectionId: frame.connectionId)
            return
        }

        // Translate the normalized intent into a typed
        // `ComputerUseAction`. Panic intents bypass dispatch and
        // signal the caller-supplied dispatcher to start the halt
        // path.
        switch intent.kind {
        case .panic:
            // Forward as a synthetic action; the coordinator interprets
            // it as a panic halt directly.
            let action: ComputerUseAction = .phoneIntent(PhoneControlIntent(kind: .panic))
            await dispatchHandler(action, sessionId)
            return
        case .tap, .scroll, .dragStart, .dragMove, .dragEnd:
            guard let (displayX, displayY) = denormalize(intent.normalizedX, intent.normalizedY) else {
                await emitDeniedFrame(reason: .signatureFailure, uid: frame.uid, connectionId: frame.connectionId)
                return
            }
            let endpoint = denormalize(intent.normalizedX2, intent.normalizedY2)
            let macAction = MacInputAction(
                kind: macInputKind(for: intent.kind),
                displayX: displayX,
                displayY: displayY,
                dragEndX: endpoint?.0,
                dragEndY: endpoint?.1
            )
            await dispatchHandler(.macInput(macAction), sessionId)
        case .type:
            await dispatchHandler(
                .macInput(MacInputAction(kind: .type, text: intent.text)),
                sessionId
            )
        case .shortcut:
            await dispatchHandler(
                .macInput(MacInputAction(kind: .shortcut, key: intent.key, modifiers: intent.modifiers)),
                sessionId
            )
        }
    }

    private func macInputKind(for kind: HermesRealtimeRelayInputIntent.Kind) -> MacInputAction.Kind {
        switch kind {
        case .tap: return .click
        case .dragStart, .dragMove, .dragEnd: return .dragDrop
        case .type: return .type
        case .shortcut: return .shortcut
        case .scroll: return .scroll
        case .panic: return .click  // unreachable; panic short-circuits above
        }
    }

    private func denormalize(_ nx: Double?, _ ny: Double?) -> (Int, Int)? {
        guard let nx, let ny else { return nil }
        let displays = displayBoundsProvider()
        guard let point = MacInputCore.denormalize(normalizedX: nx, normalizedY: ny, in: displays.first) else {
            return nil
        }
        return (point.x, point.y)
    }

    private func emitDeniedFrame(
        reason: HermesRealtimeRelayControlDenied.Reason,
        uid: String,
        connectionId: String
    ) async {
        let payload = HermesRealtimeRelayControlPayload(
            streamClass: "control.input",
            denied: HermesRealtimeRelayControlDenied(reason: reason)
        )
        let frame = HermesRealtimeRelayFrame(
            type: .controlDenied,
            uid: uid,
            connectionId: connectionId,
            control: payload
        )
        try? await denyFrameSink(frame)
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
