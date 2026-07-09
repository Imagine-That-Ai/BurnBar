package com.openburnbar.data.community

import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelPurposeClassifierGoldenTest {
    @Test
    fun classifierGoldens_matchSharedFixture() {
        val fixtures = loadGoldens()
        for (i in 0 until fixtures.length()) {
            val fixture = fixtures.getJSONObject(i)
            val name = fixture.getString("name")
            if (fixture.has("expectedFingerprint")) {
                continue
            }
            val signalsJson = fixture.getJSONObject("signals")
            val signals = parseSignals(signalsJson)
            val corrections =
                if (fixture.has("corrections")) {
                    parseCorrections(fixture.getJSONArray("corrections"))
                } else {
                    emptyList()
                }
            val result = classifyPurpose(signals, corrections)
            if (fixture.has("expected")) {
                val expected = fixture.getString("expected")
                assertEquals("golden '$name' category", expected, result.category.name.lowercase())
            }
            if (fixture.has("minConfidence")) {
                val min = fixture.getDouble("minConfidence")
                assertTrue(
                    "golden '$name' confidence >= $min",
                    result.confidence >= min,
                )
            }
            if (fixture.has("expectedSignal")) {
                val expectedSignal = fixture.getString("expectedSignal")
                assertTrue(
                    "golden '$name' signal $expectedSignal",
                    result.contributingSignals.contains(expectedSignal),
                )
            }
        }
    }

    private fun loadGoldens(): JSONArray {
        val root = File(System.getProperty("user.dir"))
        val candidates =
            listOf(
                root.resolve("tests/fixtures/classifier-goldens.json"),
                root.resolve("../../tests/fixtures/classifier-goldens.json"),
                root.resolve("../../../tests/fixtures/classifier-goldens.json"),
            )
        val file = candidates.firstOrNull { it.isFile }
            ?: error("classifier-goldens.json not found from user.dir=$root")
        return JSONArray(file.readText())
    }

    private fun parseSignals(el: JSONObject): ClassifierSignals {
        val exts =
            if (el.has("fileExtensions")) {
                val arr = el.getJSONArray("fileExtensions")
                List(arr.length()) { arr.getString(it) }
            } else {
                emptyList()
            }
        val keywords =
            if (el.has("keywords")) {
                val arr = el.getJSONArray("keywords")
                List(arr.length()) { arr.getString(it) }
            } else {
                emptyList()
            }
        return ClassifierSignals(
            fileExtensions = exts,
            model = el.optString("model", null),
            appSurface = el.optString("appSurface", null),
            hasCodeExecution = el.optBoolean("hasCodeExecution", false),
            hasErrorOutput = el.optBoolean("hasErrorOutput", false),
            hasSearchResults = el.optBoolean("hasSearchResults", false),
            hasMultiStepPlanning = el.optBoolean("hasMultiStepPlanning", false),
            keywords = keywords,
        )
    }

    private fun parseCorrections(arr: JSONArray): List<PurposeCorrection> {
        return List(arr.length()) { i ->
            val row = arr.getJSONObject(i)
            val corrected =
                ModelPurposeCategory.valueOf(row.getString("correctedTo").uppercase())
            PurposeCorrection(
                fingerprint = row.getString("fingerprint"),
                correctedTo = corrected,
            )
        }
    }
}
