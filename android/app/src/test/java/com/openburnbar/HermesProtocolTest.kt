package com.openburnbar

import com.openburnbar.data.hermes.HermesProtocol
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-Kotlin tests for the wire helpers shared by [HermesService] and the
 * Hermes settings dialog. No Android SDK calls — these run under the standard
 * JVM test runner.
 */
class HermesProtocolTest {

    // ── normalizeBaseURL ─────────────────────────────────────────────

    @Test
    fun `normalizeBaseURL wraps bare host as http`() {
        assertEquals("http://localhost:8642", HermesProtocol.normalizeBaseURL("localhost:8642"))
        assertEquals("http://127.0.0.1:8642", HermesProtocol.normalizeBaseURL("127.0.0.1:8642"))
    }

    @Test
    fun `normalizeBaseURL strips trailing API paths`() {
        assertEquals(
            "http://localhost:8642",
            HermesProtocol.normalizeBaseURL("http://localhost:8642/v1/chat/completions")
        )
        assertEquals(
            "https://hermes.example.com",
            HermesProtocol.normalizeBaseURL("https://hermes.example.com/v1/models")
        )
        assertEquals(
            "http://localhost:8642",
            HermesProtocol.normalizeBaseURL("http://localhost:8642/health/")
        )
    }

    @Test
    fun `normalizeBaseURL coerces ws and wss to http variants`() {
        assertEquals("http://localhost:8642", HermesProtocol.normalizeBaseURL("ws://localhost:8642"))
        assertEquals(
            "https://hermes.example.com",
            HermesProtocol.normalizeBaseURL("wss://hermes.example.com")
        )
    }

    @Test
    fun `normalizeBaseURL returns null for blank input`() {
        assertNull(HermesProtocol.normalizeBaseURL(""))
        assertNull(HermesProtocol.normalizeBaseURL("   "))
        assertNull(HermesProtocol.normalizeBaseURL(null))
    }

    // ── validatedBaseURL ─────────────────────────────────────────────

    @Test
    fun `validatedBaseURL accepts localhost over http`() {
        assertNotNull(HermesProtocol.validatedBaseURL("http://localhost:8642"))
        assertNotNull(HermesProtocol.validatedBaseURL("http://127.0.0.1:8642"))
    }

    @Test
    fun `validatedBaseURL accepts RFC1918 private lan over http`() {
        assertNotNull(HermesProtocol.validatedBaseURL("http://10.0.0.5:8642"))
        assertNotNull(HermesProtocol.validatedBaseURL("http://172.16.0.10:8642"))
        assertNotNull(HermesProtocol.validatedBaseURL("http://192.168.1.42:8642"))
    }

    @Test
    fun `validatedBaseURL rejects plain http to public host`() {
        assertNull(HermesProtocol.validatedBaseURL("http://hermes.example.com"))
        assertNull(HermesProtocol.validatedBaseURL("http://8.8.8.8:8642"))
    }

    @Test
    fun `validatedBaseURL accepts https for any host`() {
        assertNotNull(HermesProtocol.validatedBaseURL("https://hermes.example.com"))
        assertNotNull(HermesProtocol.validatedBaseURL("https://localhost:8642"))
    }

    // ── isLocalOrPrivateHost ────────────────────────────────────────

    @Test
    fun `isLocalOrPrivateHost recognizes loopback`() {
        assertTrue(HermesProtocol.isLocalOrPrivateHost("localhost"))
        assertTrue(HermesProtocol.isLocalOrPrivateHost("127.0.0.1"))
        assertTrue(HermesProtocol.isLocalOrPrivateHost("::1"))
    }

    @Test
    fun `isLocalOrPrivateHost recognizes private lans`() {
        assertTrue(HermesProtocol.isLocalOrPrivateHost("10.0.0.5"))
        assertTrue(HermesProtocol.isLocalOrPrivateHost("172.16.0.1"))
        assertTrue(HermesProtocol.isLocalOrPrivateHost("172.31.255.255"))
        assertTrue(HermesProtocol.isLocalOrPrivateHost("192.168.10.20"))
    }

    @Test
    fun `isLocalOrPrivateHost rejects public addresses and hostnames`() {
        assertFalse(HermesProtocol.isLocalOrPrivateHost("8.8.8.8"))
        assertFalse(HermesProtocol.isLocalOrPrivateHost("172.32.0.1"))
        assertFalse(HermesProtocol.isLocalOrPrivateHost("example.com"))
        assertFalse(HermesProtocol.isLocalOrPrivateHost(""))
    }

    // ── extractStreamedText ─────────────────────────────────────────

    @Test
    fun `extractStreamedText reads delta content string`() {
        val json = JSONObject(
            """
            {
              "choices": [
                { "delta": { "content": "Hello world" } }
              ]
            }
            """.trimIndent()
        )
        assertEquals("Hello world", HermesProtocol.extractStreamedText(json))
    }

    @Test
    fun `extractStreamedText reads delta content array of objects`() {
        val json = JSONObject(
            """
            {
              "choices": [
                { "delta": { "content": [
                  { "type": "text", "text": "Hello, " },
                  { "type": "text", "text": "Hermes" }
                ] } }
              ]
            }
            """.trimIndent()
        )
        assertEquals("Hello, Hermes", HermesProtocol.extractStreamedText(json))
    }

    @Test
    fun `extractStreamedText falls back to choice text`() {
        val json = JSONObject(
            """
            {
              "choices": [
                { "text": "raw text fallback" }
              ]
            }
            """.trimIndent()
        )
        assertEquals("raw text fallback", HermesProtocol.extractStreamedText(json))
    }

    @Test
    fun `extractStreamedText falls back to top-level output_text`() {
        val json = JSONObject("""{ "output_text": "completion text" }""")
        assertEquals("completion text", HermesProtocol.extractStreamedText(json))
    }

    @Test
    fun `extractStreamedText returns empty for empty chunks`() {
        val json = JSONObject("""{ "choices": [ { "delta": {} } ] }""")
        assertEquals("", HermesProtocol.extractStreamedText(json))
    }

    @Test
    fun `extractContentValue tolerates value alias`() {
        val obj = JSONObject("""{ "value": "alias" }""")
        assertEquals("alias", HermesProtocol.extractContentValue(obj))
    }

    // ── parseModelsResponse ─────────────────────────────────────────

    @Test
    fun `parseModelsResponse parses standard OpenAI list shape`() {
        val raw = """
            {
              "data": [
                { "id": "hermes", "owned_by": "hermes", "display_name": "Hermes" },
                { "id": "gpt-4o-mini", "owned_by": "openai" }
              ]
            }
        """.trimIndent()
        val models = HermesProtocol.parseModelsResponse(raw)
        assertEquals(2, models.size)
        assertEquals("hermes", models[0].modelID)
        assertEquals("Hermes", models[0].providerName)
        assertEquals("gpt-4o-mini", models[1].modelID)
        assertEquals("Openai", models[1].providerName)
    }

    @Test
    fun `parseModelsResponse skips entries without an id`() {
        val raw = """{ "data": [ { "owned_by": "lonely" }, { "id": "ok" } ] }"""
        val models = HermesProtocol.parseModelsResponse(raw)
        assertEquals(1, models.size)
        assertEquals("ok", models[0].modelID)
    }

    @Test
    fun `parseModelsResponse returns empty for blank or malformed body`() {
        assertTrue(HermesProtocol.parseModelsResponse(null).isEmpty())
        assertTrue(HermesProtocol.parseModelsResponse("").isEmpty())
        assertTrue(HermesProtocol.parseModelsResponse("not-json").isEmpty())
        assertTrue(HermesProtocol.parseModelsResponse("""{"data": "not-an-array"}""").isEmpty())
    }
}
