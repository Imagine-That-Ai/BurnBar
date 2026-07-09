package com.openburnbar.data.community

import com.google.firebase.firestore.ListenerRegistration
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.generated.FirestoreCommunityConsentDoc
import com.openburnbar.data.models.generated.FirestoreCommunityLeaderboardDoc
import com.openburnbar.data.models.generated.FirestoreCommunityProfileDoc
import com.openburnbar.data.models.generated.FirestoreCommunityShareSnapshotDoc
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

class CommunityRepository(
    private val firestoreRepo: FirestoreRepository = FirestoreRepository(),
) {
    suspend fun fetchConsent(): FirestoreCommunityConsentDoc? {
        val uid = firestoreRepo.currentUserId()
        val snap = firestoreRepo.fetchDocument(CommunityPaths.consent(uid))
        return snap.toObject(FirestoreCommunityConsentDoc::class.java)
    }

    suspend fun fetchProfile(): FirestoreCommunityProfileDoc? {
        val uid = firestoreRepo.currentUserId()
        val snap = firestoreRepo.fetchDocument(CommunityPaths.profile(uid))
        return snap.toObject(FirestoreCommunityProfileDoc::class.java)
    }

    suspend fun fetchShareSnapshot(): FirestoreCommunityShareSnapshotDoc? {
        val uid = firestoreRepo.currentUserId()
        val snap = firestoreRepo.fetchDocument(CommunityPaths.shareSnapshot(uid))
        return snap.toObject(FirestoreCommunityShareSnapshotDoc::class.java)
    }

    suspend fun fetchLeaderboard(window: String, tier: String, geoKey: String): FirestoreCommunityLeaderboardDoc? {
        val snap = firestoreRepo.fetchDocument(CommunityPaths.leaderboard(window, tier, geoKey))
        return snap.toObject(FirestoreCommunityLeaderboardDoc::class.java)
    }

    fun listenLeaderboard(window: String, tier: String, geoKey: String): Flow<FirestoreCommunityLeaderboardDoc?> = callbackFlow {
        val registration: ListenerRegistration =
            firestoreRepo.listenDocument(CommunityPaths.leaderboard(window, tier, geoKey)) listener@{ snapshot, error ->
                if (error != null) {
                    close(error)
                    return@listener
                }
                trySend(snapshot?.toObject(FirestoreCommunityLeaderboardDoc::class.java))
            }
        awaitClose { registration.remove() }
    }
}
