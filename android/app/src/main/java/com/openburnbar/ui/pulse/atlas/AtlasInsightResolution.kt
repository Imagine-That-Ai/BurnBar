package com.openburnbar.ui.pulse.atlas

import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.derived.TrendInsight
import com.openburnbar.data.derived.TrendInsightEngine

/**
 * Resolves Trend Atlas insights for a digest. A non-null [insights] list
 * (including empty) is caller-supplied and must win; `null` means "compute
 * from the digest." Extracted so JVM tests can cover the memoization
 * decision without composing the card.
 */
internal fun resolvedAtlasInsights(digest: TrendDataDigest, insights: List<TrendInsight>?): List<TrendInsight> {
    if (insights != null) {
        return insights
    }
    return TrendInsightEngine.insights(digest)
}
