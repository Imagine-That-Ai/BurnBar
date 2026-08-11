import Foundation
import OpenBurnBarEngine

private enum BurnBarInboxAuthorityError: Error, LocalizedError {
    case invalid(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message):
            return message
        }
    }
}

extension BurnBarDaemonServer {
    /// AI Inbox RPCs.
    ///
    /// Reads are `observability`-scoped (the same posture as usage/insight
    /// reads: already-synthesized, already-redacted summaries plus
    /// reference-shaped evidence). Config writes and `run_now` are
    /// `config`-scoped because they change the egress posture, the spend
    /// ceiling, or immediately spend money.
    func handleInboxRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        request: BurnBarRPCRequestEnvelope,
        requestData: Data
    ) async throws -> Data {
        // Config reads force a retry so Settings → Retry can recover after a
        // transient lock or after the encryption key becomes readable.
        let forceRetry = method == .inboxConfigGet
        guard let inbox = ensureAIInboxBootstrapped(forceRetry: forceRetry) else {
            let message = aiInboxUnavailabilityReason
                ?? "The AI Inbox is not available. Configure OPENBURNBAR_INDEX_DATABASE_PATH and restart the daemon."
            return encodeErrorResponse(
                id: request.id,
                code: BurnBarRPCErrorCode.internalError,
                message: message
            )
        }

        switch method {
        case .inboxList:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxListRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: try await inbox.list(typedRequest.params)
                    )
                )
            } catch {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }

        case .inboxGet:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxGetRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: BurnBarInboxGetResponse(item: try await inbox.item(id: typedRequest.params.id))
                    )
                )
            } catch {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }

        case .inboxPresentationList:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxPresentationListRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: try await inbox.presentationList(typedRequest.params)
                    )
                )
            } catch {
                return encodeInboxStoreErrorResponse(id: typedRequest.id, error: error)
            }

        case .inboxPresentationGet:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxPresentationGetRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: BurnBarInboxPresentationGetResponse(
                            row: try await inbox.presentationRow(id: typedRequest.params.id)
                        )
                    )
                )
            } catch {
                return encodeInboxStoreErrorResponse(id: typedRequest.id, error: error)
            }

        case .inboxPresentationMutate:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxPresentationMutationRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: try await inbox.mutatePresentationState(typedRequest.params)
                    )
                )
            } catch {
                return encodeInboxStoreErrorResponse(id: typedRequest.id, error: error)
            }

        case .inboxPresentationMarkAllRead:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxPresentationMarkAllReadRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: try await inbox.markAllOpenPresentationItemsRead()
                    )
                )
            } catch {
                return encodeInboxStoreErrorResponse(id: typedRequest.id, error: error)
            }

        case .inboxRunsRecent:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxRunsRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: try await inbox.recentRuns(limit: typedRequest.params.limit)
                    )
                )
            } catch {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }

        case .inboxConfigGet:
            return encode(
                BurnBarRPCResponseEnvelope(id: request.id, result: await inbox.configuration())
            )

        case .inboxConfigUpdate:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxConfig>.self,
                from: requestData
            )
            // The service normalizes/clamps and returns what it actually stored,
            // so the caller can render the effective values rather than assume
            // its request was accepted verbatim.
            let stored = await inbox.updateConfiguration(typedRequest.params)
            return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: stored))

        case .inboxRunNow:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxRunNowRequest>.self,
                from: requestData
            )
            let response = await inbox.runNow(force: typedRequest.params.force)
            return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: response))

        // MARK: Founder Lens — threads

        case .inboxThreadGet:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxThreadGetRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: BurnBarInboxThreadGetResponse(
                            thread: try await inbox.thread(fingerprint: typedRequest.params.fingerprint)
                        )
                    )
                )
            } catch {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }

        case .inboxReply:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxReplyRequest>.self,
                from: requestData
            )
            // The service refuses internally (budget/egress/disabled) and says
            // why; refusals are results, not transport errors.
            let response = await inbox.reply(typedRequest.params)
            return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: response))

        // MARK: Founder Lens — plan ledger

        case .inboxPlansList:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxPlansListRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: try await inbox.plansList(typedRequest.params)
                    )
                )
            } catch {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }

        case .inboxPlansGet:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxPlanGetRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: try await inbox.planGet(typedRequest.params)
                    )
                )
            } catch {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }

        case .inboxPlansAccept:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxPlanAcceptRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: try await inbox.planAccept(typedRequest.params)
                    )
                )
            } catch {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }

        case .inboxPlansUpdateStep:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxPlanUpdateStepRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: try await inbox.planUpdateStep(typedRequest.params)
                    )
                )
            } catch {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }

        case .inboxPlansGrade:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxPlanGradeRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: try await inbox.planGrade(typedRequest.params)
                    )
                )
            } catch {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }

        case .inboxMemoryCandidateApprove:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxMemoryCandidateApproveRequest>.self,
                from: requestData
            )
            do {
                let result = try await approveInboxMemoryCandidate(
                    typedRequest.params,
                    inbox: inbox
                )
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: result))
            } catch {
                return encodeInboxAuthorityErrorResponse(id: typedRequest.id, error: error)
            }

        case .inboxPlansRememberStep:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxPlanRememberStepRequest>.self,
                from: requestData
            )
            do {
                let result = try await rememberInboxPlanStep(
                    typedRequest.params,
                    inbox: inbox
                )
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: result))
            } catch {
                return encodeInboxAuthorityErrorResponse(id: typedRequest.id, error: error)
            }

        case .inboxPlansCreateFollowup:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxPlanCreateFollowupRequest>.self,
                from: requestData
            )
            do {
                let result = try await createInboxPlanFollowup(
                    typedRequest.params,
                    inbox: inbox
                )
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: result))
            } catch {
                return encodeInboxAuthorityErrorResponse(id: typedRequest.id, error: error)
            }

        // MARK: Founder Lens — memory export

        case .inboxMemoryExport:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxMemoryExportRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: try await inbox.memoryExport(typedRequest.params)
                    )
                )
            } catch {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }

        default:
            preconditionFailure("Unhandled inbox RPC method: \(method.rawValue)")
        }
    }

    private func encodeInboxStoreErrorResponse(id: String, error: Error) -> Data {
        let code: Int
        if let storeError = error as? BurnBarAIInboxStoreError {
            switch storeError {
            case .itemNotFound, .invalidPresentationMutation:
                code = BurnBarRPCErrorCode.invalidParams
            case .sqlite, .closed:
                code = BurnBarRPCErrorCode.internalError
            }
        } else {
            code = BurnBarRPCErrorCode.internalError
        }
        return encodeErrorResponse(id: id, code: code, message: error.localizedDescription)
    }

    private func encodeInboxAuthorityErrorResponse(id: String, error: Error) -> Data {
        let code: Int
        switch error {
        case BurnBarInboxAuthorityError.invalid:
            code = BurnBarRPCErrorCode.invalidParams
        case BurnBarInboxAuthorityError.unavailable:
            code = BurnBarRPCErrorCode.internalError
        case let storeError as BurnBarProjectCodeMemoryStoreError:
            switch storeError {
            case .emptyText, .emptyQuery, .memoryNotFound, .invalidMemoryReviewStatus,
                 .projectPathUnavailable, .secretRejected:
                code = BurnBarRPCErrorCode.invalidParams
            case .databaseSnapshotUnavailable, .databaseSnapshotInvalidPath,
                 .databaseSnapshotTooLarge, .databaseSnapshotPermissions,
                 .databaseSnapshotFailed, .sqlite:
                code = BurnBarRPCErrorCode.internalError
            }
        case let storeError as BurnBarAIInboxStoreError:
            switch storeError {
            case .itemNotFound, .invalidPresentationMutation:
                code = BurnBarRPCErrorCode.invalidParams
            case .sqlite, .closed:
                code = BurnBarRPCErrorCode.internalError
            }
        case let missionError as BurnBarMissionControlError:
            switch missionError {
            case .projectNotFound, .invalidProjectIdentifier, .ambiguousProjectIdentifier,
                 .projectIdentityConflict, .projectDeleted, .followupNotFound:
                code = BurnBarRPCErrorCode.invalidParams
            case .questionNotFound, .missionNotFound, .missionNotApproved, .missionTerminal,
                 .enterprisePolicyBlocked, .performanceGuardrailExceeded,
                 .simulatorRunNotFound, .missingPayload, .executionReadinessFailed:
                code = BurnBarRPCErrorCode.internalError
            }
        default:
            code = BurnBarRPCErrorCode.internalError
        }
        return encodeErrorResponse(id: id, code: code, message: error.localizedDescription)
    }

    private func approveInboxMemoryCandidate(
        _ request: BurnBarInboxMemoryCandidateApproveRequest,
        inbox: BurnBarAIInboxService
    ) async throws -> BurnBarInboxMemoryApprovalResponse {
        guard projectCodeMemory != nil else {
            throw BurnBarInboxAuthorityError.unavailable(
                "Memory authority is unavailable. Configure the index database and retry."
            )
        }
        guard let item = try await inbox.item(id: request.itemID) else {
            throw BurnBarInboxAuthorityError.invalid("No inbox item with id \(request.itemID).")
        }
        guard item.summary.fingerprint == request.fingerprint else {
            throw BurnBarInboxAuthorityError.invalid(
                "Inbox item fingerprint changed; reload the item before approving memory."
            )
        }
        guard let candidate = item.payload.memoryCandidates.first(where: { $0.id == request.candidateID }) else {
            throw BurnBarInboxAuthorityError.invalid(
                "No memory proposal \(request.candidateID) exists on this inbox item."
            )
        }
        let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            throw BurnBarInboxAuthorityError.invalid("This memory proposal has no text.")
        }
        let provenance = "ai-inbox:item:\(item.summary.fingerprint):candidate:\(candidate.id)"
        return try await approveInboxMemoryText(
            text,
            kind: Self.inboxMemoryKind(candidate.kind),
            confidence: candidate.confidence,
            provenance: provenance,
            tags: [
                "ai-inbox",
                "candidate:\(candidate.id)",
                "item:\(item.summary.fingerprint)"
            ] + candidate.citationConversationIDs.prefix(6).map { "conversation:\($0)" },
            projectPath: request.projectPath,
            inbox: inbox
        )
    }

    private func rememberInboxPlanStep(
        _ request: BurnBarInboxPlanRememberStepRequest,
        inbox: BurnBarAIInboxService
    ) async throws -> BurnBarInboxPlanRememberStepResponse {
        guard let memory = projectCodeMemory else {
            throw BurnBarInboxAuthorityError.unavailable(
                "Memory authority is unavailable. Configure the index database and retry."
            )
        }
        guard let canonical = try await inbox.planAndStep(stepID: request.stepID) else {
            throw BurnBarInboxAuthorityError.invalid("No plan step with id \(request.stepID).")
        }
        let text = "\(canonical.plan.title): \(canonical.step.title). \(canonical.step.bodyMarkdown)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            throw BurnBarInboxAuthorityError.invalid("This plan step has no text to remember.")
        }
        let provenance = "ai-inbox:plan:\(canonical.plan.id):step:\(canonical.step.id)"

        let approval: BurnBarInboxMemoryApprovalResponse
        if let existingMemoryID = canonical.step.memoryID {
            let authority = try memory.memoryAuthorityState(
                memoryID: existingMemoryID,
                projectPath: request.projectPath
            )
            let approvalAuditHash: String
            if authority?.reviewStatus == .approved {
                approvalAuditHash = authority?.latestAuditHash ?? ""
            } else {
                approvalAuditHash = try memory.setReviewStatus(
                    BurnBarProjectMemoryReviewStatusRequest(
                        memoryID: existingMemoryID,
                        projectPath: request.projectPath,
                        status: .approved
                    )
                ).auditHash
            }
            let approvedAt = Date()
            try await inbox.upsertApprovedMemory(
                memoryID: existingMemoryID,
                provenance: provenance,
                snippetMarkdown: text,
                approvedAt: approvedAt
            )
            approval = BurnBarInboxMemoryApprovalResponse(
                memoryID: existingMemoryID,
                provenance: provenance,
                quarantineAuditHash: nil,
                approvalAuditHash: approvalAuditHash
            )
        } else {
            approval = try await approveInboxMemoryText(
                text,
                kind: "fact",
                confidence: 0.9,
                provenance: provenance,
                tags: ["ai-inbox", "founder-plan", "plan:\(canonical.plan.id)", "step:\(canonical.step.id)"],
                projectPath: request.projectPath,
                inbox: inbox
            )
            _ = try await inbox.bindPlanStepMemory(
                stepID: canonical.step.id,
                memoryID: approval.memoryID
            )
        }

        guard let refreshed = try await inbox.planAndStep(stepID: canonical.step.id) else {
            throw BurnBarAIInboxStoreError.sqlite("Remembered plan step did not read back.")
        }
        return BurnBarInboxPlanRememberStepResponse(
            plan: refreshed.plan,
            step: refreshed.step,
            memory: approval
        )
    }

    private func approveInboxMemoryText(
        _ text: String,
        kind: String,
        confidence: Double,
        provenance: String,
        tags: [String],
        projectPath: String?,
        inbox: BurnBarAIInboxService
    ) async throws -> BurnBarInboxMemoryApprovalResponse {
        guard let memory = projectCodeMemory else {
            throw BurnBarInboxAuthorityError.unavailable("Memory authority is unavailable.")
        }
        if let existing = try memory.memoryAuthorityState(
            text: text,
            projectPath: projectPath
        ), existing.reviewStatus != .forgotten {
            let approvalAuditHash: String
            if existing.reviewStatus == .approved, existing.latestAuditHash.isEmpty == false {
                approvalAuditHash = existing.latestAuditHash
            } else {
                approvalAuditHash = try memory.setReviewStatus(
                    BurnBarProjectMemoryReviewStatusRequest(
                        memoryID: existing.memoryID,
                        projectPath: projectPath,
                        status: .approved
                    )
                ).auditHash
            }
            try await inbox.upsertApprovedMemory(
                memoryID: existing.memoryID,
                provenance: provenance,
                snippetMarkdown: text,
                approvedAt: Date()
            )
            return BurnBarInboxMemoryApprovalResponse(
                memoryID: existing.memoryID,
                provenance: provenance,
                quarantineAuditHash: existing.reviewStatus == .quarantined
                    ? existing.latestAuditHash
                    : nil,
                approvalAuditHash: approvalAuditHash
            )
        }
        // Deliberately two authority writes. A crash after the first leaves a
        // quarantined row which normal recall excludes; retry is deterministic.
        let quarantined = try memory.remember(
            BurnBarProjectMemoryRememberRequest(
                text: text,
                projectPath: projectPath,
                kind: kind,
                scope: "personal",
                tags: Array(tags.prefix(16)),
                confidence: min(max(confidence, 0), 1),
                sourcePath: provenance,
                reviewStatus: .quarantined
            )
        )
        let approved = try memory.setReviewStatus(
            BurnBarProjectMemoryReviewStatusRequest(
                memoryID: quarantined.memoryID,
                projectPath: projectPath,
                status: .approved
            )
        )
        let approvedAt = Date()
        try await inbox.upsertApprovedMemory(
            memoryID: approved.memoryID,
            provenance: provenance,
            snippetMarkdown: text,
            approvedAt: approvedAt
        )
        return BurnBarInboxMemoryApprovalResponse(
            memoryID: approved.memoryID,
            provenance: provenance,
            quarantineAuditHash: quarantined.auditHash,
            approvalAuditHash: approved.auditHash
        )
    }

    private func createInboxPlanFollowup(
        _ request: BurnBarInboxPlanCreateFollowupRequest,
        inbox: BurnBarAIInboxService
    ) async throws -> BurnBarInboxPlanCreateFollowupResponse {
        let projectSlug = request.projectSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard projectSlug.isEmpty == false, projectSlug.count <= 128 else {
            throw BurnBarInboxAuthorityError.invalid("A bounded project id is required for this follow-up.")
        }
        guard let canonical = try await inbox.planAndStep(stepID: request.stepID) else {
            throw BurnBarInboxAuthorityError.invalid("No plan step with id \(request.stepID).")
        }

        let followupID = canonical.step.followupID ?? "followup-inbox-\(canonical.step.id)"
        let existing = try await missionControlService.followupsList(
            BurnBarFollowupsListRequest(
                projectSlug: projectSlug,
                statuses: BurnBarFollowupStatus.allCases,
                limit: 500
            )
        ).followups.first { $0.id.rawValue == followupID }
        let dueAt = existing?.nextNudgeAt ?? request.dueAt ?? Date().addingTimeInterval(24 * 60 * 60)

        if existing == nil {
            _ = try await missionControlService.followupCreate(
                BurnBarFollowupCreateRequest(
                    followup: BurnBarFollowupSnapshot(
                        id: BurnBarFollowupID(rawValue: followupID),
                        projectSlug: projectSlug,
                        title: canonical.step.title,
                        summary: "\(canonical.plan.title): \(canonical.step.bodyMarkdown)",
                        status: .open,
                        kind: .controllerNudge,
                        createdAt: Date(),
                        nextNudgeAt: dueAt,
                        metadata: [
                            "ai_inbox_plan_id": .string(canonical.plan.id),
                            "ai_inbox_step_id": .string(canonical.step.id)
                        ]
                    )
                )
            )
        }

        _ = try await inbox.planUpdateStep(
            BurnBarInboxPlanUpdateStepRequest(
                stepID: canonical.step.id,
                status: nil,
                missionID: nil,
                followupID: followupID
            )
        )
        guard let refreshed = try await inbox.planAndStep(stepID: canonical.step.id) else {
            throw BurnBarAIInboxStoreError.sqlite("Follow-up-bound plan step did not read back.")
        }
        return BurnBarInboxPlanCreateFollowupResponse(
            plan: refreshed.plan,
            step: refreshed.step,
            followupID: followupID,
            projectSlug: projectSlug,
            title: canonical.step.title,
            dueAt: dueAt
        )
    }

    private static func inboxMemoryKind(_ hint: String) -> String {
        switch hint.lowercased() {
        case "preference": return "preference"
        case "decision", "event": return "event"
        case "profile": return "profile"
        case "relationship": return "relationship"
        default: return "fact"
        }
    }
}
