package com.openburnbar.data.models

/**
 * Cloud quota snapshots are stored per provider account and sourceId. Mobile
 * account surfaces should show one row/card per real account, not one row per
 * source document.
 */
fun List<ProviderQuotaSnapshot>.deduplicatedByProviderAccount(): List<ProviderQuotaSnapshot> {
    val merged = groupBy { it.providerAccountDedupKey() }
        .values
        .map { snapshots -> snapshots.mergeQuotaSnapshotGroup() }
        .dropShadowedProviderLevelSnapshots()

    return merged
        .sortedWith(
            compareBy<ProviderQuotaSnapshot> { it.providerDisplaySortKey() }
                .thenBy { it.accountLabel.orEmpty().lowercase() }
                .thenBy { it.accountId.orEmpty() }
        )
}

private fun ProviderQuotaSnapshot.providerAccountDedupKey(): String {
    val providerKey = providerId?.takeIf { it.isNotBlank() } ?: provider
    val accountKey = accountId?.takeIf { it.isNotBlank() }
        ?: accountLabel?.takeIf { it.isNotBlank() }?.trim()?.lowercase()
        ?: "provider-level"
    return "${providerKey.lowercase()}::$accountKey"
}

private fun List<ProviderQuotaSnapshot>.mergeQuotaSnapshotGroup(): ProviderQuotaSnapshot {
    val ordered = sortedWith(
        compareByDescending<ProviderQuotaSnapshot> { it.freshnessKey() }
            .thenByDescending { it.id }
    )
    val latest = ordered.first()
    if (ordered.size == 1) return latest

    if (latest.isExplicitlyStale) {
        return latest.copy(buckets = emptyList())
    }

    val nonExplicitSnapshots = ordered.filter { !it.isExplicitlyStale }
    val freshSnapshots = nonExplicitSnapshots.filter { !it.isTimeStaleForDedupe() }
    val bucketSourceSnapshots = freshSnapshots.ifEmpty { nonExplicitSnapshots }

    val buckets = bucketSourceSnapshots
        .flatMap { snapshot ->
            snapshot.buckets.map { bucket -> bucket.bucketDedupKey() to bucket }
        }
        .distinctBy { (key, _) -> key }
        .map { (_, bucket) -> bucket }

    return latest.copy(
        id = ordered.map { it.id }.filter { it.isNotBlank() }.distinct().joinToString("+"),
        sourceId = ordered.map { it.sourceId }.filter { it.isNotBlank() }.distinct().joinToString(", "),
        accountId = latest.accountId ?: ordered.firstNotNullOfOrNull { it.accountId?.takeIf(String::isNotBlank) },
        accountLabel = latest.accountLabel ?: ordered.firstNotNullOfOrNull { it.accountLabel?.takeIf(String::isNotBlank) },
        accountStorageScope = latest.accountStorageScope ?: ordered.firstNotNullOfOrNull { it.accountStorageScope?.takeIf(String::isNotBlank) },
        fetchedAt = latest.fetchedAt ?: ordered.firstNotNullOfOrNull { it.fetchedAt?.takeIf(String::isNotBlank) },
        source = latest.source ?: ordered.firstNotNullOfOrNull { it.source?.takeIf(String::isNotBlank) },
        confidence = ordered.maxByOrNull { it.confidenceRank() }?.confidence ?: latest.confidence,
        managementUrl = latest.managementUrl ?: ordered.firstNotNullOfOrNull { it.managementUrl?.takeIf(String::isNotBlank) },
        statusMessage = latest.statusMessage ?: ordered.firstNotNullOfOrNull { it.statusMessage?.takeIf(String::isNotBlank) },
        buckets = buckets,
        updatedAt = latest.updatedAt ?: ordered.firstNotNullOfOrNull { it.updatedAt?.takeIf(String::isNotBlank) }
    )
}

private fun ProviderQuotaSnapshot.freshnessKey(): String = updatedAt ?: fetchedAt ?: ""

private fun ProviderQuotaSnapshot.isTimeStaleForDedupe(now: java.time.Instant = java.time.Instant.now()): Boolean {
    val fetched = listOfNotNull(updatedAt, fetchedAt)
        .firstNotNullOfOrNull { iso ->
            iso
                .takeIf { it.isNotBlank() }
                ?.let { runCatching { java.time.Instant.parse(it) }.getOrNull() }
        }
        ?: return true
    return java.time.Duration.between(fetched, now) > java.time.Duration.ofHours(12)
}

private fun ProviderQuotaSnapshot.confidenceRank(): Int = when (confidence.lowercase()) {
    "high" -> 3
    "medium" -> 2
    "low" -> 1
    else -> 0
}

private fun ProviderQuotaSnapshot.providerDisplaySortKey(): String =
    (providerId?.takeIf { it.isNotBlank() } ?: provider).lowercase()

private fun QuotaBucket.bucketDedupKey(): String =
    "${quotaBucketToken(name)}::${quotaBucketToken(window)}::${quotaBucketToken(meta?.get("unit")?.toString())}"

private fun quotaBucketToken(value: String?): String =
    value
        ?.lowercase()
        ?.filter { it.isLetterOrDigit() }
        .orEmpty()

private fun List<ProviderQuotaSnapshot>.dropShadowedProviderLevelSnapshots(): List<ProviderQuotaSnapshot> {
    val providersWithAccountSnapshots = filter { snapshot ->
        !snapshot.accountId.isNullOrBlank() || !snapshot.accountLabel.isNullOrBlank()
    }
        .map { it.providerDisplaySortKey() }
        .toSet()

    if (providersWithAccountSnapshots.isEmpty()) return this

    return filter { snapshot ->
        val isProviderLevel = snapshot.accountId.isNullOrBlank() && snapshot.accountLabel.isNullOrBlank()
        !(isProviderLevel && snapshot.providerDisplaySortKey() in providersWithAccountSnapshots)
    }
}
