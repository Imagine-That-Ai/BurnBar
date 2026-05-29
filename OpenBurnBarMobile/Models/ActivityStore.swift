import Foundation
import OpenBurnBarCore
import FirebaseAuth
import FirebaseFirestore

@Observable
@MainActor
final class ActivityStore {
    private let firestore: FirestoreRepository
    private let functions: FunctionsRepository
    private let vault: CloudVaultGateway

    private(set) var isLoading = false
    private(set) var isSearching = false
    private(set) var error: String?
    private(set) var rawUsages: [TokenUsage] = []
    private(set) var liveUsages: [TokenUsage] = []
    private(set) var usages: [TokenUsage] = []
    private(set) var searchHits: [StreamSearchHit] = []
    private(set) var cloudSearchHits: [CloudConversationSearchRow] = []
    private(set) var hasMore = true
    private var lastDoc: DocumentSnapshot?
    private var liveUsageListener: ListenerRegistration?
    private let targetSessionPageSize = 25
    private let rawPageSize = 100
    private let maxRawPagesPerBatch = 6
    private var lastSearchQuery = ""

    /// Optional provider filter applied to the next fetch. The view binds
    /// directly to this and calls `applyFilters()` to re-query.
    var filterProvider: AgentProvider?
    var filterStartDate: Date?
    var filterEndDate: Date?

    init(
        firestore: FirestoreRepository = FirestoreRepository(),
        functions: FunctionsRepository = FunctionsRepository()
    ) {
        self.firestore = firestore
        self.functions = functions
        self.vault = CloudVaultGateway(functions: functions)
    }

    /// Convenience alias used by `.task` and pull-to-refresh on first load.
    func loadInitial() async {
        await refresh()
    }

    /// Fetches the next page when the user reaches the bottom of the list.
    func loadNext() async {
        await loadMore()
    }

    func load() async {
        if AppStoreScreenshotMode.isEnabled {
            isLoading = false
            error = nil
            rawUsages = AppStoreScreenshotData.recentUsage
            liveUsages = AppStoreScreenshotData.recentUsage
            usages = Self.summarizeSessions(rawUsages)
            lastDoc = nil
            hasMore = false
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let batch = try await fetchRawBatch(after: nil, existingSessionKeys: [])
            rawUsages = batch.rows
            if liveUsages.isEmpty {
                liveUsages = batch.rows
            }
            usages = Self.summarizeSessions(rawUsages)
            lastDoc = batch.last
            hasMore = batch.hasMore
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        guard !AppStoreScreenshotMode.isEnabled else { return }
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let batch = try await fetchRawBatch(
                after: lastDoc,
                existingSessionKeys: Set(rawUsages.map(Self.sessionKey))
            )
            rawUsages.append(contentsOf: batch.rows)
            usages = Self.summarizeSessions(rawUsages)
            lastDoc = batch.last
            hasMore = batch.hasMore
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refresh() async {
        if AppStoreScreenshotMode.isEnabled {
            await load()
            return
        }
        lastDoc = nil
        rawUsages = []
        usages = []
        hasMore = true
        await load()
    }

    func loadLiveUsage(since startDate: Date) async {
        if AppStoreScreenshotMode.isEnabled {
            liveUsages = AppStoreScreenshotData.recentUsage
            return
        }
        do {
            liveUsages = try await firestore.fetchUsageSince(startDate)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func startLiveUsageListening(since startDate: Date) {
        guard !AppStoreScreenshotMode.isEnabled else {
            liveUsages = AppStoreScreenshotData.recentUsage
            return
        }
        liveUsageListener?.remove()
        liveUsageListener = firestore.listenToUsageSince(startDate) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let rows):
                self.liveUsages = rows
                self.error = nil
            case .failure(let error):
                self.error = error.localizedDescription
            }
        }
    }

    func stopLiveUsageListening() {
        liveUsageListener?.remove()
        liveUsageListener = nil
    }

    /// Re-runs the query with the current `filter*` properties. Called by
    /// the FilterSheet's Done button.
    func applyFilters() async {
        await refresh()
    }

    func updateSearch(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSearchQuery = trimmed
        guard trimmed.count >= 2 else {
            searchHits = []
            cloudSearchHits = []
            isSearching = false
            return
        }

        isSearching = true
        do {
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()
            guard lastSearchQuery == trimmed else { return }
            async let streamHits = functions.searchStreams(query: trimmed)
            async let cloudHits = searchEncryptedCloudIndex(query: trimmed)
            searchHits = (try? await streamHits) ?? []
            cloudSearchHits = (try? await cloudHits) ?? []
        } catch is CancellationError {
            return
        } catch {
            searchHits = []
            cloudSearchHits = []
        }
        isSearching = false
    }

    private func searchEncryptedCloudIndex(query: String) async throws -> [CloudConversationSearchRow] {
        guard let vaultKey = try await unlockCloudVaultKeyIfAvailable() else { return [] }
        let tokenHashes = try CloudVaultCrypto.tokenHashes(for: query, keyData: vaultKey, limit: 10)
        let semanticHashes = try CloudVaultCrypto.semanticHashes(for: query, keyData: vaultKey, limit: 12)
        guard tokenHashes.isEmpty == false || semanticHashes.isEmpty == false else { return [] }
        let hits = try await functions.searchEncryptedConversationIndex(
            tokenHashes: tokenHashes,
            semanticHashes: semanticHashes
        )
        return hits.compactMap { hit in
            guard let title = try? CloudVaultCrypto.openText(hit.sealedTitle, keyData: vaultKey),
                  let snippet = try? CloudVaultCrypto.openText(hit.sealedSnippet, keyData: vaultKey) else {
                return nil
            }
            return CloudConversationSearchRow(
                id: hit.id,
                title: title,
                snippet: snippet,
                provider: hit.provider,
                projectName: hit.projectName,
                storagePath: hit.storagePath,
                bodyHash: hit.bodyHash,
                score: hit.score
            )
        }
    }

    func loadCloudConversationBody(for row: CloudConversationSearchRow) async throws -> String {
        guard let vaultKey = try await vault.unlockKey() else {
            throw CloudConversationSearchError.vaultKeyUnavailable
        }
        return try await vault.downloadBody(storagePath: row.storagePath, bodyHash: row.bodyHash, vaultKey: vaultKey)
    }

    private func unlockCloudVaultKeyIfAvailable() async throws -> Data? {
        try await vault.unlockKey()
    }

    private func fetchRawBatch(
        after: DocumentSnapshot?,
        existingSessionKeys: Set<String>
    ) async throws -> (rows: [TokenUsage], last: DocumentSnapshot?, hasMore: Bool) {
        var rows: [TokenUsage] = []
        var cursor = after
        var last = after
        var hitEnd = false
        var sessionKeys = existingSessionKeys
        let startingSessionCount = sessionKeys.count

        for _ in 0..<maxRawPagesPerBatch {
            let (page, pageLast) = try await firestore.fetchUsagePage(
                pageSize: rawPageSize,
                after: cursor,
                provider: filterProvider?.rawValue,
                model: nil,
                device: nil,
                startDate: filterStartDate,
                endDate: filterEndDate
            )

            if page.isEmpty {
                hitEnd = true
                last = pageLast ?? cursor
                break
            }

            rows.append(contentsOf: page)
            page.forEach { sessionKeys.insert(Self.sessionKey(for: $0)) }
            cursor = pageLast
            last = pageLast

            if page.count < rawPageSize {
                hitEnd = true
                break
            }
            if sessionKeys.count - startingSessionCount >= targetSessionPageSize {
                break
            }
        }

        return (rows, last, !hitEnd && last != nil)
    }

    nonisolated static func summarizeSessions(_ rows: [TokenUsage]) -> [TokenUsage] {
        var groups: [String: [TokenUsage]] = [:]
        for row in rows {
            groups[sessionKey(for: row), default: []].append(row)
        }

        return groups.values
            .compactMap(sessionSummary)
            .sorted { activityDate(for: $0) > activityDate(for: $1) }
    }

    nonisolated static func sessionKey(for usage: TokenUsage) -> String {
        let sessionID = usage.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sessionID.isEmpty == false else {
            return "\(usage.provider.rawValue)|row|\(usage.id.uuidString)"
        }
        return "\(usage.provider.rawValue)|\(sessionID)"
    }

    nonisolated static func activityDate(for usage: TokenUsage) -> Date {
        max(usage.startTime, usage.endTime)
    }

    nonisolated private static func sessionSummary(from rows: [TokenUsage]) -> TokenUsage? {
        guard let latest = rows.max(by: { activityDate(for: $0) < activityDate(for: $1) }) else {
            return nil
        }
        let earliestStart = rows.map { min($0.startTime, $0.endTime) }.min() ?? latest.startTime
        let latestEnd = rows.map { max($0.startTime, $0.endTime) }.max() ?? latest.endTime
        let inputTokens = rows.reduce(0) { $0 + $1.inputTokens }
        let outputTokens = rows.reduce(0) { $0 + $1.outputTokens }
        let cacheCreationTokens = rows.reduce(0) { $0 + $1.cacheCreationTokens }
        let cacheReadTokens = rows.reduce(0) { $0 + $1.cacheReadTokens }
        let reasoningTokens = rows.reduce(0) { $0 + $1.reasoningTokens }
        let totalCost = rows.reduce(0) { $0 + $1.cost }
        let createdAt = rows.map(\.createdAt).max() ?? latest.createdAt

        return TokenUsage(
            id: latest.id,
            provider: latest.provider,
            sessionId: latest.sessionId,
            projectName: latestNonBlank(rows, \.projectName) ?? latest.projectName,
            model: dominantModel(in: rows, fallback: latest.model),
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            costUSD: totalCost,
            startTime: earliestStart,
            endTime: latestEnd,
            createdAt: createdAt,
            usageSource: latest.usageSource,
            sourceDeviceId: latestNonBlank(rows, \.sourceDeviceId) ?? latest.sourceDeviceId,
            sourceDeviceName: latestNonBlank(rows, \.sourceDeviceName) ?? latest.sourceDeviceName,
            isRemote: rows.contains(where: \.isRemote),
            providerID: latest.providerID,
            providerAccountID: latestNonBlank(rows, \.providerAccountID) ?? latest.providerAccountID,
            providerAccountLabel: latestNonBlank(rows, \.providerAccountLabel) ?? latest.providerAccountLabel,
            providerAccountSource: latest.providerAccountSource,
            provenanceMethod: rows.map(\.provenanceMethod).max() ?? latest.provenanceMethod,
            provenanceConfidence: rows.map(\.provenanceConfidence).max() ?? latest.provenanceConfidence,
            estimatorVersion: latestNonBlank(rows, \.estimatorVersion) ?? latest.estimatorVersion
        )
    }

    nonisolated private static func dominantModel(in rows: [TokenUsage], fallback: String) -> String {
        struct ModelStats {
            var tokens = 0
            var cost = 0.0
            var lastSeen = Date.distantPast
        }

        let stats = rows.reduce(into: [String: ModelStats]()) { result, row in
            let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard model.isEmpty == false else { return }
            var current = result[model] ?? ModelStats()
            current.tokens += row.totalTokens
            current.cost += row.cost
            current.lastSeen = max(current.lastSeen, activityDate(for: row))
            result[model] = current
        }

        return stats.sorted { lhs, rhs in
            if lhs.value.tokens != rhs.value.tokens { return lhs.value.tokens > rhs.value.tokens }
            if lhs.value.cost != rhs.value.cost { return lhs.value.cost > rhs.value.cost }
            return lhs.value.lastSeen > rhs.value.lastSeen
        }.first?.key ?? fallback
    }

    nonisolated private static func latestNonBlank(
        _ rows: [TokenUsage],
        _ keyPath: KeyPath<TokenUsage, String>
    ) -> String? {
        latestNonBlank(rows) { $0[keyPath: keyPath] }
    }

    nonisolated private static func latestNonBlank(
        _ rows: [TokenUsage],
        _ keyPath: KeyPath<TokenUsage, String?>
    ) -> String? {
        latestNonBlank(rows) { $0[keyPath: keyPath] }
    }

    nonisolated private static func latestNonBlank(
        _ rows: [TokenUsage],
        value: (TokenUsage) -> String?
    ) -> String? {
        rows
            .sorted { activityDate(for: $0) > activityDate(for: $1) }
            .compactMap { value($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.isEmpty == false }
    }
}

struct CloudConversationSearchRow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let snippet: String
    let provider: String?
    let projectName: String?
    let storagePath: String
    let bodyHash: String
    let score: Double
}

enum CloudConversationSearchError: LocalizedError {
    case vaultKeyUnavailable
    case downloadFailed
    case bodyHashMismatch

    var errorDescription: String? {
        switch self {
        case .vaultKeyUnavailable:
            return "This device has not received the encrypted search key yet. Leave the app signed in and let your Mac sync again."
        case .downloadFailed:
            return "Could not download the encrypted session log."
        case .bodyHashMismatch:
            return "The encrypted session log did not match its indexed hash."
        }
    }
}

// MARK: - Cloud Vault Gateway

/// Shared on-device vault-key unlock + encrypted-body retrieval used by every cloud conversation
/// surface (encrypted search, the cockpit). Centralizes the keychain → escrow-unwrap → cache flow
/// and the download → AES-GCM open → body-hash verification so the zero-knowledge spine has a
/// single, audited path rather than copies drifting per screen.
@MainActor
struct CloudVaultGateway {
    private let functions: FunctionsRepository

    init(functions: FunctionsRepository = FunctionsRepository()) {
        self.functions = functions
    }

    /// Returns the 32-byte vault key for the signed-in user, unwrapping an escrowed copy from
    /// Firestore with this device's keypair on first use and caching it in the Keychain. Returns
    /// `nil` when the user is signed out or no active wrapper has reached this device yet.
    func unlockKey() async throws -> Data? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        let keyStore = CloudVaultKeyStore()
        if let cached = try keyStore.loadKey(uid: uid) {
            return cached
        }
        let keypair = try iOSDeviceKeypair()
        let deviceId = MobileDeviceIdentity.loadOrCreateDeviceId()
        let snapshot = try await Firestore.firestore()
            .collection("users/\(uid)/cloud_vault_key_wrappers")
            .whereField("targetDeviceId", isEqualTo: deviceId)
            .whereField("status", isEqualTo: "active")
            .limit(to: 5)
            .getDocuments()
        for document in snapshot.documents {
            let data = document.data()
            guard let keyVersion = data["keyVersion"] as? Int,
                  let wrappedBase64 = data["wrappedVaultKey"] as? String,
                  let wrapped = Data(base64Encoded: wrappedBase64) else {
                continue
            }
            let unwrapped: Data
            if keyVersion == keypair.keyVersion {
                unwrapped = try keypair.decrypt(wrapped)
            } else {
                unwrapped = try keypair.decryptWithOldVersion(wrapped, version: keyVersion)
            }
            try keyStore.saveKey(unwrapped, uid: uid)
            return unwrapped
        }
        return nil
    }

    /// Downloads the encrypted session body at `storagePath`, opens it with `vaultKey`, and
    /// verifies the plaintext SHA-256 matches the indexed `bodyHash` before returning the UTF-8
    /// transcript.
    func downloadBody(storagePath: String, bodyHash: String, vaultKey: Data) async throws -> String {
        let url = try await functions.encryptedSessionBlobDownloadURL(storagePath: storagePath)
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CloudConversationSearchError.downloadFailed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(CloudVaultBlobEnvelope.self, from: data)
        let plaintext = try CloudVaultCrypto.openBlob(envelope, keyData: vaultKey)
        guard CloudVaultCrypto.sha256Hex(plaintext) == bodyHash,
              let body = String(data: plaintext, encoding: .utf8) else {
            throw CloudConversationSearchError.bodyHashMismatch
        }
        return body
    }
}

// MARK: - Conversation Cockpit Models

/// Sort axes the cockpit can order by; each maps 1:1 to a plaintext facet the server can index.
enum ConversationSortField: String, CaseIterable, Identifiable, Sendable {
    case updatedAt
    case startTime
    case endTime
    case costUSD
    case totalTokens

    var id: String { rawValue }

    var label: String {
        switch self {
        case .updatedAt: return "Recently updated"
        case .startTime: return "Start time"
        case .endTime: return "End time"
        case .costUSD: return "Cost"
        case .totalTokens: return "Tokens"
        }
    }

    var systemImage: String {
        switch self {
        case .updatedAt: return "clock.arrow.circlepath"
        case .startTime: return "calendar"
        case .endTime: return "calendar.badge.clock"
        case .costUSD: return "dollarsign.circle"
        case .totalTokens: return "number"
        }
    }
}

enum ConversationSortDirection: String, CaseIterable, Identifiable, Sendable {
    case desc
    case asc

    var id: String { rawValue }
    var label: String { self == .desc ? "Highest first" : "Lowest first" }
    var systemImage: String { self == .desc ? "arrow.down" : "arrow.up" }
}

/// A persisted faceted query the user can recall from the cockpit's saved-query rail.
struct SavedConversationQuery: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var providers: [String]
    var model: String?
    var projectQuery: String
    var sortField: String
    var sortDirection: String
    var dateFrom: Date?
    var dateTo: Date?
}

/// A decrypted cockpit row: plaintext facets for browsing plus the opened title/preview. The
/// `storagePath`/`bodyHash` allow on-demand full-transcript retrieval; everything else renders
/// without touching Cloud Storage.
struct CockpitConversationRow: Identifiable, Hashable, Sendable {
    let id: String
    let provider: String?
    let projectName: String?
    let model: String?
    let sourceType: String?
    let messageCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let costUSD: Double
    let workingDirectory: String?
    let toolTags: [String]
    let durationSeconds: Int?
    let startTime: Date?
    let updatedAt: Date?
    let title: String?
    let preview: String?
    let storagePath: String?
    let bodyHash: String?

    var providerEnum: AgentProvider? {
        provider.flatMap { AgentProvider.fromPersistedToken($0) }
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let projectName, !projectName.isEmpty { return projectName }
        return providerEnum?.displayName ?? "Encrypted session"
    }

    var activityDate: Date {
        updatedAt ?? startTime ?? .distantPast
    }

    var hasDecryptedTitle: Bool {
        if let title { return !title.isEmpty }
        return false
    }
}

// MARK: - Conversation Cockpit Store

/// Drives the Streams "Cockpit" — a faceted, paginated database view over the user's encrypted
/// session-log manifests. Filtering and sorting run server-side on plaintext facets via the
/// `queryConversations` callable; titles, previews, and full transcripts are opened locally with
/// the vault key so conversation content never leaves the device in the clear. Aggregates feed the
/// KPI header and saved queries persist locally.
@Observable
@MainActor
final class ConversationCockpitStore {
    // Filters (bound by the cockpit UI; mutating any of these changes `filterSignature`).
    var selectedProviders: Set<String> = []
    var selectedModel: String?
    var projectQuery: String = ""
    var dateFrom: Date?
    var dateTo: Date?
    var sortField: ConversationSortField = .updatedAt
    var sortDirection: ConversationSortDirection = .desc

    // Results + status.
    private(set) var rows: [CockpitConversationRow] = []
    private(set) var aggregates: ConversationQueryAggregates?
    private(set) var isLoading = false
    private(set) var isPaginating = false
    private(set) var error: String?
    private(set) var vaultLocked = false
    private(set) var hasMore = false
    private(set) var hasLoadedOnce = false
    private(set) var savedQueries: [SavedConversationQuery] = []
    private(set) var discoveredProviders: [String] = []
    private(set) var discoveredModels: [String] = []

    private let functions: FunctionsRepository
    private let vault: CloudVaultGateway
    private var nextCursor: String?
    private var vaultKey: Data?
    private var queryToken = 0

    private static let pageSize = 30
    private static let savedQueriesKey = "cockpit.savedQueries.v1"

    init(functions: FunctionsRepository = FunctionsRepository()) {
        self.functions = functions
        self.vault = CloudVaultGateway(functions: functions)
        loadSavedQueries()
    }

    /// A stable string identity for the active filter set. The cockpit binds `.task(id:)` to this
    /// so any facet change cancels the in-flight query and re-runs from page one.
    var filterSignature: String {
        let providers = selectedProviders.sorted().joined(separator: ",")
        let from = dateFrom.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        let to = dateTo.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        return "\(providers)|\(selectedModel ?? "-")|\(projectQuery)|\(sortField.rawValue)|\(sortDirection.rawValue)|\(from)|\(to)"
    }

    var hasActiveFilters: Bool {
        !selectedProviders.isEmpty
            || selectedModel != nil
            || !projectQuery.isEmpty
            || dateFrom != nil
            || dateTo != nil
    }

    func runQuery(reset: Bool) async {
        if reset {
            queryToken += 1
            nextCursor = nil
            isLoading = true
            error = nil
        } else {
            guard hasMore, !isPaginating, !isLoading, nextCursor != nil else { return }
            isPaginating = true
        }
        let token = queryToken
        defer {
            if reset {
                isLoading = false
                hasLoadedOnce = true
            } else {
                isPaginating = false
            }
        }

        do {
            if vaultKey == nil {
                vaultKey = try? await vault.unlockKey()
            }
            guard token == queryToken else { return }
            vaultLocked = (vaultKey == nil)

            let response = try await functions.queryConversations(
                providers: Array(selectedProviders),
                models: selectedModel.map { [$0] } ?? [],
                projectName: projectQuery.isEmpty ? nil : projectQuery,
                dateFrom: dateFrom,
                dateTo: dateTo,
                sort: sortField.rawValue,
                direction: sortDirection.rawValue,
                limit: Self.pageSize,
                cursorDocId: reset ? nil : nextCursor,
                includeAggregates: reset
            )
            guard token == queryToken else { return }

            let mapped = response.rows.map(decodeRow)
            if reset {
                rows = mapped
            } else {
                rows.append(contentsOf: mapped)
            }
            if let aggregates = response.aggregates {
                self.aggregates = aggregates
            }
            nextCursor = response.nextCursor
            hasMore = response.nextCursor != nil
            error = nil
            refreshFacetOptions()
        } catch is CancellationError {
            return
        } catch {
            guard token == queryToken else { return }
            if reset {
                rows = []
                aggregates = nil
            }
            hasMore = false
            self.error = error.localizedDescription
        }
    }

    func loadNextPage() async {
        await runQuery(reset: false)
    }

    func loadNextPageIfNeeded(currentRow: CockpitConversationRow) {
        guard hasMore, !isPaginating, currentRow.id == rows.last?.id else { return }
        Task { await loadNextPage() }
    }

    func loadTranscript(for row: CockpitConversationRow) async throws -> String {
        guard let storagePath = row.storagePath, !storagePath.isEmpty,
              let bodyHash = row.bodyHash, !bodyHash.isEmpty else {
            throw CloudConversationSearchError.downloadFailed
        }
        let key: Data
        if let vaultKey {
            key = vaultKey
        } else if let unlocked = try await vault.unlockKey() {
            vaultKey = unlocked
            vaultLocked = false
            key = unlocked
        } else {
            throw CloudConversationSearchError.vaultKeyUnavailable
        }
        return try await vault.downloadBody(storagePath: storagePath, bodyHash: bodyHash, vaultKey: key)
    }

    // MARK: Filter mutation

    func toggleProvider(_ provider: String) {
        if selectedProviders.contains(provider) {
            selectedProviders.remove(provider)
        } else {
            selectedProviders.insert(provider)
        }
    }

    func clearFilters() {
        selectedProviders = []
        selectedModel = nil
        projectQuery = ""
        dateFrom = nil
        dateTo = nil
        sortField = .updatedAt
        sortDirection = .desc
    }

    // MARK: Saved queries

    func saveCurrentQuery(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let query = SavedConversationQuery(
            id: UUID(),
            name: trimmed,
            providers: selectedProviders.sorted(),
            model: selectedModel,
            projectQuery: projectQuery,
            sortField: sortField.rawValue,
            sortDirection: sortDirection.rawValue,
            dateFrom: dateFrom,
            dateTo: dateTo
        )
        savedQueries.removeAll { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        savedQueries.insert(query, at: 0)
        persistSavedQueries()
    }

    func applySavedQuery(_ query: SavedConversationQuery) {
        selectedProviders = Set(query.providers)
        selectedModel = query.model
        projectQuery = query.projectQuery
        sortField = ConversationSortField(rawValue: query.sortField) ?? .updatedAt
        sortDirection = ConversationSortDirection(rawValue: query.sortDirection) ?? .desc
        dateFrom = query.dateFrom
        dateTo = query.dateTo
    }

    func deleteSavedQuery(_ query: SavedConversationQuery) {
        savedQueries.removeAll { $0.id == query.id }
        persistSavedQueries()
    }

    // MARK: Private

    private func decodeRow(_ row: ConversationFacetRow) -> CockpitConversationRow {
        var title: String?
        var preview: String?
        if let key = vaultKey {
            if let sealed = row.sealedTitle {
                title = try? CloudVaultCrypto.openText(sealed, keyData: key)
            }
            if let sealed = row.sealedBodyPreview {
                preview = try? CloudVaultCrypto.openText(sealed, keyData: key)
            }
        }
        return CockpitConversationRow(
            id: row.id,
            provider: row.provider,
            projectName: row.projectName,
            model: row.model,
            sourceType: row.sourceType,
            messageCount: row.messageCount ?? 0,
            inputTokens: row.inputTokens ?? 0,
            outputTokens: row.outputTokens ?? 0,
            totalTokens: row.totalTokens ?? 0,
            costUSD: row.costUSD ?? 0,
            workingDirectory: row.workingDirectory,
            toolTags: row.toolTags ?? [],
            durationSeconds: row.durationSeconds,
            startTime: row.startTime,
            updatedAt: row.updatedAt,
            title: title,
            preview: preview,
            storagePath: row.storagePath,
            bodyHash: row.bodyHash
        )
    }

    private func refreshFacetOptions() {
        var providers = Set(discoveredProviders)
        var models = Set(discoveredModels)
        for row in rows {
            if let provider = row.provider, !provider.isEmpty { providers.insert(provider) }
            if let model = row.model, !model.isEmpty { models.insert(model) }
        }
        discoveredProviders = providers.sorted()
        discoveredModels = models.sorted()
    }

    private func loadSavedQueries() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedQueriesKey),
              let decoded = try? JSONDecoder().decode([SavedConversationQuery].self, from: data) else {
            return
        }
        savedQueries = decoded
    }

    private func persistSavedQueries() {
        guard let data = try? JSONEncoder().encode(savedQueries) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedQueriesKey)
    }
}
