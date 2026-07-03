import Foundation
import OpenBurnBarCore

extension BurnBarDaemonServer {
    func handleSubscriptionRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .subscriptionStart:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarSubscriptionStartRequest>.self,
                from: requestData
            )
            let response = try await startSubscription(typedRequest.params)
            return encode(BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: response
            ))
        case .subscriptionResume:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarSubscriptionResumeRequest>.self,
                from: requestData
            )
            let response = try await resumeSubscription(typedRequest.params)
            return encode(BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: response
            ))
        default:
            preconditionFailure("Unhandled subscription RPC method: \(method.rawValue)")
        }
    }

    private func startSubscription(_ request: BurnBarSubscriptionStartRequest) async throws -> BurnBarSubscriptionResponse {
        let subscriptionID = "sub_\(UUID().uuidString)"
        let seq = max((request.resumeAfterSeq ?? 0) + 1, 1)
        let snapshot = try await subscriptionEvent(
            seq: seq,
            topic: request.topic,
            runID: request.runID,
            clientID: request.clientID,
            kind: "snapshot"
        )
        subscriptionCursors[subscriptionID] = seq
        return BurnBarSubscriptionResponse(
            subscriptionID: subscriptionID,
            topic: request.topic,
            firstSnapshot: snapshot,
            events: [snapshot],
            nextSeq: seq,
            disconnected: true,
            terminalDelivered: snapshot.terminal,
            recoveredAfterRestart: false,
            degradation: longPollDegradation(recoveredAfterRestart: false)
        )
    }

    private func resumeSubscription(_ request: BurnBarSubscriptionResumeRequest) async throws -> BurnBarSubscriptionResponse {
        let previousSeq = subscriptionCursors[request.subscriptionID]
        let recoveredAfterRestart = previousSeq == nil
        let nextSeq = max((previousSeq ?? request.afterSeq), request.afterSeq) + 1
        let snapshot = try await subscriptionEvent(
            seq: nextSeq,
            topic: request.topic,
            runID: request.runID,
            clientID: request.clientID,
            kind: recoveredAfterRestart ? "snapshot.reacquired" : "update"
        )
        subscriptionCursors[request.subscriptionID] = nextSeq
        return BurnBarSubscriptionResponse(
            subscriptionID: request.subscriptionID,
            topic: request.topic,
            firstSnapshot: snapshot,
            events: [snapshot],
            nextSeq: nextSeq,
            disconnected: true,
            terminalDelivered: snapshot.terminal,
            recoveredAfterRestart: recoveredAfterRestart,
            degradation: longPollDegradation(recoveredAfterRestart: recoveredAfterRestart)
        )
    }

    private func subscriptionEvent(
        seq: UInt64,
        topic: BurnBarSubscriptionTopic,
        runID: BurnBarRunID?,
        clientID: BurnBarClientID?,
        kind: String
    ) async throws -> BurnBarSubscriptionEvent {
        switch topic {
        case .daemonHealth:
            return BurnBarSubscriptionEvent(
                seq: seq,
                topic: topic,
                kind: kind,
                payload: try BurnBarJSONValue.fromEncodable(healthResponse()),
                terminal: false
            )
        case .run:
            guard let runID, let clientID else {
                throw BurnBarSubscriptionError.missingRunScope
            }
            let detail = try await runService.getRun(BurnBarRunGetRequest(runID: runID, clientID: clientID))
            let terminal = detail.run?.phase.isTerminal ?? false
            return BurnBarSubscriptionEvent(
                seq: seq,
                topic: topic,
                kind: kind,
                payload: try BurnBarJSONValue.fromEncodable(detail),
                terminal: terminal
            )
        }
    }

    private func longPollDegradation(recoveredAfterRestart: Bool) -> BurnBarSubscriptionDegradation {
        BurnBarSubscriptionDegradation(
            code: recoveredAfterRestart ? "long_poll_reacquire_after_restart" : "long_poll_single_response",
            message: "Linux AF_UNIX subscriptions use the BurnBarRPC newline-framed envelope as a long-poll response; clients resume with subscription.resume and afterSeq.",
            parityLedgerRow: recoveredAfterRestart
                ? "subscription.resume reacquired a fresh snapshot after daemon restart; no terminal state is dropped because the response includes terminalDelivered."
                : "subscription.start returns the first snapshot plus cursor; backpressure is coalesce_latest with one buffered event."
        )
    }
}

private enum BurnBarSubscriptionError: Error, LocalizedError {
    case missingRunScope

    var errorDescription: String? {
        switch self {
        case .missingRunScope:
            return "Run subscriptions require runID and clientID."
        }
    }
}

private extension BurnBarRunPhase {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }
}
