import Foundation
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OpenBurnBarCore
import OSLog

private let logger = Logger(subsystem: "com.openburnbar.mobile", category: "FirestoreRepository")

struct StreamSessionLogManifest: Identifiable, Hashable, Sendable {
    let id: String
    let documentID: String
    let sessionId: String
    let projectName: String
    let inferredTaskTitle: String
    let messageCount: Int
    let chunkCount: Int
    let byteCount: Int
    let bodyHash: String?
}

struct QuotaSnapshotStreamUpdate: Sendable {
    let snapshots: [ProviderQuotaSnapshot]
    let rawDocumentCount: Int
    let isFromCache: Bool
}

// MARK: - Firestore Repository

@MainActor
final class FirestoreRepository {
    static let shared = FirestoreRepository()

    private var db: Firestore { Firestore.firestore() }

    nonisolated func currentUserDisplayID() -> String? {
        guard FirebaseApp.app() != nil else { return nil }
        return Self.redactedUserID(Auth.auth().currentUser?.uid)
    }

    nonisolated static func redactedUserID(_ uid: String?) -> String? {
        guard let uid, uid.isEmpty == false else { return nil }
        return "…\(uid.suffix(5))"
    }

    private func uid() throws -> String {
        guard FirebaseApp.app() != nil else {
            throw FirestoreError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw FirestoreError.notAuthenticated
        }
        return uid
    }

    // MARK: - ISO 8601 Date Detection

    /// Returns `true` when a string matches ISO-8601 instant format.
    /// Used by `sanitizeForJSON` so Cloud Function date strings convert
    /// to the Double epoch that `JSONDecoder.deferredToDate` expects.
    nonisolated private static let isoDateRegex = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#
    )
    private nonisolated static func isISODateString(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return Self.isoDateRegex.firstMatch(in: s, range: range) != nil
    }

    // MARK: - Firestore → JSON Bridge

    /// Recursively converts Firestore-native types into JSON-serializable
    /// equivalents so `JSONSerialization.data(withJSONObject:)` does not throw.
    ///
    /// - `Timestamp`/`Date` → `timeIntervalSinceReferenceDate` Double
    /// - ISO 8601 date strings (e.g. `computedAt`, `fetchedAt`) → Double
    /// - Nested dicts/arrays → recursively sanitized
    nonisolated func sanitizeForJSON(_ value: Any) -> Any {
        sanitizeForJSON(value, preservingStringValues: false)
    }

    nonisolated private func sanitizeForJSON(_ value: Any, preservingStringValues: Bool) -> Any {
        switch value {
        case let ts as Timestamp:
            return ts.dateValue().timeIntervalSinceReferenceDate
        case let date as Date:
            return date.timeIntervalSinceReferenceDate
        case let s as String where preservingStringValues:
            return s
        case let s as String where Self.isISODateString(s):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: s) {
                return date.timeIntervalSinceReferenceDate
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: s) {
                return date.timeIntervalSinceReferenceDate
            }
            return s
        case let dict as [String: Any]:
            return dict.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = sanitizeForJSON(
                    entry.value,
                    preservingStringValues: preservingStringValues || entry.key == "meta"
                )
            }
        case let arr as [Any]:
            return arr.map { sanitizeForJSON($0, preservingStringValues: preservingStringValues) }
        case is NSNull:
            return NSNull()
        default:
            return value
        }
    }

    // MARK: - Decode Helpers

    /// Injects the Firestore document ID as `id` when the payload lacks it,
    /// remaps `deviceId` → `sourceDeviceId`, sanitizes for JSON, then decodes.
    nonisolated func decodeWithDocID<T: Decodable>(_ type: T.Type, from data: [String: Any], docID: String) -> T? {
        var enriched = data
        if enriched["id"] == nil {
            enriched["id"] = docID
        }
        if T.self == TokenUsage.self,
           let rawProvider = enriched["provider"] as? String {
            let providerID = ProviderID(rawValue: rawProvider)
            if let provider = AgentProvider.fromProviderID(providerID) ?? AgentProvider.fromPersistedToken(rawProvider) {
                enriched["provider"] = provider.rawValue
            }
        }
        if enriched["deviceId"] != nil && enriched["sourceDeviceId"] == nil {
            enriched["sourceDeviceId"] = enriched["deviceId"]
        }
        let sanitized = sanitizeForJSON(enriched) as? [String: Any] ?? enriched
        guard let jsonData = try? JSONSerialization.data(withJSONObject: sanitized) else {
            logger.warning("Failed to serialize Firestore data for document \(docID, privacy: .public): \(String(describing: T.self), privacy: .public)")
            return nil
        }
        do {
            return try JSONDecoder().decode(T.self, from: jsonData)
        } catch {
            logger.error("Failed to decode \(String(describing: T.self), privacy: .public) for document \(docID, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    nonisolated func decodeQuotaSnapshot(from data: [String: Any], docID: String) -> ProviderQuotaSnapshot? {
        decodeWithDocID(ProviderQuotaSnapshot.self, from: normalizeQuotaSnapshotData(data, docID: docID), docID: docID)
    }

    nonisolated func normalizeQuotaSnapshotData(_ data: [String: Any], docID: String) -> [String: Any] {
        var result = data
        result["id"] = result["id"] ?? docID

        if let rawProvider = result["provider"] as? String, result["providerID"] == nil {
            let providerID = AgentProvider.fromPersistedToken(rawProvider)?.providerID
                ?? AgentProvider(rawValue: rawProvider)?.providerID
                ?? ProviderID(rawValue: rawProvider)
            result["providerID"] = providerID.rawValue
        }

        if let rawSourceKind = result["sourceKind"] as? String {
            switch rawSourceKind {
            case "provider", "officialAPI", "localCLI", "localSession", "manualEstimate", "unavailable":
                break
            default:
                result["sourceKind"] = "provider"
            }
        } else {
            result["sourceKind"] = "provider"
        }

        if let rawConfidence = result["confidence"] as? String {
            switch rawConfidence {
            case "exact":
                result["confidence"] = "high"
            case "estimated":
                result["confidence"] = "medium"
            case "unavailable":
                result["confidence"] = "stale"
            case "high", "medium", "low", "stale":
                break
            default:
                result["confidence"] = "stale"
            }
        } else {
            result["confidence"] = "stale"
        }

        if let buckets = result["buckets"] as? [[String: Any]] {
            result["buckets"] = buckets.compactMap(normalizeQuotaBucketData)
        }

        return result
    }

    nonisolated private func normalizeQuotaBucketData(_ bucket: [String: Any]) -> [String: Any]? {
        var meta = normalizedQuotaBucketMeta(bucket["meta"])

        let rawUnit = stringValue(bucket["unit"]) ?? meta["unit"]
        if let rawUnit, meta["unit"] == nil {
            meta["unit"] = rawUnit
        }

        let name = stringValue(bucket["name"])
            ?? stringValue(bucket["key"])
            ?? stringValue(bucket["label"])
        guard let name, name.isEmpty == false else { return nil }

        if meta["label"] == nil, let label = stringValue(bucket["label"]) {
            meta["label"] = label
        }
        if meta["isEstimated"] == nil, let isEstimated = bucket["isEstimated"] {
            meta["isEstimated"] = stringValue(isEstimated) ?? String(describing: isEstimated)
        }
        if meta["usedPercent"] == nil, let usedPercent = numericValue(bucket["usedPercent"]) {
            meta["usedPercent"] = String(format: "%.2f", usedPercent)
        }
        // Bring the top-level `resetsAt` (first-class field on the new
        // `QuotaBucket` schema) into `meta` as an ISO 8601 string so the
        // legacy back-compat path in `ProviderQuotaBucket.init(from:)`
        // also sees it, regardless of whether Firestore returned a
        // `Timestamp` (Double after `sanitizeForJSON`) or an already-ISO
        // string from a Cloud Functions response.
        if meta["resetsAt"] == nil {
            if let isoString = stringValue(bucket["resetsAt"]) {
                meta["resetsAt"] = isoString
            } else if let interval = numericValue(bucket["resetsAt"]) {
                let date = Date(timeIntervalSinceReferenceDate: interval)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                meta["resetsAt"] = formatter.string(from: date)
            }
        }

        let unit = rawUnit?.lowercased()
        let window = stringValue(bucket["window"]) ?? stringValue(bucket["windowKind"])
        let usedPercent = numericValue(bucket["usedPercent"]) ?? numericValue(meta["usedPercent"])
        var used = numericValue(bucket["used"]) ?? numericValue(bucket["usedValue"])
        var limit = numericValue(bucket["limit"]) ?? numericValue(bucket["limitValue"])
        var remaining = numericValue(bucket["remaining"]) ?? numericValue(bucket["remainingValue"])

        if let rawLimit = limit, rawLimit < 0 {
            if let knownRemaining = remaining, knownRemaining > 0 {
                used = max(0, used ?? 0)
                limit = knownRemaining + max(0, used ?? 0)
                remaining = knownRemaining
                meta["limitKind"] = meta["limitKind"] ?? "remainingOnly"
            } else {
                used = 0
                limit = 100
                remaining = 100
                meta["unit"] = meta["unit"] ?? "unlimited"
                meta["limitKind"] = meta["limitKind"] ?? "unlimited"
            }
        }

        // Desktop percent-window quota buckets historically carried
        // `remainingValue`/`usedPercent` without `limitValue`; some cloud
        // uploads encoded that as `limit: 0`. The mobile display model needs a
        // positive denominator, so normalize percentage windows onto 0...100.
        if unit == "percent",
           (limit == nil || limit == 0),
           usedPercent != nil || remaining != nil {
            limit = 100
        }
        if used == nil, let usedPercent {
            used = usedPercent
        }
        if remaining == nil,
           unit == "percent",
           let used,
           (limit ?? 0) > 0 {
            remaining = max(0, (limit ?? 100) - used)
        }
        if used == nil,
           unit == "percent",
           let remaining,
           (limit ?? 0) > 0 {
            used = max(0, (limit ?? 100) - remaining)
        }

        guard let used, let limit, let remaining else { return nil }

        var normalized: [String: Any] = [
            "name": name,
            "used": used,
            "limit": limit,
            "remaining": remaining
        ]
        if let window { normalized["window"] = window }
        // Promote `resetsAt` to the top level so the new first-class field
        // on `ProviderQuotaBucket` is hit directly by Codable, not just the
        // legacy meta back-compat path.
        if let resetsAtNumeric = numericValue(bucket["resetsAt"]) {
            normalized["resetsAt"] = resetsAtNumeric
        } else if let resetsAtString = stringValue(bucket["resetsAt"]) {
            normalized["resetsAt"] = resetsAtString
        }
        if meta.isEmpty == false { normalized["meta"] = meta }
        return normalized
    }

    nonisolated private func normalizedQuotaBucketMeta(_ raw: Any?) -> [String: String] {
        guard let raw = raw as? [String: Any] else { return [:] }
        return raw.reduce(into: [String: String]()) { result, entry in
            if let string = entry.value as? String {
                result[entry.key] = string
            } else if entry.value is NSNull {
                result[entry.key] = ""
            } else {
                result[entry.key] = String(describing: entry.value)
            }
        }
    }

    nonisolated private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        case .some(let value) where !(value is NSNull):
            return String(describing: value)
        default:
            return nil
        }
    }

    nonisolated private func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    /// Decodes a usage rollup with full field normalization.
    ///
    /// Cloud Functions write rollups with differences from the Swift Codable types:
    /// - `id` and `windowKey` are the document ID, not in the payload
    /// - `dailyPoints` is `{ "YYYY-MM-DD": number }` but Swift expects `[{id, date, value}]`
    /// - Nested arrays (`providerSummaries`, etc.) lack `id` fields
    nonisolated func decodeUsageRollup(from data: [String: Any], docID: String) -> UsageRollupDoc? {
        var enriched = normalizeRollupData(data, docID: docID)
        if enriched["id"] == nil {
            enriched["id"] = docID
        }
        if enriched["windowKey"] == nil {
            switch docID {
            case "today": enriched["windowKey"] = "today"
            case "7d": enriched["windowKey"] = "7d"
            case "30d": enriched["windowKey"] = "30d"
            case "90d": enriched["windowKey"] = "90d"
            case "all_time": enriched["windowKey"] = "all_time"
            default:
                logger.warning("Unknown rollup window key in docID: \(docID)")
                return nil
            }
        }
        let sanitized = sanitizeForJSON(enriched) as? [String: Any] ?? enriched
        guard let jsonData = try? JSONSerialization.data(withJSONObject: sanitized) else {
            logger.warning("Failed to serialize rollup data for document \(docID)")
            return nil
        }
        do {
            return try JSONDecoder().decode(UsageRollupDoc.self, from: jsonData)
        } catch {
            logger.error("Failed to decode UsageRollupDoc for document \(docID): \(error.localizedDescription)")
            return nil
        }
    }

    /// Normalizes a rollup document to match what the Swift Codable types expect.
    nonisolated func normalizeRollupData(_ data: [String: Any], docID: String) -> [String: Any] {
        var result = data

        // dailyPoints: dict → array
        if let pointsDict = result["dailyPoints"] as? [String: Any] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            var pointsArray: [[String: Any]] = []
            for (dateStr, rawValue) in pointsDict {
                let value: Double
                if let d = rawValue as? Double { value = d }
                else if let i = rawValue as? Int { value = Double(i) }
                else if let n = rawValue as? NSNumber { value = n.doubleValue }
                else { continue }
                let date = formatter.date(from: dateStr) ?? Date()
                pointsArray.append([
                    "id": dateStr,
                    "date": date.timeIntervalSinceReferenceDate,
                    "value": value
                ])
            }
            pointsArray.sort { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
            result["dailyPoints"] = pointsArray
        }

        // providerSummaries: inject id from provider
        if let providers = result["providerSummaries"] as? [[String: Any]] {
            result["providerSummaries"] = providers.map { var p = $0; if p["id"] == nil { p["id"] = p["provider"] }; return p }
        }

        // accountSummaries: inject id from accountID, or the unattributed provider bucket.
        if let accounts = result["accountSummaries"] as? [[String: Any]] {
            result["accountSummaries"] = accounts.map {
                var account = $0
                if account["id"] == nil {
                    account["id"] = account["accountID"] ?? "\(account["providerID"] ?? account["provider"] ?? "provider"):unattributed"
                }
                return account
            }
        }

        // modelSummaries: inject id from "provider:model"
        if let models = result["modelSummaries"] as? [[String: Any]] {
            result["modelSummaries"] = models.map { var m = $0; if m["id"] == nil { m["id"] = "\(m["provider"] ?? ""):\(m["model"] ?? "")" }; return m }
        }

        // deviceSummaries: inject id from deviceId
        if let devices = result["deviceSummaries"] as? [[String: Any]] {
            result["deviceSummaries"] = devices.map { var d = $0; if d["id"] == nil { d["id"] = d["deviceId"] }; return d }
        }

        return result
    }

    // MARK: - Usage Rollups

    func fetchRollups() async throws -> [UsageRollupDoc] {
        let uid = try uid()
        let keys = RollupWindowKey.allCases.map(\.rawValue)
        var results: [UsageRollupDoc] = []
        var lastError: Error?

        for key in keys {
            do {
                let doc = try await db.document("users/\(uid)/usage_rollups/\(key)").getDocument()
                if let data = doc.data(),
                   let rollup = decodeUsageRollup(from: data, docID: doc.documentID) {
                    results.append(rollup)
                }
            } catch {
                logger.error("Failed to fetch usage rollup for window \(key): \(error.localizedDescription)")
                lastError = error
            }
        }

        if results.isEmpty, let lastError {
            throw lastError
        }
        logger.info("Fetched \(results.count)/\(keys.count) usage rollups")
        return results
    }

    func listenToRollups(
        onUpdate: @escaping @Sendable (Result<[UsageRollupDoc], Error>) -> Void
    ) -> ListenerRegistration? {
        guard FirebaseApp.app() != nil else {
            onUpdate(.failure(FirestoreError.firebaseUnavailable))
            return nil
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            onUpdate(.failure(FirestoreError.notAuthenticated))
            return nil
        }
        return db.collection("users/\(uid)/usage_rollups").addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            if let error {
                logger.error("Rollup listener error: \(error.localizedDescription)")
                onUpdate(.failure(error))
                return
            }
            var results: [UsageRollupDoc] = []
            for doc in snapshot?.documents ?? [] {
                if let rollup = self.decodeUsageRollup(from: doc.data(), docID: doc.documentID) {
                    results.append(rollup)
                }
            }
            logger.debug("Rollup listener update: \(results.count) rollups")
            onUpdate(.success(results))
        }
    }

    // MARK: - Quota Snapshots

    func fetchQuotaSnapshots() async throws -> [ProviderQuotaSnapshot] {
        let uid = try uid()
        let collection = db.collection("users/\(uid)/quota_snapshots")
        let snapshot: QuerySnapshot
        do {
            snapshot = try await collection.getDocuments(source: .server)
        } catch {
            logger.warning("Server quota snapshot fetch failed for account \(Self.redactedUserID(uid) ?? "unknown"): \(error.localizedDescription). Falling back to default Firestore source.")
            snapshot = try await collection.getDocuments(source: .default)
        }
        let (results, failedIDs) = decodeQuotaDocuments(snapshot.documents.map { ($0.documentID, $0.data()) })
        let rawCount = results.count + failedIDs.count
        let providerIDs = Set(results.map(\.providerID.rawValue)).sorted().joined(separator: ",")
        logger.info("Fetched \(results.count)/\(rawCount) quota snapshots for account \(Self.redactedUserID(uid) ?? "unknown") providers=[\(providerIDs, privacy: .public)]")
        if failedIDs.isEmpty == false {
            logger.warning("Skipped \(failedIDs.count) undecodable quota snapshot docs: \(failedIDs.joined(separator: ","), privacy: .private)")
        }
        if rawCount > 0, results.isEmpty {
            throw FirestoreError.decodingFailed("Could not decode \(rawCount) quota snapshot document\(rawCount == 1 ? "" : "s").")
        }
        return results
    }

    func listenToQuotaSnapshots(
        onUpdate: @escaping @Sendable (Result<[ProviderQuotaSnapshot], Error>) -> Void
    ) -> ListenerRegistration? {
        listenToQuotaSnapshotUpdates { result in
            onUpdate(result.map(\.snapshots))
        }
    }

    func listenToQuotaSnapshotUpdates(
        onUpdate: @escaping @Sendable (Result<QuotaSnapshotStreamUpdate, Error>) -> Void
    ) -> ListenerRegistration? {
        guard FirebaseApp.app() != nil else {
            onUpdate(.failure(FirestoreError.firebaseUnavailable))
            return nil
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            onUpdate(.failure(FirestoreError.notAuthenticated))
            return nil
        }
        return db.collection("users/\(uid)/quota_snapshots").addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            if let error {
                logger.error("Quota listener error: \(error.localizedDescription)")
                onUpdate(.failure(error))
                return
            }
            let documents = snapshot?.documents ?? []
            let (results, failedIDs) = self.decodeQuotaDocuments(documents.map { ($0.documentID, $0.data()) })
            if failedIDs.isEmpty == false {
                logger.warning("Quota listener skipped \(failedIDs.count) undecodable docs: \(failedIDs.joined(separator: ","), privacy: .private)")
            }
            if documents.isEmpty == false, results.isEmpty {
                onUpdate(.failure(FirestoreError.decodingFailed("Could not decode \(documents.count) quota snapshot document\(documents.count == 1 ? "" : "s").")))
                return
            }
            let isFromCache = snapshot?.metadata.isFromCache ?? false
            let source = isFromCache ? "cache" : "server"
            let providerIDs = Set(results.map(\.providerID.rawValue)).sorted().joined(separator: ",")
            logger.info("Quota listener update: \(results.count)/\(documents.count) snapshots source=\(source, privacy: .public) providers=[\(providerIDs, privacy: .public)]")
            onUpdate(.success(QuotaSnapshotStreamUpdate(
                snapshots: results,
                rawDocumentCount: documents.count,
                isFromCache: isFromCache
            )))
        }
    }

    nonisolated private func decodeQuotaDocuments(_ documents: [(id: String, data: [String: Any])]) -> ([ProviderQuotaSnapshot], [String]) {
        var results: [ProviderQuotaSnapshot] = []
        var failedIDs: [String] = []
        for document in documents {
            if let snapshot = decodeQuotaSnapshot(from: document.data, docID: document.id) {
                results.append(snapshot)
            } else {
                failedIDs.append(document.id)
            }
        }
        return (results, failedIDs)
    }

    // MARK: - Usage Events (Activity)

    func fetchUsagePage(
        pageSize: Int,
        after: DocumentSnapshot?,
        provider: String?,
        model: String?,
        device: String?,
        startDate: Date?,
        endDate: Date?
    ) async throws -> ([TokenUsage], DocumentSnapshot?) {
        let uid = try uid()
        var query: Query = db.collection("users/\(uid)/usage")
            .order(by: "startTime", descending: true)
            .limit(to: pageSize)

        if let provider { query = query.whereField("provider", isEqualTo: provider) }
        if let model { query = query.whereField("model", isEqualTo: model) }
        if let device { query = query.whereField("deviceId", isEqualTo: device) }
        if let startDate { query = query.whereField("startTime", isGreaterThanOrEqualTo: Timestamp(date: startDate)) }
        if let endDate { query = query.whereField("startTime", isLessThanOrEqualTo: Timestamp(date: endDate)) }
        if let after { query = query.start(afterDocument: after) }

        do {
            let snapshot = try await query.getDocuments()
            let items = snapshot.documents.compactMap { doc -> TokenUsage? in
                decodeWithDocID(TokenUsage.self, from: doc.data(), docID: doc.documentID)
            }
            logger.debug("Fetched \(items.count) usage events (page)")
            return (items, snapshot.documents.last)
        } catch {
            logger.error("Failed to fetch usage page: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Stream Detail

    func fetchHermesCloudLibrarySessions(limit: Int = 120) async throws -> [HermesCloudLibraryManifest] {
        let uid = try uid()
        let snapshot = try await db
            .collection("users/\(uid)/session_logs")
            .whereField("provider", isEqualTo: AgentProvider.hermes.rawValue)
            .order(by: "updatedAt", descending: true)
            .limit(to: limit)
            .getDocuments()

        return snapshot.documents.compactMap { doc -> HermesCloudLibraryManifest? in
            let data = doc.data()
            let title = data["inferredTaskTitle"] as? String
                ?? data["title"] as? String
                ?? data["sessionId"] as? String
                ?? "Hermes conversation"
            return HermesCloudLibraryManifest(
                id: data["id"] as? String ?? doc.documentID,
                documentID: doc.documentID,
                sessionId: data["sessionId"] as? String ?? doc.documentID,
                title: title,
                projectName: data["projectName"] as? String ?? "",
                messageCount: data["messageCount"] as? Int ?? 0,
                updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue(),
                startTime: (data["startTime"] as? Timestamp)?.dateValue(),
                endTime: (data["endTime"] as? Timestamp)?.dateValue()
            )
        }
    }

    func fetchSessionLogManifest(for usage: TokenUsage) async throws -> StreamSessionLogManifest? {
        let uid = try uid()
        let deviceId = usage.sourceDeviceId
        let logsRef = db.collection("users/\(uid)/session_logs")

        let candidates: [Query]
        if let deviceId, !deviceId.isEmpty {
            candidates = [
                logsRef
                    .whereField("deviceId", isEqualTo: deviceId)
                    .whereField("sessionId", isEqualTo: usage.sessionId)
                    .limit(to: 1),
                logsRef
                    .whereField("deviceId", isEqualTo: deviceId)
                    .whereField("id", isEqualTo: "\(usage.provider.rawValue):\(usage.sessionId)")
                    .limit(to: 1),
                logsRef
                    .whereField("deviceId", isEqualTo: deviceId)
                    .whereField("id", isEqualTo: usage.sessionId)
                    .limit(to: 1)
            ]
        } else {
            candidates = [
                logsRef
                    .whereField("sessionId", isEqualTo: usage.sessionId)
                    .limit(to: 1),
                logsRef
                    .whereField("id", isEqualTo: "\(usage.provider.rawValue):\(usage.sessionId)")
                    .limit(to: 1),
                logsRef
                    .whereField("id", isEqualTo: usage.sessionId)
                    .limit(to: 1)
            ]
        }

        for query in candidates {
            let snapshot = try await query.getDocuments()
            if let doc = snapshot.documents.first {
                return streamManifest(from: doc)
            }
        }
        return nil
    }

    func fetchSessionLogBody(documentID: String, maxCharacters: Int? = nil) async throws -> String {
        let uid = try uid()
        let snapshot = try await db
            .collection("users/\(uid)/session_logs/\(documentID)/chunks")
            .order(by: "index")
            .getDocuments()

        var body = ""
        for doc in snapshot.documents {
            guard let chunk = doc.data()["body"] as? String else { continue }
            body += chunk
            if let maxCharacters, body.count >= maxCharacters {
                return String(body.prefix(maxCharacters))
            }
        }
        return body
    }

    private func streamManifest(from doc: QueryDocumentSnapshot) -> StreamSessionLogManifest {
        let data = doc.data()
        return StreamSessionLogManifest(
            id: data["id"] as? String ?? doc.documentID,
            documentID: doc.documentID,
            sessionId: data["sessionId"] as? String ?? data["id"] as? String ?? doc.documentID,
            projectName: data["projectName"] as? String ?? "",
            inferredTaskTitle: data["inferredTaskTitle"] as? String ?? "",
            messageCount: data["messageCount"] as? Int ?? 0,
            chunkCount: data["chunkCount"] as? Int ?? 0,
            byteCount: data["byteCount"] as? Int ?? 0,
            bodyHash: data["bodyHash"] as? String
        )
    }

    // MARK: - Provider Connections

    func fetchProviderConnections() async throws -> [ProviderConnectionDoc] {
        let uid = try uid()
        let collection = db.collection("users/\(uid)/provider_connections")
        let snapshot: QuerySnapshot
        do {
            snapshot = try await collection.getDocuments(source: .server)
        } catch {
            logger.warning("Server provider connection fetch failed for account \(Self.redactedUserID(uid) ?? "unknown"): \(error.localizedDescription). Falling back to default Firestore source.")
            snapshot = try await collection.getDocuments(source: .default)
        }
        let results = snapshot.documents.compactMap { doc -> ProviderConnectionDoc? in
            decodeWithDocID(ProviderConnectionDoc.self, from: doc.data(), docID: doc.documentID)
        }
        let providerIDs = Set(results.map(\.provider)).sorted().joined(separator: ",")
        logger.info("Fetched \(results.count) provider connections for account \(Self.redactedUserID(uid) ?? "unknown") providers=[\(providerIDs, privacy: .public)]")
        return results
    }

    func fetchProviderAccounts() async throws -> [ProviderAccountDoc] {
        let uid = try uid()
        let collection = db.collection("users/\(uid)/provider_accounts")
        let snapshot: QuerySnapshot
        do {
            snapshot = try await collection.getDocuments(source: .server)
        } catch {
            logger.warning("Server provider account fetch failed for account \(Self.redactedUserID(uid) ?? "unknown"): \(error.localizedDescription). Falling back to default Firestore source.")
            snapshot = try await collection.getDocuments(source: .default)
        }
        let results = snapshot.documents.compactMap { doc -> ProviderAccountDoc? in
            decodeWithDocID(ProviderAccountDoc.self, from: doc.data(), docID: doc.documentID)
        }
        let providerIDs = Set(results.filter { $0.status != .deleted }.map(\.providerID.rawValue)).sorted().joined(separator: ",")
        logger.info("Fetched \(results.count) provider accounts for account \(Self.redactedUserID(uid) ?? "unknown") providers=[\(providerIDs, privacy: .public)]")
        return sortProviderAccounts(results)
    }

    // MARK: - Provider Account Device Links
    //
    // Streams `users/{uid}/provider_account_device_links` so the iOS Providers
    // screen can render a "On N devices" chip per account in real time.

    struct ProviderAccountDeviceLinkProjection: Identifiable, Hashable, Sendable {
        let id: String
        let accountID: String
        let deviceID: String
        let deviceDisplayName: String
        let capability: DeviceLinkCapability
        let status: DeviceLinkStatus
        let lastObservedAt: Date?
    }

    func listenProviderAccountDeviceLinks(
        onChange: @escaping ([ProviderAccountDeviceLinkProjection]) -> Void
    ) -> ListenerRegistration? {
        guard FirebaseApp.app() != nil,
              let uid = Auth.auth().currentUser?.uid else {
            return nil
        }
        return db.collection("users/\(uid)/provider_account_device_links")
            .addSnapshotListener { snapshot, _ in
                let docs = snapshot?.documents ?? []
                let projections: [ProviderAccountDeviceLinkProjection] = docs.compactMap { doc in
                    let data = doc.data()
                    guard let accountID = data["accountID"] as? String,
                          let deviceID = data["deviceID"] as? String else { return nil }
                    let capability = DeviceLinkCapability(rawValue: (data["capability"] as? String) ?? "use") ?? .use
                    let statusRaw = (data["status"] as? String) ?? "active"
                    let status = DeviceLinkStatus(rawValue: statusRaw) ?? .active
                    let deviceDisplayName = (data["deviceDisplayName"] as? String) ?? deviceID
                    let lastObservedAt: Date? = {
                        if let ts = data["lastObservedAt"] as? Timestamp { return ts.dateValue() }
                        if let iso = data["lastObservedAt"] as? String {
                            return ISO8601DateFormatter().date(from: iso)
                        }
                        return nil
                    }()
                    return ProviderAccountDeviceLinkProjection(
                        id: doc.documentID,
                        accountID: accountID,
                        deviceID: deviceID,
                        deviceDisplayName: deviceDisplayName,
                        capability: capability,
                        status: status,
                        lastObservedAt: lastObservedAt
                    )
                }
                onChange(projections)
            }
    }

    nonisolated func sortProviderAccounts(_ accounts: [ProviderAccountDoc]) -> [ProviderAccountDoc] {
        accounts.sorted {
            if $0.providerID.rawValue != $1.providerID.rawValue {
                return $0.providerID.rawValue < $1.providerID.rawValue
            }
            if $0.sortKey != $1.sortKey {
                return $0.sortKey < $1.sortKey
            }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }
}

// MARK: - Firestore Error

enum FirestoreError: Error, LocalizedError {
    case firebaseUnavailable
    case notAuthenticated
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .firebaseUnavailable: return "Firebase is not configured."
        case .notAuthenticated: return "Not signed in."
        case .decodingFailed(let message): return message
        }
    }
}
