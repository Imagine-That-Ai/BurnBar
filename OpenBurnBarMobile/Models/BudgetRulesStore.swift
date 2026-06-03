import FirebaseAuth
import FirebaseFirestore
import Foundation
import OpenBurnBarCore

/// Firestore-backed CRUD layer for budget rules and audit events on iOS.
///
/// Mirrors the macOS `BudgetRulesStore` API surface (which is GRDB-backed) but persists
/// directly to Firestore at `users/{uid}/budgetRules/{ruleId}` and
/// `users/{uid}/budgetEvents/{eventId}`. The `BudgetSettings` observable store wraps this;
/// `BudgetLedger` reads via this; Hermes / MCP write through this.
///
/// **This is intentionally NOT `@Observable`** — it's a raw CRUD layer. Observable state
/// lives in `BudgetSettings`.
@MainActor
final class BudgetRulesStore {
    private var listener: ListenerRegistration?

    #if DEBUG
    private var mockRules: [String: BudgetRule] = [:]
    private var mockEvents: [BudgetEvent] = []
    private var mockListenerCallback: (([BudgetRule]) -> Void)?

    private var isTestingMode: Bool {
        return Auth.auth().currentUser == nil
    }
    #endif

    // MARK: - Firestore references

    private var uid: String? { Auth.auth().currentUser?.uid }

    private func rulesCollection() -> CollectionReference? {
        guard let uid else { return nil }
        return Firestore.firestore().collection("users").document(uid).collection("budgetRules")
    }

    private func eventsCollection() -> CollectionReference? {
        guard let uid else { return nil }
        return Firestore.firestore().collection("users").document(uid).collection("budgetEvents")
    }

    // MARK: - Rules

    /// Upsert a budget rule into Firestore. Uses `setData(merge: true)` to match the
    /// macOS `CloudBudgetService` upload pattern — partial updates don't clobber
    /// server-set fields.
    func upsertRule(_ rule: BudgetRule) async throws {
        #if DEBUG
        if isTestingMode {
            mockRules[rule.id] = rule
            mockListenerCallback?(Array(mockRules.values).filter { $0.isEnabled }.sorted(by: { $0.createdAt > $1.createdAt }))
            return
        }
        #endif
        guard let collection = rulesCollection() else { return }
        let data = encodeRule(rule)
        try await collection.document(rule.id).setData(data, merge: true)
    }

    /// Deletes a budget rule document from Firestore.
    func deleteRule(id: String) async throws {
        #if DEBUG
        if isTestingMode {
            mockRules.removeValue(forKey: id)
            mockListenerCallback?(Array(mockRules.values).filter { $0.isEnabled }.sorted(by: { $0.createdAt > $1.createdAt }))
            return
        }
        #endif
        guard let collection = rulesCollection() else { return }
        try await collection.document(id).delete()
    }

    /// Fetches all budget rules, optionally including disabled ones.
    /// Returns an empty array if the user is not signed in.
    func fetchAllRules(includeDisabled: Bool = false) async throws -> [BudgetRule] {
        #if DEBUG
        if isTestingMode {
            return Array(mockRules.values)
                .filter { includeDisabled ? true : $0.isEnabled }
                .sorted { $0.createdAt > $1.createdAt }
        }
        #endif
        guard let collection = rulesCollection() else { return [] }

        let query: Query
        if includeDisabled {
            query = collection.order(by: "createdAt", descending: true)
        } else {
            query = collection
                .whereField("isEnabled", isEqualTo: true)
                .order(by: "createdAt", descending: true)
        }

        let snapshot = try await query.getDocuments()
        return snapshot.documents.compactMap { decodeRule(from: $0.data(), id: $0.documentID) }
    }

    /// Fetches a single rule by ID. Returns `nil` if not found or user is not signed in.
    func fetchRule(id: String) async throws -> BudgetRule? {
        #if DEBUG
        if isTestingMode {
            return mockRules[id]
        }
        #endif
        guard let collection = rulesCollection() else { return nil }
        let doc = try await collection.document(id).getDocument()
        guard let data = doc.data() else { return nil }
        return decodeRule(from: data, id: doc.documentID)
    }

    // MARK: - Events

    /// Records a budget audit event to Firestore. Events are append-only.
    func recordEvent(_ event: BudgetEvent) async throws {
        #if DEBUG
        if isTestingMode {
            mockEvents.append(event)
            return
        }
        #endif
        guard let collection = eventsCollection() else { return }
        let data = encodeEvent(event)
        try await collection.document(event.id).setData(data)
    }

    /// Fetches recent audit events, optionally filtered by rule ID.
    func recentEvents(forRule ruleID: String? = nil, limit: Int = 100) async throws -> [BudgetEvent] {
        #if DEBUG
        if isTestingMode {
            let filtered = mockEvents.filter { ruleID == nil ? true : $0.ruleID == ruleID }
            return Array(filtered.suffix(limit).reversed())
        }
        #endif
        guard let collection = eventsCollection() else { return [] }

        var query: Query
        if let ruleID {
            query = collection
                .whereField("ruleID", isEqualTo: ruleID)
                .order(by: "occurredAt", descending: true)
                .limit(to: limit)
        } else {
            query = collection
                .order(by: "occurredAt", descending: true)
                .limit(to: limit)
        }

        let snapshot = try await query.getDocuments()
        return snapshot.documents.compactMap { decodeEvent(from: $0.data(), id: $0.documentID) }
    }

    // MARK: - Real-time Listener

    /// Attaches a Firestore snapshot listener to the `budgetRules` collection. Enabled
    /// rules are delivered to the callback on every server or local change.
    ///
    /// Call `stopListening()` to remove the listener.
    func startListening(onChange: @escaping ([BudgetRule]) -> Void) {
        stopListening()
        #if DEBUG
        if isTestingMode {
            mockListenerCallback = onChange
            onChange(Array(mockRules.values).filter { $0.isEnabled }.sorted(by: { $0.createdAt > $1.createdAt }))
            return
        }
        #endif
        guard let collection = rulesCollection() else { return }

        listener = collection
            .whereField("isEnabled", isEqualTo: true)
            .addSnapshotListener { snapshot, error in
                guard let snapshot, error == nil else { return }
                let rules = snapshot.documents
                    .compactMap { self.decodeRule(from: $0.data(), id: $0.documentID) }
                    .sorted { ($0.createdAt) > ($1.createdAt) }
                onChange(rules)
            }
    }

    /// Removes the active Firestore snapshot listener, if any.
    func stopListening() {
        #if DEBUG
        if isTestingMode {
            mockListenerCallback = nil
            return
        }
        #endif
        listener?.remove()
        listener = nil
    }

    // MARK: - Encoding

    /// Encodes a `BudgetRule` into a Firestore-compatible dictionary.
    /// Matches the macOS `CloudBudgetService.encodeRule` encoding exactly — dates are
    /// written as `Timestamp`, nil values are stripped via `compactMapValues`.
    private func encodeRule(_ rule: BudgetRule, vaultKey: Data) throws -> [String: Any] {
        var data: [String: Any] = [
            "id": rule.id,
            "scope": rule.scope.rawValue,
            "identifier": rule.identifier as Any,
            "providerID": rule.providerID as Any,
            "accountID": rule.accountID as Any,
            "amountUSD": rule.amountUSD,
            "period": rule.period.rawValue,
            "behavior": rule.behavior.rawValue,
            "fallbackCredentialIDsJSON": encodeFallbackIDs(rule.fallbackCredentialIDs) as Any,
            "pausedUntil": rule.pausedUntil.map { Timestamp(date: $0) } as Any,
            "createdAt": Timestamp(date: rule.createdAt),
            "updatedAt": Timestamp(date: rule.updatedAt),
            "syncedAt": rule.syncedAt.map { Timestamp(date: $0) } as Any,
            "sourceDeviceID": rule.sourceDeviceID as Any,
            "isEnabled": rule.isEnabled,
        ]
        // Seal the private project name + label instead of writing them in clear.
        if let projectName = rule.projectName {
            data["sealedProjectName"] = try CloudVaultCrypto.dictionary(
                CloudVaultCrypto.sealText(projectName, keyData: vaultKey)
            )
            if let projectKeyHash = CloudVaultCrypto.projectKeyHash(for: projectName, keyData: vaultKey) {
                data["projectKeyHash"] = projectKeyHash
            }
        }
        if let label = rule.label {
            data["sealedLabel"] = try CloudVaultCrypto.dictionary(
                CloudVaultCrypto.sealText(label, keyData: vaultKey)
            )
        }
        // Firestore doesn't tolerate nil values in setData — remove them
        data = data.compactMapValues { value -> Any? in
            if value is NSNull { return nil }
            // `as Any` wrapping on nil optionals produces NSNull on some paths;
            // additionally filter out Optional.none bridged values.
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional, mirror.children.isEmpty { return nil }
            return value
        }
        return data
    }

    /// Encodes a `BudgetEvent` into a Firestore-compatible dictionary.
    /// Matches the macOS `CloudBudgetService.encodeEvent` encoding exactly.
    private func encodeEvent(_ event: BudgetEvent) -> [String: Any] {
        var data: [String: Any] = [
            "id": event.id,
            "ruleID": event.ruleID,
            "kind": event.kind.rawValue,
            "source": event.source as Any,
            "amountAtEvent": event.amountAtEvent,
            "limitAtEvent": event.limitAtEvent,
            "detailJSON": event.detailJSON as Any,
            "occurredAt": Timestamp(date: event.occurredAt),
            "syncedAt": event.syncedAt.map { Timestamp(date: $0) } as Any,
            "sourceDeviceID": event.sourceDeviceID as Any,
        ]
        data = data.compactMapValues { value -> Any? in
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional, mirror.children.isEmpty { return nil }
            return value
        }
        return data
    }

    // MARK: - Decoding

    /// Decodes a `BudgetRule` from a Firestore document dictionary. Handles Firestore
    /// `Timestamp` fields and falls back to `Date()` for missing date fields.
    ///
    /// This is identical to `CloudBudgetService.decodeRule` on macOS but uses
    /// Firestore's `Timestamp.dateValue()` instead of raw `Date` casts.
    private func decodeRule(from data: [String: Any], id: String, vaultKey: Data?) -> BudgetRule? {
        guard let scopeRaw = data["scope"] as? String,
              let scope = BudgetRuleScope(rawValue: scopeRaw),
              let periodRaw = data["period"] as? String,
              let period = BudgetPeriod(rawValue: periodRaw),
              let behaviorRaw = data["behavior"] as? String,
              let behavior = BudgetBehavior(rawValue: behaviorRaw),
              let amount = data["amountUSD"] as? Double else {
            return nil
        }

        var fallbacks: [String] = []
        if let json = data["fallbackCredentialIDsJSON"] as? String,
           let jsonData = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: jsonData) {
            fallbacks = decoded
        }

        // Open sealed project name/label; fall back to legacy plaintext for
        // pre-migration peers that still write the cleartext fields.
        let projectName = CloudVaultCrypto.openSealedProjectName(from: data, keyData: vaultKey)
        let label = CloudVaultCrypto.openSealedProjectName(
            from: data,
            sealedField: "sealedLabel",
            legacyField: "label",
            keyData: vaultKey
        )

        return BudgetRule(
            id: id,
            scope: scope,
            identifier: data["identifier"] as? String,
            providerID: data["providerID"] as? String,
            accountID: data["accountID"] as? String,
            projectName: projectName,
            label: label,
            amountUSD: amount,
            period: period,
            behavior: behavior,
            fallbackCredentialIDs: fallbacks,
            pausedUntil: dateFromField(data["pausedUntil"]),
            createdAt: dateFromField(data["createdAt"]) ?? Date(),
            updatedAt: dateFromField(data["updatedAt"]) ?? Date(),
            syncedAt: dateFromField(data["syncedAt"]),
            sourceDeviceID: data["sourceDeviceID"] as? String,
            isEnabled: (data["isEnabled"] as? Bool) ?? true
        )
    }

    /// Decodes a `BudgetEvent` from a Firestore document dictionary.
    private func decodeEvent(from data: [String: Any], id: String) -> BudgetEvent? {
        guard let ruleID = data["ruleID"] as? String,
              let kindRaw = data["kind"] as? String,
              let kind = BudgetEventKind(rawValue: kindRaw) else {
            return nil
        }

        return BudgetEvent(
            id: id,
            ruleID: ruleID,
            kind: kind,
            source: data["source"] as? String,
            amountAtEvent: (data["amountAtEvent"] as? Double) ?? 0,
            limitAtEvent: (data["limitAtEvent"] as? Double) ?? 0,
            detailJSON: data["detailJSON"] as? String,
            occurredAt: dateFromField(data["occurredAt"]) ?? Date(),
            syncedAt: dateFromField(data["syncedAt"]),
            sourceDeviceID: data["sourceDeviceID"] as? String
        )
    }

    // MARK: - Private helpers

    /// Converts a Firestore field value to `Date`, handling both Firestore `Timestamp`
    /// and raw `Date` (from Codable round-trips).
    private func dateFromField(_ raw: Any?) -> Date? {
        if let ts = raw as? Timestamp { return ts.dateValue() }
        if let date = raw as? Date { return date }
        return nil
    }

    /// Encodes fallback credential IDs to a JSON string, or returns `nil` if empty.
    private func encodeFallbackIDs(_ ids: [String]) -> String? {
        guard !ids.isEmpty,
              let data = try? JSONEncoder().encode(ids) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
