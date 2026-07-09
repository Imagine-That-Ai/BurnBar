package com.openburnbar.data.community

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelPurposeClassifierTest {
    @Test
    fun modelBiasTieOrder_matchesO1BeforeDeepseek() {
        val result =
            classifyPurpose(
                ClassifierSignals(model = "o1-deepseek-hybrid"),
            )
        assertEquals(ModelPurposeCategory.RESEARCH, result.category)
        assertTrue(result.confidence >= 0.2)
        assertTrue(result.contributingSignals.contains("model:o1"))
    }

    @Test
    fun uiSwiftFile_matchesGolden() {
        val result =
            classifyPurpose(
                ClassifierSignals(fileExtensions = listOf("swift")),
            )
        assertEquals(ModelPurposeCategory.UI, result.category)
        assertTrue(result.confidence >= 0.5)
    }

    @Test
    fun backendGoSql_matchesGolden() {
        val result =
            classifyPurpose(
                ClassifierSignals(fileExtensions = listOf("go", "sql")),
            )
        assertEquals(ModelPurposeCategory.BACKEND, result.category)
        assertTrue(result.confidence >= 0.5)
    }
}