import Foundation
import OpenBurnBarCore
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions

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
    /// True once an initial page load completed without error — see
    /// `loadInitialIfNeeded`.
    private(set) var hasLoadedOnce = false
    /// True once a one-shot live-usage fetch completed without error — see
    /// `loadLiveUsageIfNeeded`.
    private var hasLoadedLiveUsageOnce = false
    private var lastDoc: DocumentSnapshot?
    private var liveUsageListener: ListenerRegistration?
    private static let serverSearchLimit = 50
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

    /// Idempotent variant of `loadInitial()` for stores hoisted above the
    /// owning view: a warm store keeps its paged rows on a tab return; a
    /// store whose last load failed retries.
    func loadInitialIfNeeded() async {
        guard hasLoadedOnce else {
            await loadInitial()
            return
        }
    }

    /// Idempotent variant of `loadLiveUsage(since:)`: the one-shot seed
    /// fetch only matters before the live listener has ever delivered —
    /// on a warm tab return the restarted listener replays the current
    /// window by itself.
    func loadLiveUsageIfNeeded(since startDate: Date) async {
        guard hasLoadedLiveUsageOnce else {
            await loadLiveUsage(since: startDate)
            return
        }
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
            hasLoadedOnce = true
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
            hasLoadedOnce = true
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
        // A refresh empties the store, so until `load()` succeeds again the
        // store must read as cold — otherwise a failed pull-to-refresh would
        // leave `loadIfNeeded` skipping the retry on the next mount.
        hasLoadedOnce = false
        await load()
    }

    func loadLiveUsage(since startDate: Date) async {
        if AppStoreScreenshotMode.isEnabled {
            liveUsages = AppStoreScreenshotData.recentUsage
            hasLoadedLiveUsageOnce = true
            return
        }
        do {
            liveUsages = try await firestore.fetchUsageSince(startDate)
            hasLoadedLiveUsageOnce = true
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
                self.hasLoadedLiveUsageOnce = true
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
        searchHits = []
        cloudSearchHits = []
        defer {
            if lastSearchQuery == trimmed {
                isSearching = false
            }
        }
        do {
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()
            guard lastSearchQuery == trimmed else { return }
            async let streamHits = functions.searchStreams(query: trimmed, limit: Self.serverSearchLimit)
            async let cloudHits = searchEncryptedCloudIndex(query: trimmed)
            let resolvedStreamHits = (try? await streamHits) ?? []
            let resolvedCloudHits = (try? await cloudHits) ?? []
            guard lastSearchQuery == trimmed else { return }
            searchHits = resolvedStreamHits
            cloudSearchHits = resolvedCloudHits
        } catch is CancellationError {
            return
        } catch {
            searchHits = []
            cloudSearchHits = []
        }
    }

    private func searchEncryptedCloudIndex(query: String) async throws -> [CloudConversationSearchRow] {
        guard FirebaseApp.app() != nil, let uid = Auth.auth().currentUser?.uid else { return [] }
        guard let vaultKey = try await unlockCloudVaultKeyIfAvailable() else { return [] }
        let tokenHashes = try CloudVaultCrypto.searchQueryTokenHashes(for: query, keyData: vaultKey, limit: 10)
        let semanticHashes = try CloudVaultCrypto.semanticHashes(for: query, keyData: vaultKey, limit: 12)
        guard tokenHashes.isEmpty == false || semanticHashes.isEmpty == false else { return [] }
        let hits = try await functions.searchEncryptedConversationIndex(
            tokenHashes: tokenHashes,
            semanticHashes: semanticHashes,
            limit: Self.serverSearchLimit
        )
        let rows: [CloudConversationSearchRow] = hits.compactMap { (hit: CloudConversationSearchHit) -> CloudConversationSearchRow? in
            guard let title = try? CloudVaultCrypto.openText(
                hit.sealedTitle,
                keyData: vaultKey,
                aadContext: CloudVaultAADContext(
                    uid: uid,
                    collection: "cloud_search_documents",
                    docID: hit.documentID,
                    field: "sealedTitle"
                )
            ),
            let snippet = try? CloudVaultCrypto.openText(
                hit.sealedSnippet,
                keyData: vaultKey,
                aadContext: CloudVaultAADContext(
                    uid: uid,
                    collection: "cloud_search_chunks",
                    docID: hit.chunkID,
                    field: "sealedSnippet"
                )
            ) else {
                return nil
            }
            return CloudConversationSearchRow(
                id: hit.id,
                documentID: hit.documentID,
                title: title,
                snippet: snippet,
                provider: hit.provider,
                storagePath: hit.storagePath,
                bodyHash: hit.bodyHash,
                bodyHashVersion: hit.bodyHashVersion ?? 0,
                score: hit.score,
                tokenScore: hit.tokenScore,
                semanticScore: hit.semanticScore,
                matchKind: hit.matchKind
            )
        }
        return Self.rankCloudConversationRows(rows, query: query)
    }

    func loadCloudConversationBody(for row: CloudConversationSearchRow) async throws -> String {
        guard let vaultKey = try await vault.unlockKey() else {
            throw CloudConversationSearchError.vaultKeyUnavailable
        }
        return try await vault.downloadBody(
            storagePath: row.storagePath,
            bodyHash: row.bodyHash,
            bodyHashVersion: row.bodyHashVersion,
            vaultKey: vaultKey
        )
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

        return stats.min { lhs, rhs in
            if lhs.value.tokens != rhs.value.tokens { return lhs.value.tokens > rhs.value.tokens }
            if lhs.value.cost != rhs.value.cost { return lhs.value.cost > rhs.value.cost }
            return lhs.value.lastSeen > rhs.value.lastSeen
        }?.key ?? fallback
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

    nonisolated static func rankCloudConversationRows(
        _ rows: [CloudConversationSearchRow],
        query: String
    ) -> [CloudConversationSearchRow] {
        let scorer = CloudConversationSearchReranker(query: query)
        guard scorer.isActive else { return rows }
        return rows.sorted { lhs, rhs in
            let lhsScore = scorer.score(lhs)
            let rhsScore = scorer.score(rhs)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

struct CloudConversationSearchRow: Identifiable, Hashable, Sendable {
    let id: String
    let documentID: String
    let title: String
    let snippet: String
    let provider: String?
    let storagePath: String
    let bodyHash: String
    let bodyHashVersion: Int
    let score: Double
    let tokenScore: Double?
    let semanticScore: Double?
    let matchKind: String?

    var providerEnum: AgentProvider? {
        guard let provider else { return nil }
        return AgentProvider.fromCatalogProviderID(provider)
            ?? AgentProvider.fromPersistedToken(provider)
            ?? AgentProvider(rawValue: provider)
    }
}

private struct CloudConversationSearchReranker: Sendable {
    let phrase: String
    let tokens: [String]
    let concepts: Set<String>

    init(query: String) {
        phrase = Self.normalizedPhrase(query)
        tokens = Self.normalizedTokens(query)
        concepts = Self.semanticConcepts(in: query)
    }

    var isActive: Bool {
        !phrase.isEmpty || !tokens.isEmpty
    }

    func score(_ row: CloudConversationSearchRow) -> Double {
        let title = Self.normalizedPhrase(row.title)
        let snippet = Self.normalizedPhrase(row.snippet)
        let provider = Self.normalizedPhrase(row.providerEnum?.displayName ?? row.provider ?? "")
        let haystack = [title, snippet, provider]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        var score = row.score * 100
        score += (row.tokenScore ?? 0) * 45
        score += (row.semanticScore ?? 0) * 28

        if phrase.count >= 3 {
            if title.contains(phrase) { score += 90 }
            if snippet.contains(phrase) { score += 70 }
        }

        if !tokens.isEmpty {
            let matched = tokens.filter { haystack.contains($0) }
            let coverage = Double(matched.count) / Double(tokens.count)
            score += coverage * 70
            if matched.count == tokens.count { score += 45 }
            if title.containsAll(tokens) { score += 30 }
            if snippet.containsAll(tokens) { score += 18 }
        }

        if !concepts.isEmpty {
            let rowConcepts = Self.semanticConcepts(in: haystack)
            let matchedConcepts = concepts.intersection(rowConcepts)
            let coverage = Double(matchedConcepts.count) / Double(concepts.count)
            score += coverage * 55
            if matchedConcepts.count == concepts.count { score += 22 }
        }

        switch row.matchKind?.lowercased() {
        case "hybrid":
            score += 18
        case "token":
            score += 10
        case "semantic":
            score += 18
        default:
            break
        }

        return score
    }

    private static func normalizedPhrase(_ text: String) -> String {
        normalizedTokens(text).joined(separator: " ")
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "and", "for", "with", "that", "this", "from", "how", "what", "where",
            "when", "why", "are", "was", "were", "you", "your", "have", "has", "had",
            "into", "onto", "can", "could", "should", "would"
        ]
        var seen = Set<String>()
        return text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in
                (token.count >= 2 || token == "x") && !stopwords.contains(token)
            }
            .filter { seen.insert($0).inserted }
    }

    private static func semanticConcepts(in text: String) -> Set<String> {
        let phrase = normalizedPhrase(text)
        let tokenSet = Set(normalizedTokens(text))
        var concepts = Set<String>()

        let mentionsX = tokenSet.contains("x")
            || tokenSet.contains("twitter")
            || phrase.contains("x platform")
        let mentionsAds = tokenSet.contains("ad")
            || tokenSet.contains("ads")
            || tokenSet.contains("advertising")
            || tokenSet.contains("campaign")
            || tokenSet.contains("campaigns")
            || tokenSet.contains("marketing")
        let mentionsAPI = tokenSet.contains("api")
            || tokenSet.contains("endpoint")
            || tokenSet.contains("endpoints")
            || tokenSet.contains("sdk")
            || tokenSet.contains("webhook")
            || tokenSet.contains("integration")
            || tokenSet.contains("integrations")

        if mentionsX {
            concepts.insert("x-platform")
            concepts.insert("social-platform")
        }
        if mentionsAds {
            concepts.insert("advertising")
        }
        if mentionsAPI {
            concepts.insert("api-integration")
        }
        if mentionsX && mentionsAds {
            concepts.insert("x-ads")
        }
        if mentionsAds && mentionsAPI {
            concepts.insert("ads-api")
        }
        if mentionsX && mentionsAPI {
            concepts.insert("x-api")
        }

        return concepts
    }
}

private extension String {
    func containsAll(_ tokens: [String]) -> Bool {
        tokens.allSatisfy { contains($0) }
    }
}

enum CloudConversationSearchError: LocalizedError, Equatable {
    case vaultKeyUnavailable
    /// The conversation row carries no stored body (missing `storagePath`/`bodyHash`), so there is
    /// no encrypted transcript to download — distinct from a transfer failure, and not retryable.
    case transcriptUnavailable
    /// The encrypted body object is gone from Cloud Storage (a signed-URL 404/410, or a server-side
    /// `not-found` from `getEncryptedSessionBlobDownloadUrl`). Retrying won't help until the Mac
    /// re-uploads the body, so the UI should say so rather than offer a futile "Try Again".
    case transcriptMissingFromCloud
    /// A genuine transfer/decode failure. `underlying` carries the real cause (HTTP status, callable
    /// message, or network/decode error) so the error pane is never an opaque dead end.
    case downloadFailed(underlying: String?)
    case bodyHashMismatch

    var errorDescription: String? {
        switch self {
        case .vaultKeyUnavailable:
            return "This device has not received the encrypted search key yet. Leave the app signed in and let your Mac sync again."
        case .transcriptUnavailable:
            return "This conversation was indexed without a stored transcript, so there's nothing to open."
        case .transcriptMissingFromCloud:
            return "This conversation's encrypted transcript is no longer stored in the cloud."
        case .downloadFailed(let underlying):
            if let underlying, !underlying.isEmpty {
                return "Could not download the encrypted session log: \(underlying)"
            }
            return "Could not download the encrypted session log."
        case .bodyHashMismatch:
            return "The encrypted session log did not match its indexed hash."
        }
    }
}

// MARK: - Cloud Transcript Cache

struct CloudTranscriptCacheSettings: Sendable {
    static let defaultMaxMegabytes = 250
    static let maximumMegabytes = 2_048
    static let bytesPerMegabyte: Int64 = 1_024 * 1_024
    static let shared = CloudTranscriptCacheSettings()

    private static let maxMegabytesKey = "streams.transcriptCache.maxMegabytes.v1"
    private let defaultsSuiteName: String?

    init(defaultsSuiteName: String? = nil) {
        self.defaultsSuiteName = defaultsSuiteName
    }

    var maxMegabytes: Int {
        get {
            let stored = defaults.object(forKey: Self.maxMegabytesKey) as? NSNumber
            return Self.clampedMegabytes(stored?.intValue ?? Self.defaultMaxMegabytes)
        }
        nonmutating set {
            defaults.set(Self.clampedMegabytes(newValue), forKey: Self.maxMegabytesKey)
        }
    }

    var maxBytes: Int64 {
        get { Int64(maxMegabytes) * Self.bytesPerMegabyte }
        nonmutating set {
            maxMegabytes = Int(newValue / Self.bytesPerMegabyte)
        }
    }

    private var defaults: UserDefaults {
        if let defaultsSuiteName, let suite = UserDefaults(suiteName: defaultsSuiteName) {
            return suite
        }
        return .standard
    }

    static func clampedMegabytes(_ value: Int) -> Int {
        min(max(0, value), maximumMegabytes)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesActualByteCount = false
        return formatter.string(fromByteCount: max(0, bytes))
    }
}

struct CloudTranscriptCacheSnapshot: Equatable, Sendable {
    let usageBytes: Int64
    let maxBytes: Int64

    var isDisabled: Bool { maxBytes <= 0 }
    var isFull: Bool { !isDisabled && usageBytes >= maxBytes }
}

struct CloudTranscriptCacheWarmupResult: Equatable, Sendable {
    var available = 0
    var skipped = 0
    var failed = 0
    var limitReached = false
}

actor CloudTranscriptCache {
    static let shared = CloudTranscriptCache()

    private struct CacheIndex: Codable, Sendable {
        var entries: [String: CacheEntry] = [:]
    }

    private struct CacheEntry: Codable, Sendable {
        let key: String
        let storagePath: String
        let bodyHash: String
        let bodyHashVersion: Int?
        var byteCount: Int64
        let cachedAt: Date
        var lastAccessedAt: Date
    }

    private let directory: URL
    private let settings: CloudTranscriptCacheSettings

    init(
        directory: URL? = nil,
        settings: CloudTranscriptCacheSettings = .shared
    ) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenBurnBarCloudTranscripts", isDirectory: true)
        self.settings = settings
    }

    func cachedTranscript(
        storagePath: String,
        bodyHash: String,
        bodyHashVersion: Int,
        vaultKey: Data,
        aadContext: CloudVaultAADContext
    ) -> String? {
        guard settings.maxBytes > 0 else { return nil }
        let key = Self.cacheKey(storagePath: storagePath, bodyHash: bodyHash, bodyHashVersion: bodyHashVersion)
        do {
            var index = try loadIndex()
            guard var entry = index.entries[key],
                  entry.storagePath == storagePath,
                  entry.bodyHash == bodyHash,
                  (entry.bodyHashVersion ?? 0) == bodyHashVersion else {
                return nil
            }
            let data = try Data(contentsOf: blobURL(for: key))
            let envelope = try JSONDecoder().decode(CloudVaultBlobEnvelope.self, from: data)
            let plaintext = try CloudVaultCrypto.openBlob(envelope, keyData: vaultKey, aadContext: aadContext)
            guard try CloudVaultCrypto.expectedSessionBodyHash(
                plaintext,
                keyData: vaultKey,
                bodyHashVersion: bodyHashVersion
            ) == bodyHash,
                  let transcript = String(data: plaintext, encoding: .utf8) else {
                try removeEntry(key, from: &index)
                try writeIndex(index)
                return nil
            }
            entry.byteCount = Int64(data.count)
            entry.lastAccessedAt = Date()
            index.entries[key] = entry
            try writeIndex(index)
            return transcript
        } catch {
            try? removeCachedKey(key)
            return nil
        }
    }

    func storeTranscript(
        _ transcript: String,
        storagePath: String,
        bodyHash: String,
        bodyHashVersion: Int,
        vaultKey: Data,
        aadContext: CloudVaultAADContext
    ) throws {
        let maxBytes = settings.maxBytes
        guard maxBytes > 0 else {
            try? clear()
            return
        }

        let plaintext = Data(transcript.utf8)
        let envelope = try CloudVaultCrypto.sealBlob(plaintext, keyData: vaultKey, aadContext: aadContext)
        guard try CloudVaultCrypto.expectedSessionBodyHash(
            plaintext,
            keyData: vaultKey,
            bodyHashVersion: bodyHashVersion
        ) == bodyHash else {
            throw CloudConversationSearchError.bodyHashMismatch
        }
        let encoded = try JSONEncoder().encode(envelope)
        guard Int64(encoded.count) <= maxBytes else { return }

        try ensureDirectory()
        let key = Self.cacheKey(storagePath: storagePath, bodyHash: bodyHash, bodyHashVersion: bodyHashVersion)
        try encoded.write(to: blobURL(for: key), options: .atomic)

        var index = try loadIndex()
        let now = Date()
        index.entries[key] = CacheEntry(
            key: key,
            storagePath: storagePath,
            bodyHash: bodyHash,
            bodyHashVersion: bodyHashVersion,
            byteCount: Int64(encoded.count),
            cachedAt: now,
            lastAccessedAt: now
        )
        try trim(&index, maxBytes: maxBytes)
        try writeIndex(index)
    }

    func snapshot() -> CloudTranscriptCacheSnapshot {
        let usage = (try? currentUsageBytes()) ?? 0
        return CloudTranscriptCacheSnapshot(usageBytes: usage, maxBytes: settings.maxBytes)
    }

    func trimToLimit() {
        do {
            var index = try loadIndex()
            try trim(&index, maxBytes: settings.maxBytes)
            try writeIndex(index)
        } catch {
            // Cache trimming is opportunistic; transcript loading should not fail because
            // the local cache index is temporarily unavailable.
        }
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try ensureDirectory()
        try writeIndex(CacheIndex())
    }

    private static func cacheKey(storagePath: String, bodyHash: String, bodyHashVersion: Int) -> String {
        CloudVaultCrypto.sha256Hex("\(storagePath)\n\(bodyHash)\n\(bodyHashVersion)")
    }

    private var indexURL: URL {
        directory.appendingPathComponent("index.json", isDirectory: false)
    }

    private func blobURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json", isDirectory: false)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func loadIndex() throws -> CacheIndex {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return CacheIndex() }
        let data = try Data(contentsOf: indexURL)
        return try JSONDecoder().decode(CacheIndex.self, from: data)
    }

    private func writeIndex(_ index: CacheIndex) throws {
        try ensureDirectory()
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    private func currentUsageBytes() throws -> Int64 {
        var index = try loadIndex()
        var total: Int64 = 0
        for (key, entry) in index.entries {
            let url = blobURL(for: key)
            guard FileManager.default.fileExists(atPath: url.path) else {
                index.entries.removeValue(forKey: key)
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? entry.byteCount
            var updated = entry
            updated.byteCount = byteCount
            index.entries[key] = updated
            total += byteCount
        }
        try writeIndex(index)
        return total
    }

    private func trim(_ index: inout CacheIndex, maxBytes: Int64) throws {
        guard maxBytes > 0 else {
            for key in Array(index.entries.keys) {
                try? FileManager.default.removeItem(at: blobURL(for: key))
            }
            index.entries = [:]
            return
        }

        var total: Int64 = 0
        for (key, entry) in index.entries {
            let url = blobURL(for: key)
            guard FileManager.default.fileExists(atPath: url.path) else {
                index.entries.removeValue(forKey: key)
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? entry.byteCount
            var updated = entry
            updated.byteCount = byteCount
            index.entries[key] = updated
            total += byteCount
        }

        let oldestFirst = index.entries.values.sorted { lhs, rhs in
            lhs.lastAccessedAt < rhs.lastAccessedAt
        }
        for entry in oldestFirst where total > maxBytes {
            try? FileManager.default.removeItem(at: blobURL(for: entry.key))
            index.entries.removeValue(forKey: entry.key)
            total -= entry.byteCount
        }
    }

    private func removeEntry(_ key: String, from index: inout CacheIndex) throws {
        try? FileManager.default.removeItem(at: blobURL(for: key))
        index.entries.removeValue(forKey: key)
    }

    private func removeCachedKey(_ key: String) throws {
        var index = try loadIndex()
        try removeEntry(key, from: &index)
        try writeIndex(index)
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
        guard FirebaseApp.app() != nil, let uid = Auth.auth().currentUser?.uid else { return nil }
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

    /// Downloads the encrypted session body at `storagePath`, opens it with `vaultKey`, and verifies
    /// the versioned external session body hash before returning the UTF-8 transcript. The blob's
    /// own HMAC is verified inside `CloudVaultCrypto.openBlob`.
    func downloadBody(storagePath: String, bodyHash: String, bodyHashVersion: Int, vaultKey: Data) async throws -> String {
        guard FirebaseApp.app() != nil,
              let uid = Auth.auth().currentUser?.uid,
              let documentID = Self.sessionLogDocumentID(from: storagePath) else {
            throw CloudConversationSearchError.transcriptUnavailable
        }
        let aadContext = try CloudVaultAADContext(
            uid: uid,
            collection: "session_logs",
            docID: documentID,
            field: "sealedBody"
        )
        if let cached = await CloudTranscriptCache.shared.cachedTranscript(
            storagePath: storagePath,
            bodyHash: bodyHash,
            bodyHashVersion: bodyHashVersion,
            vaultKey: vaultKey,
            aadContext: aadContext
        ) {
            return cached
        }

        do {
            let url = try await functions.encryptedSessionBlobDownloadURL(storagePath: storagePath)
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw Self.classifyDownloadFailure(httpStatus: http.statusCode, error: nil)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(CloudVaultBlobEnvelope.self, from: data)
            let plaintext = try CloudVaultCrypto.openBlob(envelope, keyData: vaultKey, aadContext: aadContext)
            guard try CloudVaultCrypto.expectedSessionBodyHash(
                plaintext,
                keyData: vaultKey,
                bodyHashVersion: bodyHashVersion
            ) == bodyHash,
                  let body = String(data: plaintext, encoding: .utf8) else {
                throw CloudConversationSearchError.bodyHashMismatch
            }
            try? await CloudTranscriptCache.shared.storeTranscript(
                body,
                storagePath: storagePath,
                bodyHash: bodyHash,
                bodyHashVersion: bodyHashVersion,
                vaultKey: vaultKey,
                aadContext: aadContext
            )
            return body
        } catch let error as CloudConversationSearchError {
            throw error
        } catch {
            throw Self.classifyDownloadFailure(httpStatus: nil, error: error)
        }
    }

    /// Maps a raw transcript-download failure into a precise, user-facing error. Pure (no I/O) so it
    /// can be unit-tested without a live Functions/Storage round-trip. A missing body object surfaces
    /// either as a signed-URL 404/410 or as a callable `not-found`; both become
    /// `.transcriptMissingFromCloud` so the UI stops offering a futile retry. Every other failure
    /// keeps its real cause (HTTP status or the SDK's localized message) instead of collapsing into an
    /// opaque "download failed".
    nonisolated static func classifyDownloadFailure(httpStatus: Int?, error: Error?) -> CloudConversationSearchError {
        if let httpStatus, httpStatus == 404 || httpStatus == 410 {
            return .transcriptMissingFromCloud
        }
        if let error, isNotFoundError(error) {
            return .transcriptMissingFromCloud
        }
        if let httpStatus, !(200...299).contains(httpStatus) {
            return .downloadFailed(underlying: "HTTP \(httpStatus)")
        }
        return .downloadFailed(underlying: error?.localizedDescription)
    }

    /// True when `error` is a Firebase callable `not-found` (the download URL function reports a
    /// missing body object this way after its `file.exists()` precheck).
    nonisolated static func isNotFoundError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == FunctionsErrorDomain
            && nsError.code == FunctionsErrorCode.notFound.rawValue
    }

    nonisolated private static func sessionLogDocumentID(from storagePath: String) -> String? {
        let parts = storagePath.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "session_logs"),
              parts.indices.contains(index + 1),
              parts.indices.contains(index + 2),
              parts[index + 2] == "bodies" else {
            return nil
        }
        return parts[index + 1]
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
    let bodyHashVersion: Int

    var providerEnum: AgentProvider? {
        provider.flatMap { AgentProvider.fromPersistedToken($0) }
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
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

@MainActor
protocol ConversationQueryClient {
    func queryConversations(
        providers: [String],
        models: [String],
        deviceId: String?,
        sourceType: String?,
        dateFrom: Date?,
        dateTo: Date?,
        sort: String,
        direction: String,
        limit: Int,
        cursorDocId: String?,
        includeAggregates: Bool
    ) async throws -> ConversationQueryResponse
}

extension FunctionsRepository: ConversationQueryClient {}

@MainActor
struct CloudConversationAuthGate {
    var currentUID: @MainActor () -> String?
    var prepareIDToken: @MainActor (_ forcingRefresh: Bool) async -> Bool

    static let live = CloudConversationAuthGate(
        currentUID: {
            guard FirebaseApp.app() != nil else { return nil }
            return Auth.auth().currentUser?.uid
        },
        prepareIDToken: { forcingRefresh in
            guard FirebaseApp.app() != nil else { return false }
            guard let user = Auth.auth().currentUser else { return false }
            return await withCheckedContinuation { continuation in
                user.getIDTokenResult(forcingRefresh: forcingRefresh) { result, error in
                    continuation.resume(returning: error == nil && (result?.token.isEmpty == false))
                }
            }
        }
    )

    func prepareForCallable() async -> Bool {
        guard currentUID()?.isEmpty == false else { return false }
        return await prepareIDToken(false)
    }

    func refreshForCallable() async -> Bool {
        guard currentUID()?.isEmpty == false else { return false }
        return await prepareIDToken(true)
    }
}

/// Drives the Streams "Cockpit" — a faceted, paginated database view over the user's encrypted
/// session-log manifests. Filtering and sorting run server-side only on operational facets via the
/// `queryConversations` callable; text/project/path search uses keyed encrypted search hashes and
/// local decryption. Aggregates feed the KPI header and saved queries persist locally.
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
    private let queryClient: any ConversationQueryClient
    private let vault: CloudVaultGateway
    private let authGate: CloudConversationAuthGate
    private var nextCursor: String?
    private var vaultKey: Data?
    private var queryToken = 0

    private static let pageSize = 100
    private static let savedQueriesKey = "cockpit.savedQueries.v1"

    init(
        functions: FunctionsRepository = FunctionsRepository(),
        queryClient: (any ConversationQueryClient)? = nil,
        authGate: CloudConversationAuthGate = .live
    ) {
        self.functions = functions
        self.queryClient = queryClient ?? functions
        self.vault = CloudVaultGateway(functions: functions)
        self.authGate = authGate
        loadSavedQueries()
    }

    /// A stable string identity for the active filter set. The cockpit binds `.task(id:)` to this
    /// so any facet change cancels the in-flight query and re-runs from page one.
    var filterSignature: String {
        let providers = selectedProviders.sorted().joined(separator: ",")
        let from = dateFrom.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        let to = dateTo.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        return "\(providers)|\(selectedModel ?? "-")|\(sortField.rawValue)|\(sortDirection.rawValue)|\(from)|\(to)"
    }

    var hasActiveFilters: Bool {
        !selectedProviders.isEmpty
            || selectedModel != nil
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

        guard await authGate.prepareForCallable() else {
            if reset {
                rows = []
                aggregates = nil
            }
            vaultLocked = false
            hasMore = false
            error = "Sign in to load cloud conversations."
            return
        }

        do {
            if vaultKey == nil {
                vaultKey = try? await vault.unlockKey()
            }
            guard token == queryToken else { return }
            vaultLocked = (vaultKey == nil)

            let response = try await queryConversationsPage(reset: reset)
            guard token == queryToken else { return }

            apply(response: response, reset: reset)
        } catch is CancellationError {
            return
        } catch {
            guard token == queryToken else { return }
            if Self.isUnauthenticated(error),
               await authGate.refreshForCallable(),
               token == queryToken {
                do {
                    let response = try await queryConversationsPage(reset: reset)
                    guard token == queryToken else { return }
                    apply(response: response, reset: reset)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard token == queryToken else { return }
                    handleQueryFailure(error, reset: reset)
                    return
                }
            }
            handleQueryFailure(error, reset: reset)
        }
    }

    private func queryConversationsPage(reset: Bool) async throws -> ConversationQueryResponse {
        try await queryClient.queryConversations(
            providers: Array(selectedProviders),
            models: selectedModel.map { [$0] } ?? [],
            deviceId: nil,
            sourceType: nil,
            dateFrom: dateFrom,
            dateTo: dateTo,
            sort: sortField.rawValue,
            direction: sortDirection.rawValue,
            limit: Self.pageSize,
            cursorDocId: reset ? nil : nextCursor,
            includeAggregates: reset
        )
    }

    private func apply(response: ConversationQueryResponse, reset: Bool) {
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
    }

    private func handleQueryFailure(_ error: Error, reset: Bool) {
        if reset {
            rows = []
            aggregates = nil
        }
        hasMore = false
        self.error = Self.presentableQueryError(error)
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
            throw CloudConversationSearchError.transcriptUnavailable
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
        return try await vault.downloadBody(
            storagePath: storagePath,
            bodyHash: bodyHash,
            bodyHashVersion: row.bodyHashVersion,
            vaultKey: key
        )
    }

    func cacheLoadedTranscripts() async -> CloudTranscriptCacheWarmupResult {
        var result = CloudTranscriptCacheWarmupResult()
        guard rows.isEmpty == false else { return result }

        let key: Data
        if let vaultKey {
            key = vaultKey
        } else if let unlocked = try? await vault.unlockKey() {
            vaultKey = unlocked
            vaultLocked = false
            key = unlocked
        } else {
            result.failed = rows.count
            return result
        }

        for row in rows {
            guard let storagePath = row.storagePath, !storagePath.isEmpty,
                  let bodyHash = row.bodyHash, !bodyHash.isEmpty else {
                result.skipped += 1
                continue
            }
            let snapshot = await CloudTranscriptCache.shared.snapshot()
            if snapshot.isDisabled || snapshot.isFull {
                result.limitReached = true
                break
            }
            do {
                _ = try await vault.downloadBody(
                    storagePath: storagePath,
                    bodyHash: bodyHash,
                    bodyHashVersion: row.bodyHashVersion,
                    vaultKey: key
                )
                result.available += 1
            } catch {
                result.failed += 1
            }
        }
        await CloudTranscriptCache.shared.trimToLimit()
        return result
    }

    private static func presentableQueryError(_ error: Error) -> String {
        let description = error.localizedDescription
        if isUnauthenticated(error) {
            #if DEBUG
            return "Sign in again, or reinstall this debug build with a registered App Check token."
            #else
            return "Sign in again to load cloud conversations."
            #endif
        }
        return description
    }

    private static func isUnauthenticated(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("unauthenticated")
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
            projectQuery: "",
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
        projectQuery = ""
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
        if let key = vaultKey, let uid = authGate.currentUID() {
            if let sealed = row.sealedTitle {
                title = try? CloudVaultCrypto.openText(
                    sealed,
                    keyData: key,
                    aadContext: CloudVaultAADContext(
                        uid: uid,
                        collection: "session_logs",
                        docID: row.id,
                        field: "sealedTitle"
                    )
                )
            }
            if let sealed = row.sealedBodyPreview {
                preview = try? CloudVaultCrypto.openText(
                    sealed,
                    keyData: key,
                    aadContext: CloudVaultAADContext(
                        uid: uid,
                        collection: "session_logs",
                        docID: row.id,
                        field: "sealedBodyPreview"
                    )
                )
            }
        }
        return CockpitConversationRow(
            id: row.id,
            provider: row.provider,
            projectName: nil,
            model: row.model,
            sourceType: row.sourceType,
            messageCount: row.messageCount ?? 0,
            inputTokens: row.inputTokens ?? 0,
            outputTokens: row.outputTokens ?? 0,
            totalTokens: row.totalTokens ?? 0,
            costUSD: row.costUSD ?? 0,
            workingDirectory: nil,
            toolTags: row.toolTags ?? [],
            durationSeconds: row.durationSeconds,
            startTime: row.startTime,
            updatedAt: row.updatedAt,
            title: title,
            preview: preview,
            storagePath: row.storagePath,
            bodyHash: row.bodyHash,
            bodyHashVersion: row.bodyHashVersion ?? 0
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
