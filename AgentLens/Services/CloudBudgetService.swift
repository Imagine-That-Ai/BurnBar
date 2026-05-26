import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarCore

/// Syncs `budget_rules` and `budget_events` to Firestore for enterprise cross-seat
/// rollup (Phase 8). Mirrors the `CloudSyncService` upload/download pattern: local
/// rows with `syncedAt == nil` are pushed; remote rows not present locally are pulled.
///
/// Org-level aggregate queries (`burnbar_org_spend`) are served by the MCP server
/// directly against `token_usage` since CloudSync already syncs every usage row —
/// no separate aggregation pipeline is needed for per-seat spend reporting.
@MainActor
final class CloudBudgetService {
    private let dataStore: DataStore
    private let accountManager: AccountManager
    private let budgetSettings: BudgetSettings
    private let budgetRulesStore: BudgetRulesStore

    init(dataStore: DataStore, accountManager: AccountManager, budgetSettings: BudgetSettings, budgetRulesStore: BudgetRulesStore) {
        self.dataStore = dataStore
        self.accountManager = accountManager
        self.budgetSettings = budgetSettings
        self.budgetRulesStore = budgetRulesStore
    }

    // MARK: - Upload

    /// Pushes all local budget_rules and budget_events with `syncedAt == nil` to Firestore.
    /// Layout: `users/{uid}/budgetRules/{ruleId}` and `users/{uid}/budgetEvents/{eventId}`.
    func uploadPendingBudgetRules() async {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              let uid = Auth.auth().currentUser?.uid else { return }

        let db = Firestore.firestore()

        // Upload rules with no syncedAt
        do {
            let unsyncedRules = try budgetRulesStore.fetchAllRules(includeDisabled: true)
                .filter { $0.syncedAt == nil }

            for rule in unsyncedRules {
                let docRef = db.collection("users").document(uid)
                    .collection("budgetRules").document(rule.id)
                let data = encodeRule(rule)
                try await docRef.setData(data, merge: true)

                // Mark as synced locally
                var synced = rule
                synced.syncedAt = Date()
                try budgetRulesStore.upsertRule(synced)
            }
        } catch {
            // Best-effort; next sync cycle retries.
        }

        // Upload events with no syncedAt (last 500 max per sync to cap bandwidth)
        do {
            let unsyncedEvents = try budgetRulesStore.recentEvents(limit: 500)
                .filter { $0.syncedAt == nil }

            for event in unsyncedEvents {
                let docRef = db.collection("users").document(uid)
                    .collection("budgetEvents").document(event.id)
                let data = encodeEvent(event)
                try await docRef.setData(data, merge: true)

                // Mark synced — we update the local row's syncedAt directly via GRDB
                try budgetRulesStore.markEventSynced(event.id)
            }
        } catch {
            // Best-effort
        }
    }

    // MARK: - Download

    /// Pulls remote budget rules that don't exist locally or have a newer `updatedAt`.
    /// Events are append-only and never edited remotely, so we only pull rules.
    func downloadRemoteBudgetRules() async {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              let uid = Auth.auth().currentUser?.uid else { return }

        let db = Firestore.firestore()
        let localRules: [BudgetRule]
        do {
            localRules = try budgetRulesStore.fetchAllRules(includeDisabled: true)
        } catch {
            return
        }
        let localByID = Dictionary(uniqueKeysWithValues: localRules.map { ($0.id, $0) })

        do {
            let snapshot = try await db.collection("users").document(uid)
                .collection("budgetRules")
                .whereField("sourceDeviceID", isNotEqualTo: accountManager.deviceId)
                .getDocuments()

            for doc in snapshot.documents {
                guard let remoteRule = decodeRule(from: doc.data(), id: doc.documentID) else { continue }
                if let local = localByID[remoteRule.id] {
                    // Remote wins on conflict if newer
                    if remoteRule.updatedAt > local.updatedAt {
                        try budgetRulesStore.upsertRule(remoteRule)
                    }
                } else {
                    // New rule from another seat
                    try budgetRulesStore.upsertRule(remoteRule)
                }
            }
        } catch {
            // Best-effort
        }

        budgetSettings.refresh()
    }

    // MARK: - Encoding / Decoding

    private func encodeRule(_ rule: BudgetRule) -> [String: Any] {
        var data: [String: Any] = [
            "id": rule.id,
            "scope": rule.scope.rawValue,
            "identifier": rule.identifier as Any,
            "providerID": rule.providerID as Any,
            "accountID": rule.accountID as Any,
            "projectName": rule.projectName as Any,
            "label": rule.label as Any,
            "amountUSD": rule.amountUSD,
            "period": rule.period.rawValue,
            "behavior": rule.behavior.rawValue,
            "fallbackCredentialIDsJSON": (try? JSONEncoder().encode(rule.fallbackCredentialIDs)).flatMap { String(data: $0, encoding: .utf8) } as Any,
            "pausedUntil": rule.pausedUntil as Any,
            "createdAt": rule.createdAt,
            "updatedAt": rule.updatedAt,
            "syncedAt": rule.syncedAt as Any,
            "sourceDeviceID": rule.sourceDeviceID as Any,
            "isEnabled": rule.isEnabled,
        ]
        // Firestore doesn't tolerate nil values in setData — remove them
        data = data.compactMapValues { $0 }
        return data
    }

    private func encodeEvent(_ event: BudgetEvent) -> [String: Any] {
        var data: [String: Any] = [
            "id": event.id,
            "ruleID": event.ruleID,
            "kind": event.kind.rawValue,
            "source": event.source as Any,
            "amountAtEvent": event.amountAtEvent,
            "limitAtEvent": event.limitAtEvent,
            "detailJSON": event.detailJSON as Any,
            "occurredAt": event.occurredAt,
            "syncedAt": event.syncedAt as Any,
            "sourceDeviceID": event.sourceDeviceID as Any,
        ]
        data = data.compactMapValues { $0 }
        return data
    }

    private func decodeRule(from data: [String: Any], id: String) -> BudgetRule? {
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
        return BudgetRule(
            id: id,
            scope: scope,
            identifier: data["identifier"] as? String,
            providerID: data["providerID"] as? String,
            accountID: data["accountID"] as? String,
            projectName: data["projectName"] as? String,
            label: data["label"] as? String,
            amountUSD: amount,
            period: period,
            behavior: behavior,
            fallbackCredentialIDs: fallbacks,
            pausedUntil: data["pausedUntil"] as? Date,
            createdAt: data["createdAt"] as? Date ?? Date(),
            updatedAt: data["updatedAt"] as? Date ?? Date(),
            syncedAt: data["syncedAt"] as? Date,
            sourceDeviceID: data["sourceDeviceID"] as? String,
            isEnabled: (data["isEnabled"] as? Bool) ?? true
        )
    }
}

// MARK: - Dictionary helper

private extension Dictionary {
    func compactMapValues(_ transform: (Value) -> Value?) -> [Key: Value] {
        var result: [Key: Value] = [:]
        for (key, value) in self {
            if let newValue = transform(value) {
                result[key] = newValue
            }
        }
        return result
    }
}
