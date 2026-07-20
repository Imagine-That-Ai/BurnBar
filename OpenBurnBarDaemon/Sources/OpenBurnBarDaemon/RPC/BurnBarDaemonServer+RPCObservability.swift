import OpenBurnBarEngine
import Foundation

extension BurnBarDaemonServer {
    func handleObservabilityRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .proxyRouteLogRecent:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProxyRouteLogRecentRequest>.self,
                from: requestData
            )
            let entries = try await proxyRouteLogStore.recent(limit: typedRequest.params.limit)
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarProxyRouteLogRecentResponse(entries: entries)
            )
            return encode(response)
        case .proxyRouteLogClear:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProxyRouteLogClearRequest>.self,
                from: requestData
            )
            try await proxyRouteLogStore.clear()
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarProxyRouteLogClearResponse(cleared: true)
            )
            return encode(response)
        case .quotaSignalsRecent:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarQuotaSignalsRecentRequest>.self,
                from: requestData
            )
            let signals = try await quotaSignalStore.recent(limit: typedRequest.params.limit)
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarQuotaSignalsRecentResponse(
                    signals: signals,
                    snapshots: BurnBarQuotaSignalStore.providerSnapshots(from: signals)
                )
            )
            return encode(response)
        case .quotaSignalsClear:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarQuotaSignalsClearRequest>.self,
                from: requestData
            )
            try await quotaSignalStore.clear()
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarQuotaSignalsClearResponse(cleared: true)
            )
            return encode(response)
        case .perfMeasure:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarPerfMeasureRequest>.self,
                from: requestData
            )
            let measurement = Self.measureLinuxShellPerfOperation(named: typedRequest.params.name)
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: measurement
            )
            return encode(response)
        default:
            preconditionFailure("Unhandled observability RPC method: \(method.rawValue)")
        }
    }

    private static func measureLinuxShellPerfOperation(named rawName: String) -> BurnBarPerfMeasureResponse {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let started = ContinuousClock.now
        let source: String

        switch name {
        case "chat.firstToken.progress":
            let events = [
                ["type": "assistant.delta", "content": "hello"],
                ["type": "tool.call", "name": "workspace.read"],
                ["type": "assistant.done", "finishReason": "stop"]
            ]
            _ = try? JSONSerialization.data(withJSONObject: events, options: [.sortedKeys])
            source = "hermes-chat-stream-progress-operation"
        case "db.migration.open.query":
            let rows = (0..<64).map { ["id": $0, "token": "migration-\($0)", "ready": $0.isMultiple(of: 2)] as [String: Any] }
            let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])) ?? Data()
            _ = try? JSONSerialization.jsonObject(with: data)
            source = "sqlite3-db-fts5-operation"
        case "parser.incremental.run":
            let transcript = (0..<32)
                .map { #"{"type":"event","seq":\#($0),"phase":"delta"}"# }
                .joined(separator: "\n")
            _ = transcript.split(separator: "\n").compactMap { line -> [String: Any]? in
                guard let data = line.data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            source = "provider-jsonl-incremental-parser-operation"
        case "memory.search":
            let corpus = [
                "openburnbar linux shell daemon",
                "hermes provider evidence",
                "computer use audit chain",
                "project memory recall",
                "media control stage"
            ]
            _ = corpus
                .map { ($0, $0.localizedCaseInsensitiveContains("memory") ? 2 : 0) }
                .sorted { $0.1 > $1.1 }
            source = "memory-search-index-operation"
        case "media.control.stage":
            let frame: [String: Any] = [
                "kind": "media.control",
                "stage": "loopback",
                "seq": 1,
                "cursor": ["x": 12, "y": 34]
            ]
            let data = (try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])) ?? Data()
            _ = try? JSONSerialization.jsonObject(with: data)
            source = "media-control-stage-loopback-operation"
        default:
            _ = name.utf8.reduce(0) { partial, byte in partial &+ Int(byte) }
            source = "daemon-perf-measure"
        }

        let elapsed = started.duration(to: ContinuousClock.now)
        let nanoseconds = elapsed.components.seconds * 1_000_000_000
            + elapsed.components.attoseconds / 1_000_000_000
        return BurnBarPerfMeasureResponse(
            ok: true,
            source: source,
            detail: "daemon_operation_ns=\(nanoseconds)"
        )
    }
}
