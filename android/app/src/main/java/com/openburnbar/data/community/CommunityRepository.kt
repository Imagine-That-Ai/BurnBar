package com.openburnbar.data.community

import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.CommunityShareSnapshotDoc
import com.openburnbar.data.models.generated.FirestoreCommunityConsentDoc
import com.openburnbar.data.models.generated.FirestoreCommunityLeaderboardDoc
import com.openburnbar.data.models.generated.FirestoreCommunityProfileDoc
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.tasks.await

class CommunityRepository(
    private val firestoreRepo: FirestoreRepository = FirestoreRepository(),
    private val db: FirebaseFirestore = FirebaseFirestore.getInstance(),
) {
    suspend fun fetchConsent(): FirestoreCommunityConsentDoc? {
        val uid = firestoreRepo.currentUserId()
        val snap = db.document(CommunityPaths.consent(uid)).get().await()
        return snap.toObject(FirestoreCommunityConsentDoc::class.java)
    }

    suspend fun fetchProfile(): FirestoreCommunityProfileDoc? {
        val uid = firestoreRepo.currentUserId()
        val snap = db.document(CommunityPaths.profile(uid)).get().await()
        return snap.toObject(FirestoreCommunityProfileDoc::class.java)
    }

    suspend fun fetchShareSnapshot(): CommunityShareSnapshotDoc? {
        val uid = firestoreRepo.currentUserId()
        val snap = db.document(CommunityPaths.shareSnapshot(uid)).get().await()
        return snap.toObject(CommunityShareSnapshotDoc::class.java)
    }

    suspend fun fetchLeaderboard(
        window: String,
        tier: String,
        geoKey: String,
    ): FirestoreCommunityLeaderboardDoc? {
        val snap = db.document(CommunityPaths.leaderboard(window, tier, geoKey)).get().await()
        return snap.toObject(FirestoreCommunityLeaderboardDoc::class.java)
    }

    fun listenLeaderboard(
        window: String,
        tier: String,
        geoKey: String,
    ): Flow<FirestoreCommunityLeaderboardDoc?> = callbackFlow {
        val ref = db.document(CommunityPaths.leaderboard(window, tier, geoKey))
        val registration: ListenerRegistration =
            ref.addSnapshotListener { snapshot, error ->
                if (error != null) {
                    close(error)
                    return@addSnapshotListener
                }
                trySend(snapshot?.toObject(FirestoreCommunityLeaderboardDoc::class.java))
            }
        awaitClose { registration.remove() }
    }
}