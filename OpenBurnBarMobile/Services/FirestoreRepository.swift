import Foundation
import FirebaseAuth
import FirebaseFirestore
import OpenBurnBarCore
import OSLog

private let logger = Logger(subsystem: "com.openburnbar.mobile", category: "FirestoreRepository")

// MARK: - Firestore Repository

@MainActor
final class FirestoreRepository {
    static let shared = FirestoreRepository()

    private let db = Firestore.firestore()

    private func uid() throws -> String {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw FirestoreError.notAuthenticated
        }
        return uid
    }

    // MARK: - ISO 8601 Date Detection

    /// Returns `true` when a string matches ISO-8601 instant format.
    /// Used by `sanitizeForJSON` so Cloud Function date strings convert
    /// to the Double epoch that `JSONDecoder.deferredToDate` expects.
    private static let isoDateRegex = try! NSRegularExpression(
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
    /// - `Timestamp` → `timeIntervalSinceReferenceDate` Double
    /// - ISO 8601 date strings (e.g. `computedAt`, `fetchedAt`) → Double
    /// - Nested dicts/arrays → recursively sanitized
    nonisolated func sanitizeForJSON(_ value: Any) -> Any {
        switch value {
        case let ts as Timestamp:
            return ts.dateValue().timeIntervalSinceReferenceDate
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
            return dict.mapValues { sanitizeForJSON($0) }
        case let arr as [Any]:
            return arr.map { sanitizeForJSON($0) }
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
        if enriched["deviceId"] != nil && enriched["sourceDeviceId"] == nil {
            enriched["sourceDeviceId"] = enriched["deviceId"]
        }
        let sanitized = sanitizeForJSON(enriched) as? [String: Any] ?? enriched
        guard let jsonData = try? JSONSerialization.data(withJSONObject: sanitized) else {
            logger.warning("Failed to serialize Firestore data for document \(docID): \(String(describing: T.self))")
            return nil
        }
        do {
            return try JSONDecoder().decode(T.self, from: jsonData)
        } catch {
            logger.error("Failed to decode \(String(describing: T.self)) for document \(docID): \(error.localizedDescription)")
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
        let snapshot = try await db.collection("users/\(uid)/quota_snapshots").getDocuments()
        let results = snapshot.documents.compactMap { doc -> ProviderQuotaSnapshot? in
            decodeWithDocID(ProviderQuotaSnapshot.self, from: doc.data(), docID: doc.documentID)
        }
        logger.info("Fetched \(results.count) quota snapshots")
        return results
    }

    func listenToQuotaSnapshots(
        onUpdate: @escaping @Sendable (Result<[ProviderQuotaSnapshot], Error>) -> Void
    ) -> ListenerRegistration? {
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
            let results = (snapshot?.documents ?? []).compactMap { doc -> ProviderQuotaSnapshot? in
                self.decodeWithDocID(ProviderQuotaSnapshot.self, from: doc.data(), docID: doc.documentID)
            }
            logger.debug("Quota listener update: \(results.count) snapshots")
            onUpdate(.success(results))
        }
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

    // MARK: - Provider Connections

    func fetchProviderConnections() async throws -> [ProviderConnectionDoc] {
        let uid = try uid()
        let snapshot = try await db.collection("users/\(uid)/provider_connections").getDocuments()
        let results = snapshot.documents.compactMap { doc -> ProviderConnectionDoc? in
            decodeWithDocID(ProviderConnectionDoc.self, from: doc.data(), docID: doc.documentID)
        }
        logger.info("Fetched \(results.count) provider connections")
        return results
    }
}

// MARK: - Firestore Error

enum FirestoreError: Error, LocalizedError {
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in."
        }
    }
}
