package com.openburnbar.data.community

import com.openburnbar.data.models.generated.FirestoreCommunityShareSnapshotDoc
import com.openburnbar.data.models.generated.FirestoreCommunityUsageTotal

fun FirestoreCommunityShareSnapshotDoc.usageForWindow(window: CommunityTimeWindow): FirestoreCommunityUsageTotal = when (window) {
    CommunityTimeWindow.TODAY -> windows.today
    CommunityTimeWindow.SEVEN_DAY -> windows.sevenDay
    CommunityTimeWindow.THIRTY_DAY -> windows.thirtyDay
    CommunityTimeWindow.NINETY_DAY -> windows.ninetyDay
    CommunityTimeWindow.ALL_TIME -> windows.allTime
}

enum class CommunityTimeWindow(val wire: String, val label: String) {
    TODAY("today", "Today"),
    SEVEN_DAY("7d", "7d"),
    THIRTY_DAY("30d", "30d"),
    NINETY_DAY("90d", "90d"),
    ALL_TIME("all_time", "All"),
}

enum class CommunityGeoTier(val wire: String, val label: String) {
    CITY("city", "City"),
    REGION("region", "Region"),
    COUNTRY("country", "Country"),
    WORLD("world", "World"),
}
