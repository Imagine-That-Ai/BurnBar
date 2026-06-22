package com.openburnbar.ui.insights

import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightModelTag
import org.junit.Assert.assertEquals
import org.junit.Test

class InsightsViewModelTest {
    @Test
    fun `follow-up keeps visible local rules selection local`() {
        val selected =
            InsightModelTag(
                providerKey = "local-rules",
                modelID = "local-rules-v1",
                displayName = "Local rules",
                egressTier = InsightEgressTier.LOCAL_ONLY,
            )

        val resolved =
            InsightsViewModel.resolvedAnalysisModel(
                selected = selected,
                instruction = InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP,
            )

        assertEquals("local-rules", resolved.providerKey)
        assertEquals(InsightEgressTier.LOCAL_ONLY, resolved.egressTier)
    }

    @Test
    fun `default brief preserves selected non-local model`() {
        val selected =
            InsightModelTag(
                providerKey = "hermes",
                modelID = "hermes-auto",
                displayName = "Hermes",
                egressTier = InsightEgressTier.USER_RELAY,
            )

        val resolved =
            InsightsViewModel.resolvedAnalysisModel(
                selected = selected,
                instruction = InsightAnalysisRequest.Instruction.DEFAULT_BRIEF,
            )

        assertEquals("hermes", resolved.providerKey)
        assertEquals(InsightEgressTier.USER_RELAY, resolved.egressTier)
    }
}
