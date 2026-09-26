package com.openburnbar.data.models

import com.openburnbar.data.models.generated.FirestoreUsageEventDoc

fun tokenUsageFromGenerated(doc: FirestoreUsageEventDoc, id: String): TokenUsage? {
    val provider = doc.provider.trim()
    val recordedAt = doc.recordedAt.trim()
    if (provider.isEmpty() || recordedAt.isEmpty()) return null
    return TokenUsage(
        id = id,
        provider = provider,
        providerId = doc.providerId,
        providerAccountId = doc.providerAccountId,
        providerAccountLabel = doc.providerAccountLabel,
        providerAccountSource = doc.providerAccountSource,
        model = doc.model,
        sessionId = doc.sessionId,
        deviceId = doc.deviceId,
        sourceDeviceId = doc.sourceDeviceId,
        executionSourceId = doc.executionSourceId,
        executionSourceName = doc.executionSourceName,
        executionSourceKind = doc.executionSourceKind,
        executionSourceConfidence = doc.executionSourceConfidence,
        inputTokens = doc.inputTokens?.toInt() ?: 0,
        outputTokens = doc.outputTokens?.toInt() ?: 0,
        cacheReadTokens = doc.cacheReadTokens?.toInt() ?: 0,
        cacheWriteTokens = doc.cacheWriteTokens?.toInt() ?: 0,
        totalTokens = doc.totalTokens?.toInt() ?: 0,
        // Wave 2.5: absent stays absent (null) so it falls through the
        // shared cost rule; coercing to 0.0 here would wrongly WIN over
        // legacy spellings.
        costUSD = doc.costUSD,
        currency = doc.currency,
        recordedAt = recordedAt,
        eventKind = doc.eventKind,
        idempotencyKey = doc.idempotencyKey,
    )
}
