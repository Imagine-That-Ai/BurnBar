package com.openburnbar.data.community

object CommunityPaths {
    fun consent(uid: String): String = "users/$uid/community/consent"

    fun profile(uid: String): String = "users/$uid/community/profile"

    fun shareSnapshot(uid: String): String = "users/$uid/community/share_snapshot"

    fun leaderboard(window: String, tier: String, geoKey: String): String =
        "community_leaderboards/${window}_${tier}_$geoKey"
}