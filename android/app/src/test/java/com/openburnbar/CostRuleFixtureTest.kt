package com.openburnbar

import com.openburnbar.data.models.CostRule
import com.openburnbar.data.models.CostSpellings
import java.nio.file.Path
import kotlin.io.path.exists
import kotlin.io.path.readText
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * One cost rule (Wave 2.5, decision 3): the cross-client fixture in
 * `tests/fixtures/cost-rule/v1.json` must produce the identical total here,
 * in Functions, and in Swift — normative spec in
 * `tests/fixtures/cost-rule/README.md`.
 */
class CostRuleFixtureTest {
    @Test
    fun `fixture produces the pinned per-event values and total`() {
        val fixtureFile = findFixture()
        requireNotNull(fixtureFile) {
            "cost-rule fixture missing: expected tests/fixtures/cost-rule/v1.json above ${System.getProperty("user.dir")}"
        }
        val fixture = JSONObject(fixtureFile.readText())
        assertEquals(1, fixture.getInt("version"))

        val events = fixture.getJSONArray("events")
        var total = 0.0
        for (i in 0 until events.length()) {
            val event = events.getJSONObject(i)
            // Strings are never coerced (rule): only JSON numbers become Doubles.
            val effective = CostRule.effectiveCostUSD(
                costUSD = event.optDoubleOrNull("costUSD"),
                costUsd = event.optDoubleOrNull("costUsd"),
                cost = event.optDoubleOrNull("cost"),
            )
            assertEquals("event ${event.getString("id")}", event.getDouble("expectedEffective"), effective, 0.0)
            total += effective
        }
        assertEquals(fixture.getDouble("expectedTotal"), total, 0.0)
    }

    @Test
    fun `totalCostUSD sums effectiveCostUSD over events in order`() {
        val costs = listOf(
            CostSpellings(costUSD = 1.25, costUsd = 999.0),
            CostSpellings(costUsd = 0.04),
            CostSpellings(cost = 0.03),
            CostSpellings(),
        )
        assertEquals(1.32, CostRule.totalCostUSD(costs), 1e-9)
        assertEquals(0.0, CostRule.totalCostUSD(emptyList()), 0.0)
    }

    private fun JSONObject.optDoubleOrNull(key: String): Double? {
        if (isNull(key)) return null
        val value = opt(key)
        return if (value is Number) value.toDouble() else null
    }

    private fun findFixture(): Path? {
        var dir: Path? = Path.of(System.getProperty("user.dir"))
        repeat(5) {
            val candidate = dir?.resolve("tests/fixtures/cost-rule/v1.json")
            if (candidate != null && candidate.exists()) return candidate
            dir = dir?.parent
        }
        return null
    }
}
