package com.openburnbar.ui.community

import android.app.Application
import com.openburnbar.data.models.generated.FirestoreCommunityConsentDoc
import com.openburnbar.data.models.generated.FirestoreCommunityProfileDoc
import com.openburnbar.data.models.generated.FirestoreCommunityTierConsent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CommunityParticipationStateTest {
    @Test
    fun viewModelExposesApplicationConstructorForSavedStateFactory() {
        assertNotNull(CommunityViewModel::class.java.getConstructor(Application::class.java))
    }

    @Test
    fun l3OnlyConsentStillExposesRevokeControls() {
        val consent = FirestoreCommunityConsentDoc(l3LookingGlass = "granted")

        assertTrue(hasServerCommunityParticipation(consent, null, null))
    }

    @Test
    fun pausedRankingsWithProfileStillExposesRevokeControls() {
        val consent = FirestoreCommunityConsentDoc(
            l2Rankings = "declined",
            l2Tiers = FirestoreCommunityTierConsent(),
        )

        assertTrue(
            hasServerCommunityParticipation(
                consent,
                FirestoreCommunityProfileDoc(anonId = "anon-1"),
                null,
            ),
        )
    }

    @Test
    fun fullyRevokedTombstoneWithoutProfileOrSnapshotIsNotParticipation() {
        val consent = FirestoreCommunityConsentDoc(
            l1Analytics = "declined",
            l2Rankings = "declined",
            l3LookingGlass = "declined",
            locationConsent = "declined",
        )

        assertFalse(hasServerCommunityParticipation(consent, null, null))
    }
}
