import Foundation
import OpenBurnBarKernel

/// Daemon authority for Safari memory and skill learning.
///
/// The actor deliberately separates four states that must never be conflated:
/// observation, reviewed proposal, user approval, and activated persistence.
/// Browser content can reach the first two states only. Durable personal memory
/// and portable skills are activated only by an optimistic, version-bound user
/// approval.
public actor LearningCoordinator {
    public typealias EligibilityProvider =
        @Sendable () async -> SafariLearningEligibility
    public typealias SourcePolicy =
        @Sendable (URL) async -> Bool
    public typealias ProposalReviewer =
        @Sendable (SafariLearningReviewContext) async throws -> Data
    public typealias ApprovedMemoryWriter =
        @Sendable (BurnBarProjectMemoryRememberRequest) async throws
            -> BurnBarProjectMemoryRememberResponse
    public typealias ApprovedMemoryForgetter =
        @Sendable (BurnBarProjectMemoryForgetRequest) async throws
            -> BurnBarProjectMemoryForgetResponse
    public typealias PersonalMemoryRecaller =
        @Sendable (BurnBarProjectMemoryRecallRequest) async throws
            -> BurnBarProjectMemoryRecallResponse

    public struct Configuration: Sendable, Equatable {
        public var maximumStoreBytes: Int
        public var maximumProposalCount: Int
        public var maximumHistoryPerProposal: Int
        public var maximumObservationReceipts: Int
        public var maximumRepeatSignals: Int
        public var repeatedWorkflowThreshold: Int
        public var longActionThreshold: Int
        public var maximumObservationAge: TimeInterval
        public var repeatedWorkflowWindow: TimeInterval
        public var staleSkillInterval: TimeInterval
        public var archiveSkillInterval: TimeInterval
        public var maximumRecallBytes: Int

        public init(
            maximumStoreBytes: Int = 4 * 1024 * 1024,
            maximumProposalCount: Int = 512,
            maximumHistoryPerProposal: Int = 16,
            maximumObservationReceipts: Int = 4_096,
            maximumRepeatSignals: Int = 512,
            repeatedWorkflowThreshold: Int = 3,
            longActionThreshold: Int = 5,
            maximumObservationAge: TimeInterval = 30 * 24 * 60 * 60,
            repeatedWorkflowWindow: TimeInterval = 30 * 24 * 60 * 60,
            staleSkillInterval: TimeInterval = 30 * 24 * 60 * 60,
            archiveSkillInterval: TimeInterval = 90 * 24 * 60 * 60,
            maximumRecallBytes: Int = 16 * 1024
        ) {
            self.maximumStoreBytes = max(64 * 1024, maximumStoreBytes)
            self.maximumProposalCount = max(1, maximumProposalCount)
            self.maximumHistoryPerProposal = max(1, maximumHistoryPerProposal)
            self.maximumObservationReceipts = max(32, maximumObservationReceipts)
            self.maximumRepeatSignals = max(8, maximumRepeatSignals)
            self.repeatedWorkflowThreshold = max(3, repeatedWorkflowThreshold)
            self.longActionThreshold = max(5, longActionThreshold)
            self.maximumObservationAge = max(60, maximumObservationAge)
            self.repeatedWorkflowWindow = max(60, repeatedWorkflowWindow)
            self.staleSkillInterval = max(60, staleSkillInterval)
            self.archiveSkillInterval = max(
                self.staleSkillInterval,
                archiveSkillInterval
            )
            self.maximumRecallBytes = max(1_024, maximumRecallBytes)
        }
    }

    private static let schemaVersion = 1
    private static let consentVersion = 1
    private static let maximumIdentifierBytes = 256
    private static let maximumSourceURLBytes = 2_048
    private static let maximumSourceTitleBytes = 512
    private static let maximumTitleBytes = 256
    private static let maximumContentBytes = 16 * 1024
    private static let maximumReasonBytes = 2 * 1024
    private static let maximumExpectedOutcomeBytes = 2 * 1024
    private static let maximumTagCount = 24
    private static let maximumTagBytes = 64
    private static let maximumActionCount = 10_000
    private static let futureClockSkew: TimeInterval = 5 * 60
    private static let strictReviewKeys: Set<String> = [
        "action", "kind", "title", "content", "reason", "expectedOutcome"
    ]

    private let stateURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let configuration: Configuration
    private let eligibilityProvider: EligibilityProvider
    private let sourcePolicy: SourcePolicy
    private let reviewer: ProposalReviewer?
    private let memoryWriter: ApprovedMemoryWriter?
    private let memoryForgetter: ApprovedMemoryForgetter?
    private let memoryRecaller: PersonalMemoryRecaller?
    private let skillStore: SafariLearningSkillStore

    private var loaded = false
    private var state = SafariLearningStoreEnvelope(
        schemaVersion: schemaVersion,
        consent: nil,
        proposals: [],
        repeatSignals: [],
        observationReceipts: [],
        updatedAt: .distantPast
    )
    private var inFlightObservationIDs: Set<String> = []
    private var inFlightProposalIDs: Set<String> = []
    private var profileMutationInFlight = false

    public init(
        stateURL: URL = BurnBarDaemonPaths.supportDirectoryURL
            .appendingPathComponent("safari", isDirectory: true)
            .appendingPathComponent("learning-v1.json", isDirectory: false),
        skillsRootURL: URL = BurnBarDaemonPaths.supportDirectoryURL
            .appendingPathComponent("safari-skills", isDirectory: true),
        fileManager: FileManager = .default,
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = Date.init,
        eligibilityProvider: @escaping EligibilityProvider,
        sourcePolicy: @escaping SourcePolicy = { _ in true },
        reviewer: ProposalReviewer? = nil,
        memoryWriter: ApprovedMemoryWriter? = nil,
        memoryForgetter: ApprovedMemoryForgetter? = nil,
        memoryRecaller: PersonalMemoryRecaller? = nil
    ) {
        self.stateURL = stateURL.standardizedFileURL
        self.fileManager = fileManager
        self.configuration = configuration
        self.now = now
        self.eligibilityProvider = eligibilityProvider
        self.sourcePolicy = sourcePolicy
        self.reviewer = reviewer
        self.memoryWriter = memoryWriter
        self.memoryForgetter = memoryForgetter
        self.memoryRecaller = memoryRecaller
        self.skillStore = SafariLearningSkillStore(
            rootURL: skillsRootURL,
            fileManager: fileManager
        )
    }

    // MARK: - Consent and availability

    public func availability() async throws -> SafariLearningAvailability {
        try loadIfNeeded()
        let eligibility = await eligibilityProvider()
        return SafariLearningAvailability(
            available: eligibility.isEligible,
            optedIn: state.consent?.enabled == true,
            tier: displayTier(eligibility.tier),
            hostedProfileSyncAllowed: eligibility.hostedProfileSyncAllowed
        )
    }

    public func optIn(
        _ request: BurnBarSafariLearningOptInRequest
    ) async throws -> BurnBarSafariLearningStateResponse {
        let eligibility = try await requireEligibility()
        guard request.consentVersion == Self.consentVersion else {
            throw SafariLearningCoordinatorError.invalidConsentVersion
        }
        try loadIfNeeded()
        guard profileMutationInFlight == false else {
            throw SafariLearningCoordinatorError.invalidTransition(
                "a profile mutation is already in progress"
            )
        }
        let current = now()
        if let existing = state.consent {
            state.consent = SafariLearningConsent(
                enabled: true,
                consentVersion: request.consentVersion,
                consentedAt: existing.consentedAt,
                updatedAt: current
            )
        } else {
            state.consent = SafariLearningConsent(
                enabled: true,
                consentVersion: request.consentVersion,
                consentedAt: current,
                updatedAt: current
            )
        }
        state.updatedAt = current
        try persist()
        return BurnBarSafariLearningStateResponse(
            enabled: true,
            tier: displayTier(eligibility.tier)
        )
    }

    public func optOut(
        _ request: BurnBarSafariLearningOptOutRequest
    ) async throws -> BurnBarSafariLearningStateResponse {
        try loadIfNeeded()
        guard profileMutationInFlight == false else {
            throw SafariLearningCoordinatorError.invalidTransition(
                "a profile mutation is already in progress"
            )
        }
        guard inFlightProposalIDs.isEmpty else {
            throw SafariLearningCoordinatorError.invalidTransition(
                "a proposal activation or deletion is in progress; retry opt-out"
            )
        }
        profileMutationInFlight = true
        defer { profileMutationInFlight = false }

        let eligibility = await eligibilityProvider()
        let current = now()
        if let consent = state.consent {
            state.consent = SafariLearningConsent(
                enabled: false,
                consentVersion: consent.consentVersion,
                consentedAt: consent.consentedAt,
                updatedAt: current
            )
        }
        state.updatedAt = current
        // Disable first. If a downstream forget operation fails, no subsequent
        // observation can add to the profile while the user retries the wipe.
        try persist()

        guard request.deleteLearnedProfile else {
            return BurnBarSafariLearningStateResponse(
                enabled: false,
                tier: displayTier(eligibility.tier)
            )
        }

        let externalIDs = SafariLearningSecurity.stableUnique(
            state.proposals.compactMap(\.externalMemoryID)
        )
        if externalIDs.isEmpty == false, memoryForgetter == nil {
            throw SafariLearningCoordinatorError.memoryIntegrationUnavailable
        }
        for memoryID in externalIDs {
            _ = try await memoryForgetter?(
                BurnBarProjectMemoryForgetRequest(memoryID: memoryID)
            )
        }

        let deletedCount = state.proposals.count
        try skillStore.wipe()
        state = SafariLearningStoreEnvelope(
            schemaVersion: Self.schemaVersion,
            consent: nil,
            proposals: [],
            repeatSignals: [],
            observationReceipts: [],
            updatedAt: now()
        )
        try persist()
        return BurnBarSafariLearningStateResponse(
            enabled: false,
            tier: displayTier(eligibility.tier),
            deletedEntryCount: deletedCount
        )
    }

    // MARK: - Proposal loop

    public func propose(
        _ request: BurnBarSafariLearningProposalRequest
    ) async throws -> BurnBarSafariLearningProposalResponse {
        _ = try await requireEligibilityAndConsent()
        try loadIfNeeded()
        guard profileMutationInFlight == false else {
            throw SafariLearningCoordinatorError.invalidTransition(
                "the learned profile is being changed"
            )
        }

        let observation = request.observation
        if let existing = state.proposals.first(where: {
            $0.proposal.sourceObservationId == observation.observationId
        }) {
            return BurnBarSafariLearningProposalResponse(proposal: existing.proposal)
        }
        if state.observationReceipts.contains(where: {
            $0.observationID == observation.observationId
        }) {
            throw SafariLearningCoordinatorError.duplicateObservation
        }
        guard inFlightObservationIDs.insert(observation.observationId).inserted else {
            throw SafariLearningCoordinatorError.duplicateObservation
        }
        defer { inFlightObservationIDs.remove(observation.observationId) }

        let validated = try validate(observation)
        guard await sourcePolicy(validated.sourceURL) else {
            throw SafariLearningCoordinatorError.sourceDenied
        }
        // The source policy and reviewer are async integration seams. Re-check
        // consent after every suspension so an opt-out wins deterministically.
        _ = try await requireEligibilityAndConsent()

        if observation.trigger == .repeatedWorkflow {
            let currentCount = try recordRepeatedWorkflow(
                observationID: observation.observationId,
                fingerprint: validated.repeatFingerprint,
                observedAt: observation.observedAt
            )
            if currentCount < configuration.repeatedWorkflowThreshold {
                throw SafariLearningCoordinatorError.triggerThresholdNotMet(
                    current: currentCount,
                    required: configuration.repeatedWorkflowThreshold
                )
            }
        }

        let context = reviewerContext(
            observation: observation,
            validated: validated
        )
        let reviewData: Data
        if let reviewer {
            reviewData = try await reviewer(context)
        } else {
            reviewData = try JSONEncoder().encode(
                deterministicReview(
                    observation: observation,
                    validated: validated
                )
            )
        }
        _ = try await requireEligibilityAndConsent()
        let reviewed = try Self.decodeStrictReview(reviewData)
        if reviewed.action == .delete {
            throw SafariLearningCoordinatorError.reviewerRejected(reviewed.reason)
        }
        let candidate = try sanitizedProposalCandidate(
            reviewed,
            observation: observation,
            validated: validated
        )

        // A concurrent retry may have completed while the reviewer was running.
        if let existing = state.proposals.first(where: {
            $0.proposal.sourceObservationId == observation.observationId
        }) {
            return BurnBarSafariLearningProposalResponse(proposal: existing.proposal)
        }
        if let duplicate = state.proposals.first(where: {
            $0.proposal.kind == candidate.kind
                && normalizedForDedup($0.proposal.content)
                    == normalizedForDedup(candidate.content)
                && $0.proposal.sourceURL == validated.sourceOrigin
                && $0.proposal.reviewStatus != .rejected
                && $0.proposal.reviewStatus != .archived
        }) {
            appendObservationReceipt(
                observationID: observation.observationId,
                proposalID: duplicate.proposal.proposalId
            )
            try persist()
            return BurnBarSafariLearningProposalResponse(proposal: duplicate.proposal)
        }

        try ensureProposalCapacity()
        let current = now()
        let proposal = BurnBarSafariLearningProposal(
            kind: candidate.kind,
            title: candidate.title,
            content: candidate.content,
            reason: candidate.reason,
            expectedOutcome: candidate.expectedOutcome,
            sourceURL: validated.sourceOrigin,
            sourceObservationId: observation.observationId,
            reviewStatus: .proposed,
            createdAt: current,
            updatedAt: current
        )
        state.proposals.append(
            SafariLearningProposalRecord(
                proposal: proposal,
                trigger: observation.trigger,
                tags: validated.tags,
                sourceTitle: validated.sourceTitle,
                reviewerAction: reviewed.action,
                redactionFindingIDs: candidate.redactionFindingIDs,
                externalMemoryID: nil,
                skillSlug: candidate.kind == .skill
                    ? skillStore.slug(for: proposal)
                    : nil,
                skillLifecycle: nil,
                skillUsage: nil,
                pinned: false,
                history: []
            )
        )
        appendObservationReceipt(
            observationID: observation.observationId,
            proposalID: proposal.proposalId
        )
        if observation.trigger == .repeatedWorkflow {
            state.repeatSignals.removeAll {
                $0.fingerprint == validated.repeatFingerprint
            }
        }
        state.updatedAt = current
        try persist()
        return BurnBarSafariLearningProposalResponse(proposal: proposal)
    }

    public func list(
        _ request: BurnBarSafariLearningListRequest
    ) throws -> BurnBarSafariLearningListResponse {
        try loadIfNeeded()
        let limit = max(1, min(request.limit, 100))
        let proposals = state.proposals
            .map(\.proposal)
            .filter { request.status == nil || $0.reviewStatus == request.status }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.proposalId < rhs.proposalId
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        return BurnBarSafariLearningListResponse(
            proposals: Array(proposals.prefix(limit))
        )
    }

    public func timeline() async throws -> BurnBarSafariLearningTimelineResponse {
        try loadIfNeeded()
        let eligibility = await eligibilityProvider()
        let proposals = state.proposals
            .map(\.proposal)
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.proposalId < rhs.proposalId
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        return BurnBarSafariLearningTimelineResponse(
            enabled: eligibility.isEligible && state.consent?.enabled == true,
            tier: displayTier(eligibility.tier),
            proposals: proposals
        )
    }

    public func update(
        _ request: BurnBarSafariLearningUpdateRequest
    ) async throws -> BurnBarSafariLearningProposalResponse {
        _ = try await requireEligibilityAndConsent()
        try loadIfNeeded()
        let index = try proposalIndex(
            id: request.proposalId,
            expectedVersion: request.expectedVersion
        )
        var record = state.proposals[index]
        guard record.proposal.reviewStatus == .proposed
                || record.proposal.reviewStatus == .approved else {
            throw SafariLearningCoordinatorError.invalidTransition(
                "only proposed or approved learning can be edited"
            )
        }
        guard record.skillLifecycle != .quarantined else {
            throw SafariLearningCoordinatorError.invalidTransition(
                "quarantined learning cannot be edited or activated"
            )
        }

        let title = try sanitizedBounded(
            request.title,
            field: "title",
            maximumBytes: Self.maximumTitleBytes
        )
        let content = try sanitizedBounded(
            request.content,
            field: "content",
            minimumBytes: 8,
            maximumBytes: Self.maximumContentBytes
        )
        guard SafariLearningSecurity.isNoisyObservation(content.text) == false else {
            throw SafariLearningCoordinatorError.invalidObservation(
                "updated content is transient or lacks durable signal"
            )
        }
        guard title.text != record.proposal.title
                || content.text != record.proposal.content else {
            throw SafariLearningCoordinatorError.invalidTransition(
                "the learning edit does not change the item"
            )
        }
        guard state.proposals.contains(where: {
            $0.proposal.proposalId != record.proposal.proposalId
                && $0.proposal.kind == record.proposal.kind
                && $0.proposal.sourceURL == record.proposal.sourceURL
                && normalizedForDedup($0.proposal.content)
                    == normalizedForDedup(content.text)
                && $0.proposal.reviewStatus != .rejected
                && $0.proposal.reviewStatus != .archived
        }) == false else {
            throw SafariLearningCoordinatorError.invalidTransition(
                "an equivalent learning item already exists for this site"
            )
        }

        if record.proposal.kind == .skill {
            let findings = SafariLearningSecurity.skillInjectionFindings(
                fields: [
                    record.sourceTitle,
                    title.text,
                    content.text,
                    record.proposal.reason,
                    record.proposal.expectedOutcome
                ]
            )
            guard findings.isEmpty else {
                throw SafariLearningCoordinatorError.skillQuarantined(findings)
            }
        }

        try beginProposalMutation(record.proposal.proposalId)
        defer { endProposalMutation(record.proposal.proposalId) }

        let current = now()
        let updatedProposal = BurnBarSafariLearningProposal(
            proposalId: record.proposal.proposalId,
            version: record.proposal.version + 1,
            kind: record.proposal.kind,
            title: title.text,
            content: content.text,
            reason: record.proposal.reason,
            expectedOutcome: record.proposal.expectedOutcome,
            sourceURL: record.proposal.sourceURL,
            sourceObservationId: record.proposal.sourceObservationId,
            reviewStatus: record.proposal.reviewStatus,
            createdAt: record.proposal.createdAt,
            updatedAt: current
        )

        switch record.proposal.reviewStatus {
        case .proposed:
            appendSnapshot(to: &record)
            record.proposal = updatedProposal
            state.proposals[index] = record
            state.updatedAt = current
            try persist()

        case .approved:
            switch record.proposal.kind {
            case .memory, .siteRule:
                guard let memoryWriter, let memoryForgetter,
                      let previousMemoryID = record.externalMemoryID else {
                    throw SafariLearningCoordinatorError.memoryIntegrationUnavailable
                }
                var replacementRecord = record
                replacementRecord.proposal = updatedProposal
                replacementRecord.externalMemoryID = nil
                let response = try await memoryWriter(
                    memoryRequest(for: replacementRecord)
                )
                do {
                    try Self.validateIdentifier(
                        response.memoryID,
                        field: "updated memory identifier"
                    )
                } catch {
                    _ = try? await memoryForgetter(
                        BurnBarProjectMemoryForgetRequest(
                            memoryID: response.memoryID
                        )
                    )
                    throw error
                }

                let liveIndex = try proposalIndex(
                    id: request.proposalId,
                    expectedVersion: request.expectedVersion
                )
                let originalRecord = state.proposals[liveIndex]
                let originalUpdatedAt = state.updatedAt
                record = originalRecord
                appendSnapshot(to: &record)
                record.proposal = updatedProposal
                record.externalMemoryID = response.memoryID
                state.proposals[liveIndex] = record
                state.updatedAt = current
                do {
                    try persist()
                } catch {
                    state.proposals[liveIndex] = originalRecord
                    state.updatedAt = originalUpdatedAt
                    _ = try? await memoryForgetter(
                        BurnBarProjectMemoryForgetRequest(
                            memoryID: response.memoryID
                        )
                    )
                    throw error
                }

                do {
                    _ = try await memoryForgetter(
                        BurnBarProjectMemoryForgetRequest(
                            memoryID: previousMemoryID
                        )
                    )
                } catch {
                    state.proposals[liveIndex] = originalRecord
                    state.updatedAt = now()
                    do {
                        try persist()
                    } catch {
                        throw SafariLearningCoordinatorError.invalidTransition(
                            "the replacement memory could not be rolled back safely"
                        )
                    }
                    _ = try? await memoryForgetter(
                        BurnBarProjectMemoryForgetRequest(
                            memoryID: response.memoryID
                        )
                    )
                    throw error
                }

            case .skill:
                guard let slug = record.skillSlug,
                      var usage = record.skillUsage,
                      record.skillLifecycle == .active
                        || record.skillLifecycle == .stale else {
                    throw SafariLearningCoordinatorError.invalidTransition(
                        "the approved skill materialization is unavailable"
                    )
                }
                let originalRecord = record
                let originalUpdatedAt = state.updatedAt
                try skillStore.activate(
                    proposal: updatedProposal,
                    trigger: record.trigger,
                    sourceTitle: record.sourceTitle,
                    slug: slug,
                    currentVersion: record.proposal.version
                )
                usage.patchCount = saturatedIncrement(usage.patchCount)
                usage.updatedAt = current
                do {
                    try skillStore.writeUsage(usage, slug: slug)
                    appendSnapshot(to: &record)
                    record.proposal = updatedProposal
                    record.skillLifecycle = .active
                    record.skillUsage = usage
                    state.proposals[index] = record
                    state.updatedAt = current
                    try persist()
                } catch {
                    try? skillStore.activate(
                        proposal: originalRecord.proposal,
                        trigger: originalRecord.trigger,
                        sourceTitle: originalRecord.sourceTitle,
                        slug: slug,
                        currentVersion: updatedProposal.version
                    )
                    if let previousUsage = originalRecord.skillUsage {
                        try? skillStore.writeUsage(previousUsage, slug: slug)
                    }
                    state.proposals[index] = originalRecord
                    state.updatedAt = originalUpdatedAt
                    throw error
                }
            }

        case .rejected, .archived:
            preconditionFailure("Unsupported learning edit status passed validation.")
        }

        return BurnBarSafariLearningProposalResponse(proposal: record.proposal)
    }

    public func approve(
        _ request: BurnBarSafariLearningMutationRequest
    ) async throws -> BurnBarSafariLearningProposalResponse {
        _ = try await requireEligibilityAndConsent()
        try loadIfNeeded()
        let index = try proposalIndex(
            id: request.proposalId,
            expectedVersion: request.expectedVersion
        )
        var record = state.proposals[index]
        guard record.proposal.reviewStatus == .proposed else {
            throw SafariLearningCoordinatorError.invalidTransition(
                "only a proposed item can be approved"
            )
        }
        try beginProposalMutation(record.proposal.proposalId)
        defer { endProposalMutation(record.proposal.proposalId) }

        var externalMemoryID = record.externalMemoryID
        var skillLifecycle = record.skillLifecycle
        var skillUsage = record.skillUsage
        switch record.proposal.kind {
        case .memory, .siteRule:
            guard let memoryWriter else {
                throw SafariLearningCoordinatorError.memoryIntegrationUnavailable
            }
            let response = try await memoryWriter(memoryRequest(for: record))
            try Self.validateIdentifier(
                response.memoryID,
                field: "approved memory identifier"
            )
            externalMemoryID = response.memoryID
        case .skill:
            let findings = SafariLearningSecurity.skillInjectionFindings(
                fields: [
                    record.sourceTitle,
                    record.proposal.title,
                    record.proposal.content,
                    record.proposal.reason,
                    record.proposal.expectedOutcome
                ]
            )
            if findings.isEmpty == false {
                let slug = record.skillSlug ?? skillStore.slug(for: record.proposal)
                try skillStore.quarantine(
                    proposal: record.proposal,
                    trigger: record.trigger,
                    sourceTitle: record.sourceTitle,
                    slug: slug,
                    findings: findings
                )
                let rejected = replacing(
                    record.proposal,
                    version: record.proposal.version + 1,
                    reviewStatus: .rejected,
                    updatedAt: now()
                )
                appendSnapshot(to: &record)
                record.proposal = rejected
                record.skillSlug = slug
                record.skillLifecycle = .quarantined
                state.proposals[index] = record
                state.updatedAt = now()
                try persist()
                throw SafariLearningCoordinatorError.skillQuarantined(findings)
            }
            let slug = record.skillSlug ?? skillStore.slug(for: record.proposal)
            try skillStore.activate(
                proposal: replacing(
                    record.proposal,
                    version: record.proposal.version + 1,
                    reviewStatus: .approved,
                    updatedAt: now()
                ),
                trigger: record.trigger,
                sourceTitle: record.sourceTitle,
                slug: slug,
                currentVersion: record.skillLifecycle == .active
                    || record.skillLifecycle == .stale
                    ? record.proposal.version
                    : nil
            )
            record.skillSlug = slug
            skillLifecycle = .active
            skillUsage = SafariLearningSkillUsage(updatedAt: now())
        }

        let liveIndex = try proposalIndex(
            id: request.proposalId,
            expectedVersion: request.expectedVersion
        )
        record = state.proposals[liveIndex]
        appendSnapshot(to: &record)
        record.externalMemoryID = externalMemoryID
        record.skillLifecycle = skillLifecycle
        record.skillUsage = skillUsage
        record.proposal = replacing(
            record.proposal,
            version: record.proposal.version + 1,
            reviewStatus: .approved,
            updatedAt: now()
        )
        state.proposals[liveIndex] = record
        state.updatedAt = now()
        try persist()
        return BurnBarSafariLearningProposalResponse(proposal: record.proposal)
    }

    public func reject(
        _ request: BurnBarSafariLearningMutationRequest
    ) throws -> BurnBarSafariLearningProposalResponse {
        try loadIfNeeded()
        guard profileMutationInFlight == false else {
            throw SafariLearningCoordinatorError.invalidTransition(
                "the learned profile is being changed"
            )
        }
        let index = try proposalIndex(
            id: request.proposalId,
            expectedVersion: request.expectedVersion
        )
        var record = state.proposals[index]
        guard record.proposal.reviewStatus == .proposed else {
            throw SafariLearningCoordinatorError.invalidTransition(
                "only a proposed item can be rejected"
            )
        }
        guard inFlightProposalIDs.contains(record.proposal.proposalId) == false else {
            throw SafariLearningCoordinatorError.invalidTransition(
                "the proposal is currently being activated"
            )
        }
        appendSnapshot(to: &record)
        record.proposal = replacing(
            record.proposal,
            version: record.proposal.version + 1,
            reviewStatus: .rejected,
            updatedAt: now()
        )
        state.proposals[index] = record
        state.updatedAt = now()
        try persist()
        return BurnBarSafariLearningProposalResponse(proposal: record.proposal)
    }

    public func forget(
        _ request: BurnBarSafariLearningForgetRequest
    ) async throws -> BurnBarSafariLearningStateResponse {
        try loadIfNeeded()
        guard let index = state.proposals.firstIndex(where: {
            $0.proposal.proposalId == request.proposalId
        }) else {
            throw SafariLearningCoordinatorError.proposalNotFound(request.proposalId)
        }
        let record = state.proposals[index]
        if let expectedVersion = request.expectedVersion,
           record.proposal.version != expectedVersion {
            throw SafariLearningCoordinatorError.versionConflict(
                expected: expectedVersion,
                actual: record.proposal.version
            )
        }
        try beginProposalMutation(record.proposal.proposalId)
        defer { endProposalMutation(record.proposal.proposalId) }

        if let memoryID = record.externalMemoryID {
            guard let memoryForgetter else {
                throw SafariLearningCoordinatorError.memoryIntegrationUnavailable
            }
            _ = try await memoryForgetter(
                BurnBarProjectMemoryForgetRequest(memoryID: memoryID)
            )
        }
        try skillStore.deleteAllArtifacts(
            proposalID: record.proposal.proposalId,
            slug: record.skillSlug
        )

        guard let liveIndex = state.proposals.firstIndex(where: {
            $0.proposal.proposalId == request.proposalId
        }), state.proposals[liveIndex].proposal.version == record.proposal.version else {
            let actual = state.proposals.first(where: {
                $0.proposal.proposalId == request.proposalId
            })?.proposal.version ?? -1
            throw SafariLearningCoordinatorError.versionConflict(
                expected: record.proposal.version,
                actual: actual
            )
        }
        state.proposals.remove(at: liveIndex)
        state.observationReceipts.removeAll {
            $0.proposalID == request.proposalId
        }
        state.updatedAt = now()
        try persist()
        let eligibility = await eligibilityProvider()
        return BurnBarSafariLearningStateResponse(
            enabled: eligibility.isEligible && state.consent?.enabled == true,
            tier: displayTier(eligibility.tier),
            deletedEntryCount: 1
        )
    }

    public func rollback(
        _ request: BurnBarSafariLearningRollbackRequest
    ) async throws -> BurnBarSafariLearningProposalResponse {
        _ = try await requireEligibilityAndConsent()
        try loadIfNeeded()
        guard let index = state.proposals.firstIndex(where: {
            $0.proposal.proposalId == request.proposalId
        }) else {
            throw SafariLearningCoordinatorError.proposalNotFound(request.proposalId)
        }
        var record = state.proposals[index]
        guard request.targetVersion != record.proposal.version,
              let target = record.history.last(where: {
                  $0.proposal.version == request.targetVersion
              }) else {
            throw SafariLearningCoordinatorError.invalidTransition(
                "rollback target version is unavailable"
            )
        }
        try beginProposalMutation(record.proposal.proposalId)
        defer { endProposalMutation(record.proposal.proposalId) }

        let rolledBackProposal = BurnBarSafariLearningProposal(
            proposalId: record.proposal.proposalId,
            version: record.proposal.version + 1,
            kind: target.proposal.kind,
            title: target.proposal.title,
            content: target.proposal.content,
            reason: target.proposal.reason,
            expectedOutcome: target.proposal.expectedOutcome,
            sourceURL: target.proposal.sourceURL,
            sourceObservationId: target.proposal.sourceObservationId,
            reviewStatus: target.proposal.reviewStatus,
            createdAt: record.proposal.createdAt,
            updatedAt: now()
        )

        var restoredExternalMemoryID: String?
        if record.proposal.kind == .memory || record.proposal.kind == .siteRule {
            if target.proposal.reviewStatus == .approved {
                guard let memoryWriter else {
                    throw SafariLearningCoordinatorError.memoryIntegrationUnavailable
                }
                let targetRecord = SafariLearningProposalRecord(
                    proposal: rolledBackProposal,
                    trigger: record.trigger,
                    tags: record.tags,
                    sourceTitle: record.sourceTitle,
                    reviewerAction: record.reviewerAction,
                    redactionFindingIDs: record.redactionFindingIDs,
                    externalMemoryID: nil,
                    skillSlug: nil,
                    skillLifecycle: nil,
                    skillUsage: nil,
                    pinned: record.pinned,
                    history: []
                )
                let response = try await memoryWriter(memoryRequest(for: targetRecord))
                try Self.validateIdentifier(
                    response.memoryID,
                    field: "approved memory identifier"
                )
                restoredExternalMemoryID = response.memoryID
            }
            if let currentMemoryID = record.externalMemoryID,
               currentMemoryID != restoredExternalMemoryID {
                guard let memoryForgetter else {
                    throw SafariLearningCoordinatorError.memoryIntegrationUnavailable
                }
                _ = try await memoryForgetter(
                    BurnBarProjectMemoryForgetRequest(memoryID: currentMemoryID)
                )
            }
        } else if record.proposal.kind == .skill {
            let slug = record.skillSlug ?? skillStore.slug(for: rolledBackProposal)
            var activeMaterializationExists =
                record.skillLifecycle == .active
                || record.skillLifecycle == .stale
            if record.skillLifecycle == .archived {
                try skillStore.restoreArchived(slug: slug)
                activeMaterializationExists = true
            }
            if target.proposal.reviewStatus == .approved
                || target.proposal.reviewStatus == .archived {
                let findings = SafariLearningSecurity.skillInjectionFindings(
                    fields: [
                        record.sourceTitle,
                        rolledBackProposal.title,
                        rolledBackProposal.content,
                        rolledBackProposal.reason,
                        rolledBackProposal.expectedOutcome
                    ]
                )
                guard findings.isEmpty else {
                    throw SafariLearningCoordinatorError.skillQuarantined(findings)
                }
                try skillStore.activate(
                    proposal: rolledBackProposal,
                    trigger: record.trigger,
                    sourceTitle: record.sourceTitle,
                    slug: slug,
                    currentVersion: activeMaterializationExists
                        ? record.proposal.version : nil
                )
                if target.proposal.reviewStatus == .archived {
                    try skillStore.archive(
                        slug: slug,
                        proposalID: record.proposal.proposalId,
                        version: rolledBackProposal.version
                    )
                }
            } else if activeMaterializationExists {
                try skillStore.removeActive(
                    slug: slug,
                    proposalID: record.proposal.proposalId,
                    currentVersion: record.proposal.version,
                    retainSnapshot: true
                )
            }
        }

        guard let liveIndex = state.proposals.firstIndex(where: {
            $0.proposal.proposalId == request.proposalId
        }), state.proposals[liveIndex].proposal.version == record.proposal.version else {
            let actual = state.proposals.first(where: {
                $0.proposal.proposalId == request.proposalId
            })?.proposal.version ?? -1
            throw SafariLearningCoordinatorError.versionConflict(
                expected: record.proposal.version,
                actual: actual
            )
        }
        record = state.proposals[liveIndex]
        appendSnapshot(to: &record)
        record.proposal = rolledBackProposal
        record.externalMemoryID = restoredExternalMemoryID
        if rolledBackProposal.kind == .skill {
            record.skillSlug = target.skillSlug ?? record.skillSlug
            switch target.proposal.reviewStatus {
            case .approved:
                record.skillLifecycle = target.skillLifecycle ?? .active
            case .archived:
                record.skillLifecycle = .archived
            case .rejected:
                record.skillLifecycle = target.skillLifecycle == .quarantined
                    ? .quarantined : nil
            case .proposed:
                record.skillLifecycle = nil
            }
            record.skillUsage = target.skillUsage
            record.pinned = target.pinned
        } else {
            record.skillSlug = nil
            record.skillLifecycle = nil
            record.skillUsage = nil
            record.pinned = false
        }
        state.proposals[liveIndex] = record
        state.updatedAt = now()
        try persist()
        return BurnBarSafariLearningProposalResponse(proposal: rolledBackProposal)
    }

    // MARK: - Recall

    public func recallForPrompt(
        query rawQuery: String,
        limit requestedLimit: Int = 8
    ) async throws -> String? {
        _ = try await requireEligibilityAndConsent()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false, query.utf8.count <= 2_048 else {
            throw SafariLearningCoordinatorError.invalidObservation(
                "recall query is empty or too large"
            )
        }
        let limit = max(1, min(requestedLimit, 20))
        let entries: [SafariLearningRecallEntry]
        if let memoryRecaller {
            let response = try await memoryRecaller(
                BurnBarProjectMemoryRecallRequest(
                    query: query,
                    limit: limit,
                    scope: "personal",
                    includeCrossProject: true
                )
            )
            // The memory authority normally applies these filters itself. Keep
            // them here too so a stale or alternate recaller cannot surface a
            // quarantined, rejected, forgotten, or non-personal record.
            entries = response.hits
                .filter {
                    $0.reviewStatus == .approved
                        && $0.scope.caseInsensitiveCompare("personal")
                            == .orderedSame
                }
                .prefix(limit)
                .map { hit in
                    SafariLearningRecallEntry(
                        id: hit.memoryID,
                        text: hit.snippet.isEmpty
                            ? hit.bodyRedacted
                            : hit.snippet,
                        proposalID: state.proposals.first {
                            $0.externalMemoryID == hit.memoryID
                                && $0.proposal.reviewStatus == .approved
                        }?.proposal.proposalId
                    )
                }
        } else {
            let tokens = Self.queryTokens(query)
            entries = state.proposals
                .filter {
                    ($0.proposal.kind == .memory || $0.proposal.kind == .siteRule)
                        && $0.proposal.reviewStatus == .approved
                }
                .map { record in
                    let searchable = "\(record.proposal.title) \(record.proposal.content) \(record.tags.joined(separator: " "))"
                        .lowercased()
                    let score = tokens.reduce(into: 0) { partial, token in
                        if searchable.contains(token) {
                            partial += 1
                        }
                    }
                    return (record, score)
                }
                .filter { tokens.isEmpty || $0.1 > 0 }
                .sorted {
                    if $0.1 == $1.1 {
                        return $0.0.proposal.updatedAt > $1.0.proposal.updatedAt
                    }
                    return $0.1 > $1.1
                }
                .prefix(limit)
                .map { record, _ in
                    SafariLearningRecallEntry(
                        id: record.externalMemoryID ?? record.proposal.proposalId,
                        text: record.proposal.content,
                        proposalID: record.proposal.proposalId
                    )
                }
        }
        // Recall is an async integration seam. If the user opts out or loses
        // eligibility while it is running, return no learned profile material.
        _ = try await requireEligibilityAndConsent()
        return try Self.untrustedRecallBlock(
            entries: entries,
            maximumBytes: configuration.maximumRecallBytes
        )
    }

    public static func untrustedRecallBlock(
        entries: [SafariLearningRecallEntry],
        maximumBytes: Int = 16 * 1024
    ) throws -> String? {
        let boundedMaximum = max(1_024, min(maximumBytes, 64 * 1024))
        var lines: [String] = []
        var currentBytes = 0
        for entry in entries.prefix(20) {
            let identifier = entry.id
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafeRecallIdentifier(identifier) else {
                continue
            }
            let sanitized = try SafariLearningSecurity.sanitizeForPersistence(entry.text)
            guard sanitized.text.isEmpty == false else { continue }
            let rawForgetTarget = entry.proposalID ?? identifier
            let forgetTarget: String
            if isSafeRecallIdentifier(rawForgetTarget) {
                forgetTarget = rawForgetTarget
            } else {
                forgetTarget = identifier
            }
            let indentedText = sanitized.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: "\n  ")
            let line = "- [memory_id=\(identifier); forget_id=\(forgetTarget)] \(indentedText)"
            if currentBytes + line.utf8.count + 1 > boundedMaximum {
                break
            }
            lines.append(line)
            currentBytes += line.utf8.count + 1
        }
        guard lines.isEmpty == false else { return nil }
        let body = """
        What BurnBar knows about the user (reviewable; use forget_id to remove an item):
        \(lines.joined(separator: "\n"))
        """
        return """
        ## What you know about me
        \(LLMSafeContent.wrapUntrusted(
            body,
            provenance: "safari_learning_recall"
        ))
        """
    }

    // MARK: - Skill telemetry and anti-rot

    public func recordSkillUsage(
        proposalID: String,
        event: SafariLearningSkillUsageEvent
    ) async throws {
        _ = try await requireEligibilityAndConsent()
        try loadIfNeeded()
        guard let index = state.proposals.firstIndex(where: {
            $0.proposal.proposalId == proposalID
        }) else {
            throw SafariLearningCoordinatorError.proposalNotFound(proposalID)
        }
        var record = state.proposals[index]
        guard record.proposal.kind == .skill,
              record.proposal.reviewStatus == .approved,
              let slug = record.skillSlug,
              record.skillLifecycle == .active || record.skillLifecycle == .stale else {
            throw SafariLearningCoordinatorError.skillNotFound(proposalID)
        }
        var usage = record.skillUsage ?? SafariLearningSkillUsage(updatedAt: now())
        switch event {
        case .use:
            usage.useCount = saturatedIncrement(usage.useCount)
            usage.lastUsedAt = now()
        case .view:
            usage.viewCount = saturatedIncrement(usage.viewCount)
        case .patch:
            usage.patchCount = saturatedIncrement(usage.patchCount)
            usage.lastUsedAt = now()
        }
        usage.updatedAt = now()
        record.skillUsage = usage
        if record.skillLifecycle == .stale {
            record.skillLifecycle = .active
        }
        state.proposals[index] = record
        state.updatedAt = now()
        try skillStore.writeUsage(usage, slug: slug)
        try persist()
    }

    public func setSkillPinned(
        proposalID: String,
        expectedVersion: Int,
        pinned: Bool
    ) throws -> BurnBarSafariLearningProposalResponse {
        try loadIfNeeded()
        let index = try proposalIndex(id: proposalID, expectedVersion: expectedVersion)
        var record = state.proposals[index]
        guard record.proposal.kind == .skill else {
            throw SafariLearningCoordinatorError.skillNotFound(proposalID)
        }
        guard inFlightProposalIDs.contains(proposalID) == false,
              profileMutationInFlight == false else {
            throw SafariLearningCoordinatorError.invalidTransition(
                "the learned skill is currently being changed"
            )
        }
        appendSnapshot(to: &record)
        record.pinned = pinned
        record.proposal = replacing(
            record.proposal,
            version: record.proposal.version + 1,
            reviewStatus: record.proposal.reviewStatus,
            updatedAt: now()
        )
        state.proposals[index] = record
        state.updatedAt = now()
        try persist()
        return BurnBarSafariLearningProposalResponse(proposal: record.proposal)
    }

    public func performSkillMaintenance() async throws
        -> SafariLearningMaintenanceResult {
        _ = try await requireEligibilityAndConsent()
        try loadIfNeeded()
        let current = now()
        var stale: [String] = []
        var archived: [String] = []

        for index in state.proposals.indices {
            var record = state.proposals[index]
            guard record.proposal.kind == .skill,
                  record.proposal.reviewStatus == .approved,
                  record.pinned == false,
                  inFlightProposalIDs.contains(record.proposal.proposalId) == false,
                  let slug = record.skillSlug else {
                continue
            }
            // Lifecycle transitions must not reset inactivity age. The usage
            // sidecar's creation/update anchor represents the last real skill
            // interaction; proposal.updatedAt also changes when maintenance
            // merely marks the skill stale.
            let activityDate = record.skillUsage?.lastUsedAt
                ?? record.skillUsage?.updatedAt
                ?? record.proposal.createdAt
            let age = max(0, current.timeIntervalSince(activityDate))
            if age >= configuration.archiveSkillInterval,
               record.skillLifecycle != .archived {
                appendSnapshot(to: &record)
                try skillStore.archive(
                    slug: slug,
                    proposalID: record.proposal.proposalId,
                    version: record.proposal.version
                )
                record.skillLifecycle = .archived
                record.proposal = replacing(
                    record.proposal,
                    version: record.proposal.version + 1,
                    reviewStatus: .archived,
                    updatedAt: current
                )
                archived.append(record.proposal.proposalId)
                state.proposals[index] = record
            } else if age >= configuration.staleSkillInterval,
                      record.skillLifecycle == .active {
                appendSnapshot(to: &record)
                record.skillLifecycle = .stale
                record.proposal = replacing(
                    record.proposal,
                    version: record.proposal.version + 1,
                    reviewStatus: .approved,
                    updatedAt: current
                )
                stale.append(record.proposal.proposalId)
                state.proposals[index] = record
            }
        }
        if stale.isEmpty == false || archived.isEmpty == false {
            state.updatedAt = current
            try persist()
        }
        return SafariLearningMaintenanceResult(
            markedStale: stale,
            archived: archived
        )
    }

    public func skillFileURL(proposalID: String) throws -> URL? {
        try loadIfNeeded()
        guard let record = state.proposals.first(where: {
            $0.proposal.proposalId == proposalID
        }), record.proposal.kind == .skill,
           let slug = record.skillSlug,
           let lifecycle = record.skillLifecycle else {
            return nil
        }
        return try skillStore.skillURL(
            proposalID: proposalID,
            slug: slug,
            lifecycle: lifecycle
        )
    }

    // MARK: - Validation and review

    private struct ValidatedObservation {
        let sourceURL: URL
        let sourceOrigin: String
        let sourceTitle: String
        let content: String
        let tags: [String]
        let contentRedactionFindingIDs: [String]
        let repeatFingerprint: String
    }

    private struct SanitizedProposalCandidate {
        let kind: BurnBarSafariLearningProposalKind
        let title: String
        let content: String
        let reason: String
        let expectedOutcome: String
        let redactionFindingIDs: [String]
    }

    private func validate(
        _ observation: BurnBarSafariLearningObservation
    ) throws -> ValidatedObservation {
        try Self.validateIdentifier(observation.observationId, field: "observationId")
        try Self.validateIdentifier(observation.safariSessionId, field: "safariSessionId")
        if let runID = observation.runId {
            try Self.validateIdentifier(runID, field: "runId")
        }
        guard observation.actionCount >= 0,
              observation.actionCount <= Self.maximumActionCount else {
            throw SafariLearningCoordinatorError.invalidObservation(
                "action count is outside the supported range"
            )
        }
        switch observation.trigger {
        case .longActionSequence:
            guard observation.actionCount >= configuration.longActionThreshold else {
                throw SafariLearningCoordinatorError.triggerThresholdNotMet(
                    current: observation.actionCount,
                    required: configuration.longActionThreshold
                )
            }
        case .recoveredFailure:
            guard observation.actionCount >= 2 else {
                throw SafariLearningCoordinatorError.invalidObservation(
                    "a recovered failure must contain an error and a recovery action"
                )
            }
        case .userCorrection, .repeatedWorkflow:
            break
        }

        let current = now()
        guard observation.observedAt
                <= current.addingTimeInterval(Self.futureClockSkew),
              observation.observedAt
                >= current.addingTimeInterval(-configuration.maximumObservationAge) else {
            throw SafariLearningCoordinatorError.invalidObservation(
                "observation timestamp is outside the accepted replay window"
            )
        }

        let source = try OpenBurnBarBrowserTargetPolicy.validatedURL(
            observation.sourceURL
        )
        guard source.user == nil, source.password == nil,
              observation.sourceURL.utf8.count <= Self.maximumSourceURLBytes else {
            throw SafariLearningCoordinatorError.invalidObservation(
                "source URL contains credentials or exceeds the size limit"
            )
        }
        let origin = try Self.originString(from: source)
        let rawTitle = observation.sourceTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawTitle.utf8.count <= Self.maximumSourceTitleBytes else {
            throw SafariLearningCoordinatorError.invalidObservation(
                "source title is too large"
            )
        }
        let titleSanitized = try SafariLearningSecurity.sanitizeForPersistence(
            rawTitle.isEmpty ? (source.host ?? "Safari page") : rawTitle
        )

        let rawContent = observation.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawContent.utf8.count >= 12,
              rawContent.utf8.count <= Self.maximumContentBytes,
              SafariLearningSecurity.isNoisyObservation(rawContent) == false else {
            throw SafariLearningCoordinatorError.invalidObservation(
                "content is empty, oversized, page-dump-like, or lacks durable signal"
            )
        }
        let contentSanitized = try SafariLearningSecurity.sanitizeForPersistence(
            rawContent
        )
        guard contentSanitized.text.utf8.count >= 8,
              SafariLearningSecurity.isNoisyObservation(contentSanitized.text) == false else {
            throw SafariLearningCoordinatorError.invalidObservation(
                "redaction left no durable learning signal"
            )
        }
        let tags = try Self.validatedTags(observation.tags)
        let normalized = normalizedForDedup(contentSanitized.text)
        let fingerprint = Self.stableDigest(
            "\(origin)|\(normalized)"
        )
        return ValidatedObservation(
            sourceURL: source,
            sourceOrigin: origin,
            sourceTitle: titleSanitized.text,
            content: contentSanitized.text,
            tags: tags,
            contentRedactionFindingIDs:
                titleSanitized.redactionFindingIDs
                + contentSanitized.redactionFindingIDs,
            repeatFingerprint: fingerprint
        )
    }

    private func reviewerContext(
        observation: BurnBarSafariLearningObservation,
        validated: ValidatedObservation
    ) -> SafariLearningReviewContext {
        let existing = state.proposals
            .sorted { $0.proposal.updatedAt > $1.proposal.updatedAt }
            .prefix(12)
            .map {
                "\($0.proposal.kind.rawValue) | \($0.proposal.reviewStatus.rawValue) | \($0.proposal.title) | \($0.proposal.sourceURL)"
            }
        let refinements = state.proposals
            .flatMap(\.history)
            .sorted { $0.capturedAt > $1.capturedAt }
            .prefix(8)
            .map {
                "v\($0.proposal.version) \($0.proposal.reviewStatus.rawValue): \($0.proposal.reason)"
            }
        return SafariLearningReviewContext(
            trigger: observation.trigger,
            actionCount: observation.actionCount,
            sourceOrigin: validated.sourceOrigin,
            sourceTitle: validated.sourceTitle,
            wrappedEvidence: LLMSafeContent.wrapUntrusted(
                validated.content,
                provenance: "safari_learning_observation:\(observation.observationId)"
            ),
            existingEntriesOverview: Array(existing),
            recentRefinements: Array(refinements)
        )
    }

    private func deterministicReview(
        observation: BurnBarSafariLearningObservation,
        validated: ValidatedObservation
    ) -> SafariLearningReviewOutput {
        let host = validated.sourceURL.host ?? "this site"
        let kind: String
        let title: String
        let reason: String
        let outcome: String
        switch observation.trigger {
        case .userCorrection:
            kind = "memory"
            title = "User preference from \(validated.sourceTitle)"
            reason = "The user explicitly corrected the agent, which is durable first-party evidence."
            outcome = "Future Safari turns respect the user's stated preference."
        case .recoveredFailure:
            kind = "promptNote"
            title = "Recovery rule for \(host)"
            reason = "A concrete failure was followed by a successful recovery sequence."
            outcome = "Future runs on this origin avoid the failed path and use the reviewed recovery."
        case .repeatedWorkflow:
            kind = "skill"
            title = "Repeatable workflow for \(host)"
            reason = "The same bounded workflow was observed at least three times."
            outcome = "The workflow can be deliberately selected without rediscovering its steps."
        case .longActionSequence:
            kind = "skill"
            title = "Reusable Safari workflow for \(host)"
            reason = "A deliberate sequence of at least five page actions is a candidate for reuse."
            outcome = "The reviewed sequence becomes a portable, user-invoked page skill."
        }
        return SafariLearningReviewOutput(
            action: .create,
            kind: kind,
            title: title,
            content: validated.content,
            reason: reason,
            expectedOutcome: outcome
        )
    }

    private func sanitizedProposalCandidate(
        _ review: SafariLearningReviewOutput,
        observation: BurnBarSafariLearningObservation,
        validated: ValidatedObservation
    ) throws -> SanitizedProposalCandidate {
        let kind: BurnBarSafariLearningProposalKind
        switch review.kind
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "memory":
            kind = .memory
        case "skill":
            kind = .skill
        case "promptnote", "prompt_note", "site_rule", "siterule":
            kind = .siteRule
        default:
            throw SafariLearningCoordinatorError.malformedReviewerOutput(
                "kind must be memory, skill, or promptNote"
            )
        }
        switch observation.trigger {
        case .repeatedWorkflow, .longActionSequence:
            guard kind == .skill else {
                throw SafariLearningCoordinatorError.reviewerRejected(
                    "repeated procedures and long action sequences must use the smallest reusable skill edit"
                )
            }
        case .userCorrection:
            guard kind == .memory || kind == .siteRule else {
                throw SafariLearningCoordinatorError.reviewerRejected(
                    "a user correction must remain a narrow memory or site rule"
                )
            }
        case .recoveredFailure:
            guard kind == .siteRule || kind == .skill else {
                throw SafariLearningCoordinatorError.reviewerRejected(
                    "a recovery sequence must remain a narrow site rule or reusable skill"
                )
            }
        }

        let title = try sanitizedBounded(
            review.title,
            field: "title",
            maximumBytes: Self.maximumTitleBytes
        )
        let content = try sanitizedBounded(
            review.content,
            field: "content",
            minimumBytes: 8,
            maximumBytes: Self.maximumContentBytes
        )
        let reason = try sanitizedBounded(
            review.reason,
            field: "reason",
            minimumBytes: 8,
            maximumBytes: Self.maximumReasonBytes
        )
        let expected = try sanitizedBounded(
            review.expectedOutcome,
            field: "expectedOutcome",
            minimumBytes: 8,
            maximumBytes: Self.maximumExpectedOutcomeBytes
        )
        guard SafariLearningSecurity.isNoisyObservation(content.text) == false else {
            throw SafariLearningCoordinatorError.reviewerRejected(
                "reviewed content is transient or lacks durable signal"
            )
        }
        guard Self.isGrounded(
            candidate: content.text,
            evidence: validated.content
        ) else {
            throw SafariLearningCoordinatorError.reviewerRejected(
                "reviewed content is not grounded in the supplied observation"
            )
        }
        return SanitizedProposalCandidate(
            kind: kind,
            title: title.text,
            content: content.text,
            reason: reason.text,
            expectedOutcome: expected.text,
            redactionFindingIDs: SafariLearningSecurity.stableUnique(
                validated.contentRedactionFindingIDs
                    + title.redactionFindingIDs
                    + content.redactionFindingIDs
                    + reason.redactionFindingIDs
                    + expected.redactionFindingIDs
            )
        )
    }

    private func sanitizedBounded(
        _ raw: String,
        field: String,
        minimumBytes: Int = 1,
        maximumBytes: Int
    ) throws -> SafariLearningSecurity.SanitizedText {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count >= minimumBytes,
              trimmed.utf8.count <= maximumBytes else {
            throw SafariLearningCoordinatorError.malformedReviewerOutput(
                "\(field) is empty or exceeds its \(maximumBytes)-byte limit"
            )
        }
        return try SafariLearningSecurity.sanitizeForPersistence(trimmed)
    }

    private static func decodeStrictReview(
        _ data: Data
    ) throws -> SafariLearningReviewOutput {
        guard data.isEmpty == false, data.count <= 64 * 1024 else {
            throw SafariLearningCoordinatorError.malformedReviewerOutput(
                "payload is empty or too large"
            )
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw SafariLearningCoordinatorError.malformedReviewerOutput(
                "payload is not valid JSON"
            )
        }
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Self.strictReviewKeys,
              dictionary.values.allSatisfy({ $0 is String }) else {
            throw SafariLearningCoordinatorError.malformedReviewerOutput(
                "payload must contain exactly action, kind, title, content, reason, and expectedOutcome string fields"
            )
        }
        do {
            return try JSONDecoder().decode(SafariLearningReviewOutput.self, from: data)
        } catch {
            throw SafariLearningCoordinatorError.malformedReviewerOutput(
                "action or field encoding is unsupported"
            )
        }
    }

    // MARK: - State transitions and integrations

    private func memoryRequest(
        for record: SafariLearningProposalRecord
    ) -> BurnBarProjectMemoryRememberRequest {
        let kind: String
        if record.proposal.kind == .siteRule {
            kind = "site_rule"
        } else if record.tags.contains(where: {
            $0.caseInsensitiveCompare("preference") == .orderedSame
                || $0.caseInsensitiveCompare("user_preference") == .orderedSame
        }) {
            kind = "user_preference"
        } else {
            kind = "user_fact"
        }
        let host = URL(string: record.proposal.sourceURL)?.host
        var tags = record.tags
        tags.append("safari_extension")
        tags.append("safari_proposal:\(record.proposal.proposalId)")
        tags.append(
            "safari_observation:\(record.proposal.sourceObservationId)"
        )
        if let host {
            tags.append("origin:\(host.lowercased())")
        }
        return BurnBarProjectMemoryRememberRequest(
            text: record.proposal.content,
            kind: kind,
            scope: "personal",
            tags: SafariLearningSecurity.stableUnique(tags),
            confidence: record.trigger == .userCorrection ? 0.9 : 0.8,
            sourcePath: "safari_extension",
            reviewStatus: .approved
        )
    }

    private func proposalIndex(
        id: String,
        expectedVersion: Int
    ) throws -> Int {
        guard let index = state.proposals.firstIndex(where: {
            $0.proposal.proposalId == id
        }) else {
            throw SafariLearningCoordinatorError.proposalNotFound(id)
        }
        let actual = state.proposals[index].proposal.version
        guard actual == expectedVersion else {
            throw SafariLearningCoordinatorError.versionConflict(
                expected: expectedVersion,
                actual: actual
            )
        }
        return index
    }

    private func beginProposalMutation(_ proposalID: String) throws {
        guard profileMutationInFlight == false,
              inFlightProposalIDs.insert(proposalID).inserted else {
            throw SafariLearningCoordinatorError.invalidTransition(
                "the proposal or profile is already being changed"
            )
        }
    }

    private func endProposalMutation(_ proposalID: String) {
        inFlightProposalIDs.remove(proposalID)
    }

    private func appendSnapshot(to record: inout SafariLearningProposalRecord) {
        record.history.append(
            SafariLearningProposalSnapshot(
                proposal: record.proposal,
                externalMemoryID: record.externalMemoryID,
                skillSlug: record.skillSlug,
                skillLifecycle: record.skillLifecycle,
                skillUsage: record.skillUsage,
                pinned: record.pinned,
                capturedAt: now()
            )
        )
        if record.history.count > configuration.maximumHistoryPerProposal {
            record.history.removeFirst(
                record.history.count - configuration.maximumHistoryPerProposal
            )
        }
    }

    private func replacing(
        _ proposal: BurnBarSafariLearningProposal,
        version: Int,
        reviewStatus: BurnBarSafariLearningReviewStatus,
        updatedAt: Date
    ) -> BurnBarSafariLearningProposal {
        BurnBarSafariLearningProposal(
            proposalId: proposal.proposalId,
            version: version,
            kind: proposal.kind,
            title: proposal.title,
            content: proposal.content,
            reason: proposal.reason,
            expectedOutcome: proposal.expectedOutcome,
            sourceURL: proposal.sourceURL,
            sourceObservationId: proposal.sourceObservationId,
            reviewStatus: reviewStatus,
            createdAt: proposal.createdAt,
            updatedAt: updatedAt
        )
    }

    private func recordRepeatedWorkflow(
        observationID: String,
        fingerprint: String,
        observedAt: Date
    ) throws -> Int {
        let current = now()
        state.repeatSignals.removeAll {
            current.timeIntervalSince($0.lastObservedAt)
                > configuration.repeatedWorkflowWindow
        }
        let count: Int
        if let index = state.repeatSignals.firstIndex(where: {
            $0.fingerprint == fingerprint
        }) {
            state.repeatSignals[index].count = saturatedIncrement(
                state.repeatSignals[index].count
            )
            state.repeatSignals[index].lastObservedAt = observedAt
            count = state.repeatSignals[index].count
        } else {
            ensureRepeatSignalCapacity()
            state.repeatSignals.append(
                SafariLearningRepeatSignal(
                    fingerprint: fingerprint,
                    count: 1,
                    lastObservedAt: observedAt
                )
            )
            count = 1
        }
        appendObservationReceipt(observationID: observationID, proposalID: nil)
        state.updatedAt = current
        try persist()
        return count
    }

    private func appendObservationReceipt(
        observationID: String,
        proposalID: String?
    ) {
        if let index = state.observationReceipts.firstIndex(where: {
            $0.observationID == observationID
        }) {
            state.observationReceipts[index] = SafariLearningObservationReceipt(
                observationID: observationID,
                proposalID: proposalID
                    ?? state.observationReceipts[index].proposalID,
                recordedAt: now()
            )
            return
        }
        state.observationReceipts.append(
            SafariLearningObservationReceipt(
                observationID: observationID,
                proposalID: proposalID,
                recordedAt: now()
            )
        )
        if state.observationReceipts.count > configuration.maximumObservationReceipts {
            state.observationReceipts.removeFirst(
                state.observationReceipts.count
                    - configuration.maximumObservationReceipts
            )
        }
    }

    private func ensureProposalCapacity() throws {
        guard state.proposals.count < configuration.maximumProposalCount else {
            // Anti-rot is archive-only. Capacity pressure may reject a new
            // proposal, but it must never silently delete learned history.
            throw SafariLearningCoordinatorError.storeCapacityExceeded
        }
    }

    private func ensureRepeatSignalCapacity() {
        if state.repeatSignals.count >= configuration.maximumRepeatSignals {
            state.repeatSignals.sort { $0.lastObservedAt < $1.lastObservedAt }
            state.repeatSignals.removeFirst(
                state.repeatSignals.count
                    - configuration.maximumRepeatSignals + 1
            )
        }
    }

    private func requireEligibility() async throws -> SafariLearningEligibility {
        let eligibility = await eligibilityProvider()
        guard eligibility.isEligible else {
            throw SafariLearningCoordinatorError.ineligibleTier(
                displayTier(eligibility.tier)
            )
        }
        return eligibility
    }

    private func requireEligibilityAndConsent() async throws
        -> SafariLearningEligibility {
        let eligibility = try await requireEligibility()
        try loadIfNeeded()
        guard state.consent?.enabled == true else {
            throw SafariLearningCoordinatorError.optInRequired
        }
        return eligibility
    }

    private func displayTier(_ tier: String) -> String {
        let trimmed = tier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "free" : trimmed
    }

    private func saturatedIncrement(_ value: Int) -> Int {
        value == Int.max ? value : value + 1
    }

    // MARK: - Persistence

    private func loadIfNeeded() throws {
        guard loaded == false else { return }
        guard fileManager.fileExists(atPath: stateURL.path) else {
            state.updatedAt = now()
            loaded = true
            return
        }
        let values = try stateURL.resourceValues(
            forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw SafariLearningCoordinatorError.malformedStore
        }
        guard let size = values.fileSize,
              size > 0,
              size <= configuration.maximumStoreBytes else {
            throw SafariLearningCoordinatorError.storeTooLarge
        }
        try requireOwnerOnlyPermissions(stateURL, directory: false)
        try requireOwnerOnlyPermissions(
            stateURL.deletingLastPathComponent(),
            directory: true
        )
        let data = try Data(contentsOf: stateURL, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: SafariLearningStoreEnvelope
        do {
            decoded = try decoder.decode(SafariLearningStoreEnvelope.self, from: data)
        } catch {
            throw SafariLearningCoordinatorError.malformedStore
        }
        try validate(decoded)
        state = decoded
        loaded = true
    }

    private func validate(_ envelope: SafariLearningStoreEnvelope) throws {
        let current = now().addingTimeInterval(Self.futureClockSkew)
        let proposalIDs = Set(envelope.proposals.map(\.proposal.proposalId))
        guard envelope.schemaVersion == Self.schemaVersion,
              envelope.proposals.count <= configuration.maximumProposalCount,
              envelope.repeatSignals.count <= configuration.maximumRepeatSignals,
              envelope.observationReceipts.count
                <= configuration.maximumObservationReceipts,
              proposalIDs.count == envelope.proposals.count,
              Set(envelope.observationReceipts.map(\.observationID)).count
                == envelope.observationReceipts.count,
              Set(envelope.repeatSignals.map(\.fingerprint)).count
                == envelope.repeatSignals.count,
              envelope.updatedAt <= current else {
            throw SafariLearningCoordinatorError.malformedStore
        }
        if let consent = envelope.consent {
            guard consent.consentVersion == Self.consentVersion,
                  consent.updatedAt >= consent.consentedAt,
                  consent.updatedAt <= current else {
                throw SafariLearningCoordinatorError.malformedStore
            }
        }
        for record in envelope.proposals {
            guard try isValidStoredRecord(record, current: current),
                  record.proposal.historyVersionOrderIsValid(record.history),
                  record.history.count <= configuration.maximumHistoryPerProposal,
                  record.history.allSatisfy({
                      $0.proposal.proposalId == record.proposal.proposalId
                          && $0.proposal.createdAt
                              == record.proposal.createdAt
                          && (try? isValidStoredSnapshot(
                              $0,
                              current: current
                          )) == true
                  }) else {
                throw SafariLearningCoordinatorError.malformedStore
            }
        }
        for signal in envelope.repeatSignals {
            guard signal.fingerprint.count == 16,
                  signal.fingerprint.unicodeScalars.allSatisfy({
                      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
                  }),
                  signal.count >= 1,
                  signal.lastObservedAt <= current else {
                throw SafariLearningCoordinatorError.malformedStore
            }
        }
        for receipt in envelope.observationReceipts {
            guard Self.isStoredIdentifier(receipt.observationID),
                  receipt.recordedAt <= current,
                  receipt.proposalID.map(proposalIDs.contains) ?? true else {
                throw SafariLearningCoordinatorError.malformedStore
            }
        }
    }

    private func persist() throws {
        try validate(state)
        let directory = stateURL.deletingLastPathComponent()
        let stateExists = fileManager.fileExists(atPath: stateURL.path)
        if stateExists {
            try requireOwnerOnlyPermissions(directory, directory: true)
            let values = try stateURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw SafariLearningCoordinatorError.unsafePath
            }
            try requireOwnerOnlyPermissions(stateURL, directory: false)
        }
        try ensureSecureDirectory(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        guard data.count <= configuration.maximumStoreBytes else {
            throw SafariLearningCoordinatorError.storeTooLarge
        }
        try data.write(to: stateURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: stateURL.path
        )
        try requireOwnerOnlyPermissions(stateURL, directory: false)
    }

    private func ensureSecureDirectory(_ directory: URL) throws {
        if fileManager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw SafariLearningCoordinatorError.unsafePath
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
    }

    private func requireOwnerOnlyPermissions(
        _ url: URL,
        directory: Bool
    ) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw SafariLearningCoordinatorError.insecurePermissions(url.path)
        }
        let mode = permissions.intValue
        let allowed = directory ? 0o700 : 0o600
        guard mode & 0o077 == 0, mode & allowed != 0 else {
            throw SafariLearningCoordinatorError.insecurePermissions(url.path)
        }
    }

    private func isValidStoredRecord(
        _ record: SafariLearningProposalRecord,
        current: Date
    ) throws -> Bool {
        let proposal = record.proposal
        guard Self.isValidStoredProposal(proposal, current: current),
              Self.isPersistableText(
                  record.sourceTitle,
                  minimumBytes: 1,
                  maximumBytes: Self.maximumSourceTitleBytes
              ),
              record.reviewerAction != .delete,
              record.redactionFindingIDs.count <= 64,
              record.redactionFindingIDs.allSatisfy({
                  Self.isBoundedControlFree($0, maximumBytes: 256)
              }),
              record.tags.count <= Self.maximumTagCount,
              (try? Self.validatedTags(record.tags)) == record.tags else {
            return false
        }
        if let externalMemoryID = record.externalMemoryID,
           Self.isStoredIdentifier(externalMemoryID) == false {
            return false
        }
        if let skillSlug = record.skillSlug,
           Self.isValidSkillSlug(skillSlug) == false {
            return false
        }
        if let usage = record.skillUsage,
           Self.isValidStoredUsage(usage, current: current) == false {
            return false
        }
        return Self.materializationIsConsistent(
            proposal: proposal,
            externalMemoryID: record.externalMemoryID,
            skillSlug: record.skillSlug,
            lifecycle: record.skillLifecycle,
            usage: record.skillUsage,
            pinned: record.pinned
        )
    }

    private func isValidStoredSnapshot(
        _ snapshot: SafariLearningProposalSnapshot,
        current: Date
    ) throws -> Bool {
        guard Self.isValidStoredProposal(snapshot.proposal, current: current),
              snapshot.capturedAt >= snapshot.proposal.updatedAt,
              snapshot.capturedAt <= current else {
            return false
        }
        if let externalMemoryID = snapshot.externalMemoryID,
           Self.isStoredIdentifier(externalMemoryID) == false {
            return false
        }
        if let skillSlug = snapshot.skillSlug,
           Self.isValidSkillSlug(skillSlug) == false {
            return false
        }
        if let usage = snapshot.skillUsage,
           Self.isValidStoredUsage(usage, current: current) == false {
            return false
        }
        return Self.materializationIsConsistent(
            proposal: snapshot.proposal,
            externalMemoryID: snapshot.externalMemoryID,
            skillSlug: snapshot.skillSlug,
            lifecycle: snapshot.skillLifecycle,
            usage: snapshot.skillUsage,
            pinned: snapshot.pinned
        )
    }

    private static func isValidStoredProposal(
        _ proposal: BurnBarSafariLearningProposal,
        current: Date
    ) -> Bool {
        guard proposal.version >= 1,
              isStoredIdentifier(proposal.proposalId),
              isStoredIdentifier(proposal.sourceObservationId),
              isPersistableText(
                  proposal.title,
                  minimumBytes: 1,
                  maximumBytes: maximumTitleBytes
              ),
              isPersistableText(
                  proposal.content,
                  minimumBytes: 8,
                  maximumBytes: maximumContentBytes
              ),
              SafariLearningSecurity.isNoisyObservation(proposal.content)
                == false,
              isPersistableText(
                  proposal.reason,
                  minimumBytes: 8,
                  maximumBytes: maximumReasonBytes
              ),
              isPersistableText(
                  proposal.expectedOutcome,
                  minimumBytes: 8,
                  maximumBytes: maximumExpectedOutcomeBytes
              ),
              proposal.sourceURL.utf8.count <= maximumSourceURLBytes,
              let origin = try? originURL(proposal.sourceURL),
              origin.absoluteString == proposal.sourceURL,
              proposal.createdAt <= proposal.updatedAt,
              proposal.updatedAt <= current else {
            return false
        }
        return true
    }

    private static func materializationIsConsistent(
        proposal: BurnBarSafariLearningProposal,
        externalMemoryID: String?,
        skillSlug: String?,
        lifecycle: SafariLearningSkillLifecycle?,
        usage: SafariLearningSkillUsage?,
        pinned: Bool
    ) -> Bool {
        switch proposal.kind {
        case .memory, .siteRule:
            guard skillSlug == nil,
                  lifecycle == nil,
                  usage == nil,
                  pinned == false,
                  proposal.reviewStatus != .archived else {
                return false
            }
            return proposal.reviewStatus == .approved
                ? externalMemoryID != nil
                : externalMemoryID == nil
        case .skill:
            guard externalMemoryID == nil, skillSlug != nil else {
                return false
            }
            switch proposal.reviewStatus {
            case .proposed:
                return lifecycle == nil && usage == nil
            case .approved:
                return (lifecycle == .active || lifecycle == .stale)
                    && usage != nil
            case .rejected:
                return (lifecycle == nil && usage == nil)
                    || (lifecycle == .quarantined && usage == nil)
            case .archived:
                return lifecycle == .archived && usage != nil
            }
        }
    }

    private static func isValidStoredUsage(
        _ usage: SafariLearningSkillUsage,
        current: Date
    ) -> Bool {
        guard usage.useCount >= 0,
              usage.viewCount >= 0,
              usage.patchCount >= 0,
              usage.updatedAt <= current else {
            return false
        }
        if let lastUsedAt = usage.lastUsedAt {
            return lastUsedAt <= usage.updatedAt
        }
        return true
    }

    private static func isPersistableText(
        _ text: String,
        minimumBytes: Int,
        maximumBytes: Int
    ) -> Bool {
        guard text.utf8.count >= minimumBytes,
              text.utf8.count <= maximumBytes,
              text.trimmingCharacters(in: .whitespacesAndNewlines) == text,
              let sanitized = try? SafariLearningSecurity.sanitizeForPersistence(
                  text
              ) else {
            return false
        }
        return sanitized.text == text
            && sanitized.redactionFindingIDs.isEmpty
    }

    private static func isStoredIdentifier(_ raw: String) -> Bool {
        isBoundedControlFree(raw, maximumBytes: maximumIdentifierBytes)
            && raw.trimmingCharacters(in: .whitespacesAndNewlines) == raw
            && raw.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn:
                        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:"
                ).contains($0)
            }
    }

    private static func isSafeRecallIdentifier(_ raw: String) -> Bool {
        isStoredIdentifier(raw)
    }

    private static func isValidSkillSlug(_ raw: String) -> Bool {
        guard raw.utf8.count >= 1,
              raw.utf8.count <= 64,
              raw.first?.isLetter == true || raw.first?.isNumber == true,
              raw.last?.isLetter == true || raw.last?.isNumber == true,
              raw.contains("--") == false else {
            return false
        }
        return raw.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
                .contains($0)
        }
    }

    private static func isBoundedControlFree(
        _ raw: String,
        maximumBytes: Int
    ) -> Bool {
        raw.isEmpty == false
            && raw.utf8.count <= maximumBytes
            && raw.unicodeScalars.allSatisfy {
                CharacterSet.controlCharacters.contains($0) == false
            }
    }

    // MARK: - Small deterministic helpers

    private static func validateIdentifier(
        _ raw: String,
        field: String
    ) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == raw,
              trimmed.isEmpty == false,
              trimmed.utf8.count <= Self.maximumIdentifierBytes,
              trimmed.unicodeScalars.allSatisfy({
                  CharacterSet.controlCharacters.contains($0) == false
              }) else {
            throw SafariLearningCoordinatorError.invalidObservation(
                "\(field) is invalid"
            )
        }
    }

    private static func validatedTags(_ rawTags: [String]) throws -> [String] {
        guard rawTags.count <= Self.maximumTagCount else {
            throw SafariLearningCoordinatorError.invalidObservation(
                "too many tags"
            )
        }
        var tags: [String] = []
        var seen = Set<String>()
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-"
        )
        for raw in rawTags {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard tag.isEmpty == false,
                  tag.utf8.count <= Self.maximumTagBytes,
                  tag.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw SafariLearningCoordinatorError.invalidObservation(
                    "tag contains unsupported characters or exceeds the size limit"
                )
            }
            let key = tag.lowercased()
            if seen.insert(key).inserted {
                tags.append(tag)
            }
        }
        return tags
    }

    private static func originString(from url: URL) throws -> String {
        guard let origin = try? originURL(url.absoluteString) else {
            throw SafariLearningCoordinatorError.invalidObservation(
                "source URL has no valid origin"
            )
        }
        return origin.absoluteString
    }

    private static func originURL(_ raw: String) throws -> URL {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              host.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            throw SafariLearningCoordinatorError.invalidObservation(
                "source origin is invalid"
            )
        }
        components.scheme = scheme
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        guard let origin = components.url else {
            throw SafariLearningCoordinatorError.invalidObservation(
                "source origin is invalid"
            )
        }
        return origin
    }

    private func normalizedForDedup(_ raw: String) -> String {
        Self.normalizedForDedup(raw)
    }

    private static func normalizedForDedup(_ raw: String) -> String {
        raw.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .lowercased()
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    }

    private static func stableDigest(_ raw: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func queryTokens(_ query: String) -> [String] {
        let tokens = query
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            .lowercased()
            .split { character in
                character.isWhitespace || character.isPunctuation
            }
            .map(String.init)
            .filter { $0.count >= 2 }
        return Array(Set(tokens)).sorted()
    }

    private static func isGrounded(candidate: String, evidence: String) -> Bool {
        func tokens(_ text: String) -> Set<String> {
            Set(
                text.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                .lowercased()
                .split { character in
                    character.isWhitespace || character.isPunctuation
                }
                .map(String.init)
                .filter { $0.count >= 4 }
            )
        }
        let evidenceTokens = tokens(evidence)
        let candidateTokens = tokens(candidate)
        guard evidenceTokens.isEmpty == false,
              candidateTokens.isEmpty == false else {
            return false
        }
        let overlap = evidenceTokens.intersection(candidateTokens).count
        return overlap >= min(2, evidenceTokens.count)
    }
}

private extension BurnBarSafariLearningProposal {
    func historyVersionOrderIsValid(
        _ history: [SafariLearningProposalSnapshot]
    ) -> Bool {
        let versions = history.map(\.proposal.version)
        guard Set(versions).count == versions.count,
              versions.allSatisfy({ $0 >= 1 && $0 < version }) else {
            return false
        }
        return zip(versions, versions.dropFirst()).allSatisfy {
            $0.0 < $0.1
        }
    }
}
