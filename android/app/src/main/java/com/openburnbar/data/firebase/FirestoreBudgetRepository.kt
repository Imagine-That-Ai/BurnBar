package com.openburnbar.data.firebase

import com.google.firebase.firestore.CollectionReference
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.data.cloud.AndroidCloudVaultKeyAccess
import com.openburnbar.data.models.BudgetEvent
import com.openburnbar.data.models.BudgetRule
import kotlinx.coroutines.tasks.await

internal class FirestoreBudgetRepository(
    private val db: FirebaseFirestore,
    private val currentUserId: () -> String,
) {
    private val budgetRulesCollection: CollectionReference
        get() = db.collection("users").document(currentUserId()).collection("budgetRules")

    private val budgetEventsCollection: CollectionReference
        get() = db.collection("users").document(currentUserId()).collection("budgetEvents")

    suspend fun uploadBudgetRule(rule: BudgetRule) {
        budgetRulesCollection.document(rule.id).set(rule.toMap()).await()
    }

    suspend fun deleteBudgetRule(id: String) {
        budgetRulesCollection.document(id).delete().await()
    }

    suspend fun uploadBudgetRules(rules: List<BudgetRule>) {
        if (rules.isEmpty()) return
        val batch = db.batch()
        for (rule in rules) {
            batch.set(budgetRulesCollection.document(rule.id), rule.toMap())
        }
        batch.commit().await()
    }

    suspend fun uploadBudgetEvents(events: List<BudgetEvent>) {
        if (events.isEmpty()) return
        val batch = db.batch()
        for (event in events) {
            batch.set(budgetEventsCollection.document(event.id), event.toMap())
        }
        batch.commit().await()
    }

    suspend fun downloadAllBudgetRules(): List<BudgetRule> {
        val snapshot = budgetRulesCollection.get().await()
        // Peer budget rules seal `sealedProjectName`/`sealedLabel`; resolve the read
        // vault key once so the decoder can open them. Legacy plaintext rules fall
        // back inside `toBudgetRule`; an un-approved device degrades to plaintext-only.
        val vaultKey = runCatching {
            AndroidCloudVaultKeyAccess.keyForReading(uid = currentUserId(), firestore = db)?.keyData
        }.getOrNull()
        return snapshot.documents.mapNotNull { it.toBudgetRule(vaultKey) }
    }
}
