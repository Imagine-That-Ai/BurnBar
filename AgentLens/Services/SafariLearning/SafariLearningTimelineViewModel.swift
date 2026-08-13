import Foundation
import Observation
import OpenBurnBarKernel

@Observable
@MainActor
final class SafariLearningTimelineViewModel {
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all
        case proposed
        case active
        case archived

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .proposed: "Proposed"
            case .active: "Active"
            case .archived: "Archived"
            }
        }

        func includes(_ status: BurnBarSafariLearningReviewStatus) -> Bool {
            switch self {
            case .all:
                true
            case .proposed:
                status == .proposed
            case .active:
                status == .approved
            case .archived:
                status == .archived || status == .rejected
            }
        }
    }

    enum ProfileMutation: Equatable, Sendable {
        case enabling
        case pausing
        case deleting

        var progressLabel: String {
            switch self {
            case .enabling: "Turning learning on…"
            case .pausing: "Pausing learning…"
            case .deleting: "Deleting learned profile…"
            }
        }
    }

    struct Banner: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case success
            case warning
            case error
        }

        let id = UUID()
        let kind: Kind
        let title: String
        let message: String
    }

    private(set) var enabled = false
    private(set) var tier = "free"
    private(set) var proposals: [BurnBarSafariLearningProposal] = []
    private(set) var visibleProposals: [BurnBarSafariLearningProposal] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var mutatingProposalIDs: Set<String> = []
    private(set) var profileMutation: ProfileMutation?
    private(set) var banner: Banner?
    private(set) var editDraft: SafariLearningEditDraft?

    var filter: Filter = .all {
        didSet {
            guard filter != oldValue else { return }
            rebuildVisibleProposals()
        }
    }

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            rebuildVisibleProposals()
        }
    }

    @ObservationIgnored private let client: any SafariLearningTimelineClient
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var searchIndex: [String: String] = [:]

    init(client: any SafariLearningTimelineClient) {
        self.client = client
    }

    var normalizedTier: String {
        tier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    var tierDisplayName: String {
        switch normalizedTier {
        case "pro", "burnbar_pro":
            "Pro"
        case "pro_max", "promax", "burnbar_pro_max":
            "Pro Max"
        case "ultra", "burnbar_ultra":
            "Ultra"
        case "", "free":
            "Free"
        default:
            tier
        }
    }

    var isEligibleTier: Bool {
        switch normalizedTier {
        case "pro", "burnbar_pro",
             "pro_max", "promax", "burnbar_pro_max",
             "ultra", "burnbar_ultra":
            true
        default:
            false
        }
    }

    var proposedCount: Int {
        proposals.lazy.filter { $0.reviewStatus == .proposed }.count
    }

    var activeCount: Int {
        proposals.lazy.filter { $0.reviewStatus == .approved }.count
    }

    var archivedCount: Int {
        proposals.lazy.filter {
            $0.reviewStatus == .archived || $0.reviewStatus == .rejected
        }.count
    }

    var profileActionsDisabled: Bool {
        profileMutation != nil || mutatingProposalIDs.isEmpty == false
    }

    var hasActiveSearch: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func count(for filter: Filter) -> Int {
        proposals.lazy.filter { filter.includes($0.reviewStatus) }.count
    }

    func isMutating(_ proposalID: String) -> Bool {
        profileMutation != nil || mutatingProposalIDs.contains(proposalID)
    }

    func load() async {
        await reload(presentFailure: true)
    }

    func refresh() async {
        await reload(presentFailure: true)
    }

    func dismissBanner() {
        banner = nil
    }

    func beginEditing(_ proposal: BurnBarSafariLearningProposal) {
        guard enabled else {
            banner = Banner(
                kind: .warning,
                title: "Learning is paused",
                message: "Turn learning on before editing an item."
            )
            return
        }
        guard proposal.reviewStatus == .proposed
                || proposal.reviewStatus == .approved else {
            banner = Banner(
                kind: .warning,
                title: "This item is read-only",
                message: "Rejected and archived learning can be reviewed, forgotten, or rolled back, but not edited in place."
            )
            return
        }
        guard !isMutating(proposal.proposalId) else { return }
        editDraft = SafariLearningEditDraft(proposal: proposal)
    }

    func cancelEditing() {
        guard editDraft?.isSaving != true else { return }
        editDraft = nil
    }

    func reloadCurrentVersionForEditor() {
        guard let draft = editDraft,
              let current = proposals.first(where: {
                  $0.proposalId == draft.proposalID
              }) else {
            editDraft?.setError(
                "This learning item no longer exists. Close the editor to continue.",
                conflict: true
            )
            return
        }
        draft.reset(to: current)
    }

    func saveEdit() async {
        guard enabled else {
            editDraft?.setError(
                "Learning is paused. Turn it on before saving a new version.",
                conflict: false
            )
            return
        }
        guard let draft = editDraft,
              draft.canSave,
              !isMutating(draft.proposalID) else {
            return
        }

        let proposalID = draft.proposalID
        mutatingProposalIDs.insert(proposalID)
        draft.beginSaving()
        defer {
            mutatingProposalIDs.remove(proposalID)
            draft.finishSaving()
        }

        do {
            let response = try await client.update(
                BurnBarSafariLearningUpdateRequest(
                    proposalId: proposalID,
                    expectedVersion: draft.expectedVersion,
                    title: draft.trimmedTitle,
                    content: draft.trimmedContent
                )
            )
            replace(response.proposal)
            editDraft = nil
            banner = Banner(
                kind: .success,
                title: "Learning refined",
                message: "Version \(response.proposal.version) is now the daemon-authoritative item."
            )
        } catch {
            if Self.isVersionConflict(error) {
                await reload(presentFailure: false)
                draft.setError(
                    "This item changed while you were editing it. Review the current version before saving again.",
                    conflict: true
                )
                banner = Banner(
                    kind: .warning,
                    title: "This item changed",
                    message: "Your draft is still here. Compare it with the refreshed daemon version, then reload the current version when you are ready."
                )
            } else {
                draft.setError(
                    Self.friendlyMutationMessage(
                        error,
                        fallback: "OpenBurnBar could not save this learning edit."
                    ),
                    conflict: false
                )
            }
        }
    }

    func approve(_ proposal: BurnBarSafariLearningProposal) async {
        guard proposal.reviewStatus == .proposed else { return }
        await mutate(
            proposal,
            requiresEnabledProfile: true,
            successTitle: "Learning approved",
            successMessage: "“\(proposal.title)” is active and can inform future Safari sessions."
        ) { client in
            try await client.approve(
                BurnBarSafariLearningMutationRequest(
                    proposalId: proposal.proposalId,
                    expectedVersion: proposal.version
                )
            )
        }
    }

    func reject(_ proposal: BurnBarSafariLearningProposal) async {
        guard proposal.reviewStatus == .proposed else { return }
        await mutate(
            proposal,
            requiresEnabledProfile: false,
            successTitle: "Proposal rejected",
            successMessage: "The proposal remains in history and will not become active."
        ) { client in
            try await client.reject(
                BurnBarSafariLearningMutationRequest(
                    proposalId: proposal.proposalId,
                    expectedVersion: proposal.version
                )
            )
        }
    }

    func rollbackToPreviousVersion(
        _ proposal: BurnBarSafariLearningProposal
    ) async {
        guard proposal.version > 1 else { return }
        let targetVersion = proposal.version - 1
        await mutate(
            proposal,
            requiresEnabledProfile: true,
            successTitle: "Earlier version restored",
            successMessage: "Version \(targetVersion) was restored as a new, auditable version."
        ) { client in
            try await client.rollback(
                BurnBarSafariLearningRollbackRequest(
                    proposalId: proposal.proposalId,
                    targetVersion: targetVersion
                )
            )
        }
    }

    func forget(_ proposal: BurnBarSafariLearningProposal) async {
        guard !isMutating(proposal.proposalId),
              profileMutation == nil else {
            return
        }

        mutatingProposalIDs.insert(proposal.proposalId)
        defer { mutatingProposalIDs.remove(proposal.proposalId) }

        do {
            _ = try await client.forget(
                BurnBarSafariLearningForgetRequest(
                    proposalId: proposal.proposalId,
                    expectedVersion: proposal.version
                )
            )
            remove(proposal.proposalId)
            if editDraft?.proposalID == proposal.proposalId {
                editDraft = nil
            }
            banner = Banner(
                kind: .success,
                title: "Learning forgotten",
                message: "The item and its active memory or skill materialization were removed."
            )
        } catch {
            await reconcileMutationFailure(
                error,
                fallback: "OpenBurnBar could not forget this learning item."
            )
        }
    }

    func optIn() async {
        guard isEligibleTier,
              !profileActionsDisabled else {
            if !isEligibleTier {
                banner = Banner(
                    kind: .warning,
                    title: "Pro or higher is required",
                    message: "Safari learning stays session-only on the \(tierDisplayName) tier."
                )
            }
            return
        }

        await mutateProfile(.enabling) {
            try await self.client.optIn()
        } apply: { response in
            self.enabled = response.enabled
            self.tier = response.tier
            self.banner = Banner(
                kind: .success,
                title: "Learning is on",
                message: "Only explicit, reviewable high-signal proposals can enter your learned profile."
            )
        }
    }

    func pauseLearning() async {
        guard enabled, !profileActionsDisabled else { return }
        await mutateProfile(.pausing) {
            try await self.client.optOut(deleteLearnedProfile: false)
        } apply: { response in
            self.enabled = response.enabled
            self.tier = response.tier
            self.banner = Banner(
                kind: .success,
                title: "Learning paused",
                message: "Existing learned items remain reviewable, but Safari will not create or recall durable learning."
            )
        }
    }

    func deleteLearnedProfile() async {
        guard !profileActionsDisabled else { return }
        await mutateProfile(.deleting) {
            try await self.client.optOut(deleteLearnedProfile: true)
        } apply: { response in
            self.enabled = response.enabled
            self.tier = response.tier
            self.proposals = []
            self.searchIndex = [:]
            self.rebuildVisibleProposals()
            self.editDraft = nil
            self.banner = Banner(
                kind: .success,
                title: "Learned profile deleted",
                message: "\(response.deletedEntryCount) learned item\(response.deletedEntryCount == 1 ? "" : "s") and their active materializations were removed."
            )
        }
    }

    private func reload(presentFailure: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        let firstLoad = !hasLoaded
        if firstLoad {
            isLoading = true
        } else {
            isRefreshing = true
        }
        defer {
            if generation == loadGeneration {
                isLoading = false
                isRefreshing = false
            }
        }

        do {
            let response = try await client.timeline()
            guard generation == loadGeneration else { return }
            apply(response)
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            if presentFailure {
                banner = Banner(
                    kind: .error,
                    title: hasLoaded
                        ? "Could not refresh learning"
                        : "Learning is unavailable",
                    message: Self.friendlyLoadMessage(error)
                )
            }
        }
    }

    private func apply(_ response: BurnBarSafariLearningTimelineResponse) {
        enabled = response.enabled
        tier = response.tier
        proposals = Self.sorted(response.proposals)
        rebuildSearchIndex()
        rebuildVisibleProposals()
    }

    private func mutate(
        _ proposal: BurnBarSafariLearningProposal,
        requiresEnabledProfile: Bool,
        successTitle: String,
        successMessage: String,
        operation: @escaping @Sendable (
            any SafariLearningTimelineClient
        ) async throws -> BurnBarSafariLearningProposalResponse
    ) async {
        guard !isMutating(proposal.proposalId),
              profileMutation == nil else {
            return
        }
        guard !requiresEnabledProfile || enabled else {
            banner = Banner(
                kind: .warning,
                title: "Learning is paused",
                message: "Turn learning on before approving, editing, or rolling back an item."
            )
            return
        }

        mutatingProposalIDs.insert(proposal.proposalId)
        defer { mutatingProposalIDs.remove(proposal.proposalId) }

        do {
            let response = try await operation(client)
            replace(response.proposal)
            banner = Banner(
                kind: .success,
                title: successTitle,
                message: successMessage
            )
        } catch {
            await reconcileMutationFailure(
                error,
                fallback: "OpenBurnBar could not update this learning item."
            )
        }
    }

    private func reconcileMutationFailure(
        _ error: Error,
        fallback: String
    ) async {
        let conflict = Self.isVersionConflict(error)
        if conflict {
            await reload(presentFailure: false)
        }
        banner = Banner(
            kind: conflict ? .warning : .error,
            title: conflict ? "This item changed" : "Learning update failed",
            message: conflict
                ? "The timeline was refreshed with the current daemon version. Review it and try again."
                : Self.friendlyMutationMessage(error, fallback: fallback)
        )
    }

    private func mutateProfile(
        _ mutation: ProfileMutation,
        operation: () async throws -> BurnBarSafariLearningStateResponse,
        apply: (BurnBarSafariLearningStateResponse) -> Void
    ) async {
        profileMutation = mutation
        defer { profileMutation = nil }
        do {
            apply(try await operation())
        } catch {
            banner = Banner(
                kind: .error,
                title: "Profile update failed",
                message: Self.friendlyMutationMessage(
                    error,
                    fallback: "OpenBurnBar could not update your Safari learning profile."
                )
            )
        }
    }

    private func replace(_ proposal: BurnBarSafariLearningProposal) {
        if let index = proposals.firstIndex(where: {
            $0.proposalId == proposal.proposalId
        }) {
            proposals[index] = proposal
        } else {
            proposals.append(proposal)
        }
        proposals = Self.sorted(proposals)
        searchIndex[proposal.proposalId] = Self.searchDocument(for: proposal)
        rebuildVisibleProposals()
    }

    private func remove(_ proposalID: String) {
        proposals.removeAll { $0.proposalId == proposalID }
        searchIndex.removeValue(forKey: proposalID)
        rebuildVisibleProposals()
    }

    private func rebuildSearchIndex() {
        searchIndex = Dictionary(
            uniqueKeysWithValues: proposals.map {
                ($0.proposalId, Self.searchDocument(for: $0))
            }
        )
    }

    private func rebuildVisibleProposals() {
        let query = Self.normalizedSearch(searchText)
        visibleProposals = proposals.filter { proposal in
            guard filter.includes(proposal.reviewStatus) else { return false }
            guard !query.isEmpty else { return true }
            return searchIndex[proposal.proposalId]?.contains(query) == true
        }
    }

    private static func sorted(
        _ proposals: [BurnBarSafariLearningProposal]
    ) -> [BurnBarSafariLearningProposal] {
        proposals.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.proposalId < rhs.proposalId
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private static func searchDocument(
        for proposal: BurnBarSafariLearningProposal
    ) -> String {
        normalizedSearch(
            [
                proposal.title,
                proposal.content,
                proposal.reason,
                proposal.expectedOutcome,
                proposal.sourceURL,
                proposal.kind.rawValue,
                proposal.reviewStatus.rawValue
            ].joined(separator: "\n")
        )
    }

    private static func normalizedSearch(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
    }

    private static func isVersionConflict(_ error: Error) -> Bool {
        let description = error.localizedDescription.lowercased()
        return description.contains("proposal changed")
            || description.contains("expected version")
            || description.contains("version conflict")
    }

    private static func friendlyLoadMessage(_ error: Error) -> String {
        let description = error.localizedDescription
        let normalized = description.lowercased()
        if normalized.contains("timed out") {
            return "The local OpenBurnBar daemon did not respond in time. Retry after it finishes starting."
        }
        if normalized.contains("connect failed")
            || normalized.contains("connection refused")
            || normalized.contains("no such file") {
            return "The local OpenBurnBar daemon is not reachable yet. Keep the app open, then retry."
        }
        return "OpenBurnBar could not load the learned profile. \(strippedRPCPrefix(description))"
    }

    private static func friendlyMutationMessage(
        _ error: Error,
        fallback: String
    ) -> String {
        let description = error.localizedDescription
        let normalized = description.lowercased()
        if normalized.contains("timed out") {
            return "\(fallback) The local daemon did not respond in time."
        }
        if normalized.contains("connect failed")
            || normalized.contains("connection refused")
            || normalized.contains("no such file") {
            return "\(fallback) The local daemon is not reachable yet."
        }
        return "\(fallback) \(strippedRPCPrefix(description))"
    }

    private static func strippedRPCPrefix(_ description: String) -> String {
        description
            .replacingOccurrences(
                of: "OpenBurnBarDaemon RPC error: ",
                with: ""
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Observable
@MainActor
final class SafariLearningEditDraft: Identifiable {
    static let maximumTitleBytes = 256
    static let minimumContentBytes = 8
    static let maximumContentBytes = 16 * 1024

    let proposalID: String
    private(set) var expectedVersion: Int
    private(set) var kind: BurnBarSafariLearningProposalKind
    private(set) var reviewStatus: BurnBarSafariLearningReviewStatus
    private(set) var originalTitle: String
    private(set) var originalContent: String
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var hasConflict = false
    var title: String
    var content: String

    nonisolated var id: String { proposalID }

    init(proposal: BurnBarSafariLearningProposal) {
        proposalID = proposal.proposalId
        expectedVersion = proposal.version
        kind = proposal.kind
        reviewStatus = proposal.reviewStatus
        originalTitle = proposal.title
        originalContent = proposal.content
        title = proposal.title
        content = proposal.content
    }

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var titleByteCount: Int { trimmedTitle.utf8.count }
    var contentByteCount: Int { trimmedContent.utf8.count }

    var hasChanges: Bool {
        trimmedTitle != originalTitle || trimmedContent != originalContent
    }

    var validationMessage: String? {
        if trimmedTitle.isEmpty {
            return "Add a concise title."
        }
        if titleByteCount > Self.maximumTitleBytes {
            return "The title must be at most \(Self.maximumTitleBytes) UTF-8 bytes."
        }
        if contentByteCount < Self.minimumContentBytes {
            return "The learned content must be at least \(Self.minimumContentBytes) UTF-8 bytes."
        }
        if contentByteCount > Self.maximumContentBytes {
            return "The learned content must be at most \(Self.maximumContentBytes) UTF-8 bytes."
        }
        if !hasChanges {
            return "Change the title or content before saving."
        }
        return nil
    }

    var canSave: Bool {
        validationMessage == nil && !isSaving && !hasConflict
    }

    func beginSaving() {
        isSaving = true
        errorMessage = nil
        hasConflict = false
    }

    func finishSaving() {
        isSaving = false
    }

    func setError(_ message: String, conflict: Bool) {
        errorMessage = message
        hasConflict = conflict
    }

    func reset(to proposal: BurnBarSafariLearningProposal) {
        guard proposal.proposalId == proposalID else { return }
        expectedVersion = proposal.version
        kind = proposal.kind
        reviewStatus = proposal.reviewStatus
        originalTitle = proposal.title
        originalContent = proposal.content
        title = proposal.title
        content = proposal.content
        errorMessage = nil
        hasConflict = false
    }
}
