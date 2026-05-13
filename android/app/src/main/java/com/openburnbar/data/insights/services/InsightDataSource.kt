package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightTimeWindow

/**
 * Interface for building a privacy-bounded digest from local data sources.
 * Android builds its digest from Firestore rollups + direct provider APIs,
 * not from local SQLite (which doesn't exist on Android).
 */
interface InsightDataSource {
    suspend fun buildDigest(filter: InsightFilter): InsightDigest
    suspend fun buildDigest(window: InsightTimeWindow): InsightDigest
}
