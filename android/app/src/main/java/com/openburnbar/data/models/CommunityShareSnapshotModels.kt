// Hand-maintained — not emitted by tools/schema-sync (Record<> + @encodedName
// don't round-trip through check-tsp-canon). Canonical doc:
// tools/schema-sync/typespec/domains/community.tsp (tspOnlyModels).
package com.openburnbar.data.models

import androidx.annotation.Keep
import com.google.firebase.firestore.IgnoreExtraProperties
import com.google.firebase.firestore.PropertyName

@Keep
@IgnoreExtraProperties
data class CommunityUsageTotal(
    val totalTokens: Long = 0,
    val costUSD: Double = 0.0,
)

@Keep
@IgnoreExtraProperties
data class CommunityWindowTotals(
    @get:PropertyName("today") @set:PropertyName("today")
    var today: CommunityUsageTotal = CommunityUsageTotal(),
    @get:PropertyName("7d") @set:PropertyName("7d")
    var sevenDay: CommunityUsageTotal = CommunityUsageTotal(),
    @get:PropertyName("30d") @set:PropertyName("30d")
    var thirtyDay: CommunityUsageTotal = CommunityUsageTotal(),
    @get:PropertyName("90d") @set:PropertyName("90d")
    var ninetyDay: CommunityUsageTotal = CommunityUsageTotal(),
    @get:PropertyName("all_time") @set:PropertyName("all_time")
    var allTime: CommunityUsageTotal = CommunityUsageTotal(),
)

/// Firestore: users/{uid}/community/share_snapshot
@Keep
@IgnoreExtraProperties
data class CommunityShareSnapshotDoc(
    val windows: CommunityWindowTotals = CommunityWindowTotals(),
    val modelMix: Map<String, Double> = emptyMap(),
    val purposeMix: Map<String, Double> = emptyMap(),
    val sessionCount: Long? = null,
    val countryCode: String? = null,
    val regionKey: String? = null,
    val cityKey: String? = null,
    val revoked: Boolean? = null,
    val schemaVersion: Long = 1,
    val updatedAt: String = "",
)
