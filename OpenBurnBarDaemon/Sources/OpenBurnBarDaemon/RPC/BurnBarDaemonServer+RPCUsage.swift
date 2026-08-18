import OpenBurnBarEngine
import OpenBurnBarInsights
import Foundation

extension BurnBarDaemonServer {
    func handleUsageRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .usageRecent:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarRecentUsageRequest>.self,
                from: requestData
            )
            let usage = try await usageRecorder.recentUsage(limit: typedRequest.params.limit)
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarRecentUsageResponse(usage: usage)
            )
            return encode(response)
        case .usageProjection:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarUsageProjectionRequest>.self,
                from: requestData
            )
            let projection = try await usageRecorder.projection()
            return encode(BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarUsageProjectionResponse(projection: projection)
            ))
        case .usageRecount:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarUsageRecountRequest>.self,
                from: requestData
            )
            let projection = try await usageRecorder.recountProjection()
            return encode(BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarUsageProjectionResponse(projection: projection)
            ))
        case .usageHistory:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarActivityHistoryRequest>.self,
                from: requestData
            )
            let limit = min(max(typedRequest.params.limit, 1), 500)
            let result: BurnBarActivityHistoryResponse
            if let resumeService {
                let history = try resumeService.activityHistory(limit: limit)
                if history.historyComplete {
                    result = BurnBarActivityHistoryResponse(
                        sessions: try await usageRecorder.enrichingActivityHistory(
                            history.sessions
                        ),
                        nextCursor: history.nextCursor,
                        historyComplete: history.historyComplete,
                        historyLimit: history.historyLimit,
                        totalCount: history.totalCount
                    )
                } else {
                    result = history
                }
            } else {
                result = BurnBarActivityHistoryResponse(
                    sessions: [],
                    nextCursor: nil,
                    historyComplete: false,
                    historyLimit: limit,
                    totalCount: 0
                )
            }
            return encode(BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            ))
        case .usageRecord:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarRecordUsageRequest>.self,
                from: requestData
            )
            let recordResult: BurnBarUsageRecordResult
            do {
                recordResult = try await usageRecorder.record(
                    typedRequest.params.event,
                    idempotencyKey: typedRequest.params.idempotencyKey
                )
            } catch let error as BurnBarUsageValidationError {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.invalidParams,
                    message: error.localizedDescription
                )
            }
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarRecordUsageResponse(
                    idempotencyKey: recordResult.record.idempotencyKey,
                    inserted: recordResult.inserted,
                    event: recordResult.record.event
                )
            )
            return encode(response)
        case .usageInsights:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarUsageInsightsRequest>.self,
                from: requestData
            )
            let response = try await usageInsightsResponse(typedRequest.params)
            return encode(BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: response
            ))
        default:
            preconditionFailure("Unhandled usage RPC method: \(method.rawValue)")
        }
    }

    private func usageInsightsResponse(
        _ request: BurnBarUsageInsightsRequest
    ) async throws -> BurnBarUsageInsightsResponse {
        let limit = min(max(request.limit, 1), 2_000)
        let seconds = request.windowSeconds
        guard seconds.isFinite, seconds >= 60, seconds <= 366 * 24 * 60 * 60 else {
            throw BurnBarUsageInsightsError.invalidWindow
        }
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 512 else {
            throw BurnBarUsageInsightsError.invalidPrompt
        }

        let end = Date()
        let start = end.addingTimeInterval(-seconds)
        let window = DateInterval(start: start, end: end)
        let records = try await usageRecorder.records(in: window, limit: limit)

        var usages: [InsightUsageRow] = []
        var sessionsByID: [String: InsightSessionRow] = [:]
        for record in records {
            let event = record.event
            let sessionID = event.sessionID
                ?? event.runID?.rawValue
                ?? "usage-\(event.providerID)-\(event.recordedAt.timeIntervalSince1970)"
            let totalTokens = max(0, event.inputTokens)
                + max(0, event.outputTokens)
                + max(0, event.reasoningTokens)
            usages.append(InsightUsageRow(
                sessionID: sessionID,
                provider: event.providerID,
                model: event.modelID,
                projectName: event.projectName,
                startTime: event.recordedAt,
                endTime: event.recordedAt,
                inputTokens: max(0, event.inputTokens),
                outputTokens: max(0, event.outputTokens),
                reasoningTokens: max(0, event.reasoningTokens),
                cacheReadTokens: max(0, event.cacheReadTokens),
                cacheCreationTokens: max(0, event.cacheCreationTokens),
                totalTokens: totalTokens,
                costUSD: max(0, event.cost)
            ))
            if sessionsByID[sessionID] == nil {
                sessionsByID[sessionID] = InsightSessionRow(
                    sessionID: sessionID,
                    provider: event.providerID,
                    projectName: event.projectName,
                    startTime: event.recordedAt,
                    endTime: event.recordedAt,
                    messageCount: 1,
                    inferredTaskTitle: nil,
                    keyTools: [],
                    keyCommands: [],
                    keyFiles: []
                )
            }
        }

        let snapshot = InsightDataSnapshot(
            window: window,
            generatedAt: end,
            usages: usages,
            sessions: Array(sessionsByID.values).sorted { $0.sessionID < $1.sessionID }
        )
        let filter = InsightFilter(window: .custom(start: start, end: end))
        let digest = try InsightDigestBuilder().build(from: snapshot, filter: filter)
        let digestBytes = try JSONEncoder.insightEncoder.encode(digest)
        let budget = InsightContextBudgetReport(
            encodedBytes: digestBytes.count,
            estimatedPromptTokens: max(1, digestBytes.count / 4),
            includedDataSources: ["daemon.usage.ledger"],
            truncatedDataSources: records.count < limit ? [] : ["daemon.usage.ledger"],
            truncationSummary: records.count < limit
                ? "No usage rows were omitted."
                : "Usage rows were bounded by the request limit."
        )
        let evidence = usages.prefix(12).map { usage in
            InsightEvidence(
                id: "usage-\(usage.sessionID)-\(usage.startTime.timeIntervalSince1970)",
                citation: .init(
                    kind: .session(id: usage.sessionID, provider: usage.provider),
                    label: "\(usage.provider) session"
                ),
                source: "daemon.usage.ledger",
                summary: "\(usage.provider)/\(usage.model) · \(usage.totalTokens) tokens",
                numericValue: usage.costUSD
            )
        }
        let context = InsightAnalysisContext(
            digest: digest,
            evidenceIndex: evidence,
            budgetReport: budget
        )
        let analysisRequest = InsightAnalysisRequest(
            prompt: prompt,
            context: context,
            selectedModel: InsightModelTag(
                providerKey: "local-rules",
                modelID: "linux-usage-rules-v1",
                displayName: "Linux local rules",
                egressTier: .localOnly,
                stampedAt: end
            ),
            instruction: .defaultBrief,
            allowDeepTranscriptAnalysis: false,
            maxGeneratedWidgets: 8
        )
        let analysis = try await RuleBasedInsightAnalysisEngine(platform: .linux).analyze(analysisRequest)
        return BurnBarUsageInsightsResponse(
            usage: records.map(\.event),
            analysis: analysis,
            sourceID: "daemon.usage.ledger",
            sourceLabel: "Linux daemon usage ledger · local rules"
        )
    }
}

private enum BurnBarUsageInsightsError: Error {
    case invalidWindow
    case invalidPrompt
}

private extension JSONEncoder {
    static var insightEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
