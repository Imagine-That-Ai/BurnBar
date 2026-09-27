package com.openburnbar.data.settings

import com.openburnbar.data.models.AgentProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Gate-parity tests for [SettingsGatePolicies]: the `SettingsManager`
 * cluster's portable core (backend/model identity, CSV codecs, model
 * resolution, the lossless string-list JSON codec, summary order + clamps)
 * proven against the Swift contract in `AgentLens/`.
 */
class SettingsGatePoliciesTest {
    @Test
    fun `chat backend allCases match the Swift order`() {
        assertEquals(
            listOf(
                ChatBackendId.CODEX,
                ChatBackendId.CLAUDE,
                ChatBackendId.HERMES,
                ChatBackendId.PI_AGENT,
                ChatBackendId.OPENCLAW,
                ChatBackendId.OPEN_CLAUDE,
                ChatBackendId.OMP,
                ChatBackendId.DROID,
                ChatBackendId.FORGE,
                ChatBackendId.ANTIGRAVITY,
                ChatBackendId.CURSOR_AGENT,
                ChatBackendId.JUNIE,
                ChatBackendId.FX,
                ChatBackendId.GROK,
                ChatBackendId.KIMI,
            ),
            ChatBackendId.allCases,
        )
    }

    @Test
    fun `chat backend raw values match Swift`() {
        val expected =
            mapOf(
                ChatBackendId.CODEX to "codex",
                ChatBackendId.CLAUDE to "claude",
                ChatBackendId.HERMES to "hermes",
                ChatBackendId.OPENCLAW to "openclaw",
                ChatBackendId.OPEN_CLAUDE to "openclaude",
                ChatBackendId.OMP to "omp",
                ChatBackendId.PI_AGENT to "piAgent",
                ChatBackendId.DROID to "droid",
                ChatBackendId.FORGE to "forge",
                ChatBackendId.ANTIGRAVITY to "antigravity",
                ChatBackendId.CURSOR_AGENT to "cursorAgent",
                ChatBackendId.JUNIE to "junie",
                ChatBackendId.FX to "fx",
                ChatBackendId.GROK to "grok",
                ChatBackendId.KIMI to "kimi",
            )
        for ((backend, raw) in expected) {
            assertEquals(raw, backend.rawValue)
            assertEquals(backend, ChatBackendId.fromRawValueOrNull(raw))
        }
        assertNull(ChatBackendId.fromRawValueOrNull("not-a-backend"))
        assertNull(ChatBackendId.fromRawValueOrNull("Codex"))
    }

    @Test
    fun `new chat backends carry Swift display metadata`() {
        assertEquals("Junie", ChatBackendId.JUNIE.displayName)
        assertEquals("fx", ChatBackendId.FX.displayName)
        assertEquals("Grok", ChatBackendId.GROK.displayName)
        assertEquals("Kimi", ChatBackendId.KIMI.displayName)
        assertEquals("✽", ChatBackendId.JUNIE.glyph)
        assertEquals("ƒ", ChatBackendId.FX.glyph)
        assertEquals("⚡", ChatBackendId.GROK.glyph)
        assertEquals("☾", ChatBackendId.KIMI.glyph)
        assertEquals(AgentProvider.JUNIE, ChatBackendId.JUNIE.agentProvider)
        assertEquals(AgentProvider.FX, ChatBackendId.FX.agentProvider)
        assertEquals(AgentProvider.XAI, ChatBackendId.GROK.agentProvider)
        assertEquals(AgentProvider.KIMI, ChatBackendId.KIMI.agentProvider)
        assertEquals("Cursor Agent", ChatBackendId.CURSOR_AGENT.displayName)
        assertEquals(AgentProvider.CURSOR_AGENT, ChatBackendId.CURSOR_AGENT.agentProvider)
    }

    @Test
    fun `cli consent flags match Swift`() {
        assertFalse(ChatBackendId.HERMES.requiresCliAssistantConsent)
        assertFalse(ChatBackendId.OPENCLAW.requiresCliAssistantConsent)
        assertFalse(ChatBackendId.PI_AGENT.requiresCliAssistantConsent)
        assertTrue(ChatBackendId.CODEX.requiresCliAssistantConsent)
        assertTrue(ChatBackendId.OPEN_CLAUDE.requiresCliAssistantConsent)
        assertTrue(ChatBackendId.OMP.requiresCliAssistantConsent)
        assertTrue(ChatBackendId.JUNIE.requiresCliAssistantConsent)
        assertTrue(ChatBackendId.FX.requiresCliAssistantConsent)
        assertTrue(ChatBackendId.GROK.requiresCliAssistantConsent)
        assertTrue(ChatBackendId.KIMI.requiresCliAssistantConsent)
    }

    @Test
    fun `enabled backend lists round trip and drop unknown tokens`() {
        val backends = listOf(ChatBackendId.CODEX, ChatBackendId.HERMES, ChatBackendId.KIMI)
        assertEquals(backends, ChatBackendId.decodeEnabledList(ChatBackendId.encodeEnabledList(backends)))
        assertEquals("", ChatBackendId.encodeEnabledList(emptyList()))
        assertEquals(emptyList<ChatBackendId>(), ChatBackendId.decodeEnabledList(""))
        assertEquals(
            listOf(ChatBackendId.CODEX, ChatBackendId.GROK),
            ChatBackendId.decodeEnabledList(" codex ,,nope, grok "),
        )
    }

    @Test
    fun `hermes model defaults and codecs match Swift`() {
        assertEquals(
            listOf(HermesModelId.CODEX, HermesModelId.CLAUDE, HermesModelId.OLLAMA),
            HermesModelId.defaultEnabled,
        )
        assertEquals("Z.ai", HermesModelId.ZAI.displayName)
        assertEquals("Z.ai", HermesModelId.ZAI.shortLabel)
        assertEquals("zai", HermesModelId.ZAI.hermesModelOverride)
        assertEquals(AgentProvider.OLLAMA, HermesModelId.OLLAMA.agentProvider)
        val models = listOf(HermesModelId.KIMI, HermesModelId.MINIMAX)
        assertEquals(models, HermesModelId.decodeEnabledList(HermesModelId.encodeEnabledList(models)))
        assertEquals(
            listOf(HermesModelId.CODEX),
            HermesModelId.decodeEnabledList("codex,unknown"),
        )
    }

    @Test
    fun `enabling and disabling backends is deduped and order stable`() {
        val start = listOf(ChatBackendId.CODEX, ChatBackendId.HERMES)
        assertEquals(
            listOf(ChatBackendId.CODEX, ChatBackendId.HERMES, ChatBackendId.GROK),
            SettingsEnabledListPolicies.withChatBackendEnabled(start, ChatBackendId.GROK, true),
        )
        assertEquals(
            start,
            SettingsEnabledListPolicies.withChatBackendEnabled(start, ChatBackendId.CODEX, true),
        )
        assertEquals(
            listOf(ChatBackendId.HERMES),
            SettingsEnabledListPolicies.withChatBackendEnabled(start, ChatBackendId.CODEX, false),
        )
        assertEquals(
            start,
            SettingsEnabledListPolicies.withChatBackendEnabled(start, ChatBackendId.KIMI, false),
        )
    }

    @Test
    fun `empty hermes model csv resolves to the default triple`() {
        assertEquals(
            HermesModelId.defaultEnabled,
            SettingsEnabledListPolicies.enabledHermesModelsOrDefault(""),
        )
        assertEquals(
            listOf(HermesModelId.ZAI),
            SettingsEnabledListPolicies.enabledHermesModelsOrDefault("zai"),
        )
    }

    @Test
    fun `legacy single backend upgrades to a one element csv`() {
        assertEquals(
            "codex,hermes",
            SettingsEnabledListPolicies.migrateChatBackendCsv("codex,hermes", "grok"),
        )
        assertEquals(
            "grok",
            SettingsEnabledListPolicies.migrateChatBackendCsv(null, "grok"),
        )
        assertEquals(
            "",
            SettingsEnabledListPolicies.migrateChatBackendCsv(null, "nope"),
        )
        assertEquals(
            "",
            SettingsEnabledListPolicies.migrateChatBackendCsv(null, null),
        )
    }

    @Test
    fun `hermes model selection mirrors into the override`() {
        assertEquals(
            "ollama",
            SettingsEnabledListPolicies.hermesModelOverrideForSelection(HermesModelId.OLLAMA),
        )
        assertEquals("", SettingsEnabledListPolicies.hermesModelOverrideForSelection(null))
    }

    @Test
    fun `hermes chat model resolution follows the override chain`() {
        assertEquals(
            "custom",
            ChatModelResolution.resolvedHermesChatModel("  custom ", "advertised"),
        )
        assertEquals(
            "advertised",
            ChatModelResolution.resolvedHermesChatModel("  ", " advertised "),
        )
        assertEquals("hermes", ChatModelResolution.resolvedHermesChatModel("", null))
        assertEquals("hermes", ChatModelResolution.resolvedHermesChatModel("  ", "   "))
        assertEquals("hermes", ChatModelResolution.resolvedHermesChatModel("", ""))
    }

    @Test
    fun `pi chat model resolution follows the override chain`() {
        assertEquals("custom", ChatModelResolution.resolvedPiChatModel("custom", null))
        assertEquals("advertised", ChatModelResolution.resolvedPiChatModel("", "advertised"))
        assertEquals("pi", ChatModelResolution.resolvedPiChatModel("", null))
        assertEquals("pi", ChatModelResolution.resolvedPiChatModel(" ", " "))
    }

    @Test
    fun `json string arrays decode leniently and fail to empty`() {
        assertEquals(listOf("a", "b"), SettingsJsonArray.decode("""["a","b"]"""))
        assertEquals(listOf("a", "b"), SettingsJsonArray.decode("""[" a ","","b"]"""))
        assertEquals(emptyList<String>(), SettingsJsonArray.decode("not json"))
        assertEquals(emptyList<String>(), SettingsJsonArray.decode("""{"a":1}"""))
        assertEquals(emptyList<String>(), SettingsJsonArray.decode("""["a",1]"""))
        assertEquals(emptyList<String>(), SettingsJsonArray.decode("""[null]"""))
        assertEquals(emptyList<String>(), SettingsJsonArray.decode("[]"))
    }

    @Test
    fun `json string arrays encode normalized and round trip`() {
        assertEquals("""["a","b"]""", SettingsJsonArray.encode(listOf(" a ", "", "b")))
        assertEquals("[]", SettingsJsonArray.encode(emptyList()))
        val values = listOf("plain", "quo\"te", "back\\slash", "uni→é")
        assertEquals(values, SettingsJsonArray.decode(SettingsJsonArray.encode(values)))
    }

    @Test
    fun `manual serializer matches the Swift byte shape`() {
        assertEquals(
            "[\"a\\/b\\\"c\\\\d\\n\"]",
            SettingsJsonArray.manuallySerialize(listOf("a/b\"c\\d\n")),
        )
        assertEquals(
            "[\"\\b\\f\\n\\r\\t\\u0001\"]",
            SettingsJsonArray.manuallySerialize(listOf("\b\n\r\t\u0001")),
        )
        assertEquals("[\"→é\"]", SettingsJsonArray.manuallySerialize(listOf("→é")))
        // The fallback output must survive the lenient decoder.
        val tricky = listOf("a/b", "q\"q", "c\\c", "line\nbreak", "tab\there", "snowman☃")
        assertEquals(tricky, SettingsJsonArray.decode(SettingsJsonArray.manuallySerialize(tricky)))
    }

    @Test
    fun `summary provider order parses dedupes and completes`() {
        assertEquals(SummaryProviderOrder.DEFAULT_ORDER, SummaryProviderOrder.parse(SummaryProviderOrder.DEFAULT_CSV))
        assertEquals(SummaryProviderOrder.DEFAULT_ORDER, SummaryProviderOrder.parse(""))
        assertEquals(SummaryProviderOrder.DEFAULT_ORDER, SummaryProviderOrder.parse("nope,unknown"))
        assertEquals(
            listOf(
                SummaryProviderId.OLLAMA,
                SummaryProviderId.LOCAL,
                SummaryProviderId.MLX,
                SummaryProviderId.MINIMAX,
                SummaryProviderId.OPENROUTER,
                SummaryProviderId.ZAI,
            ),
            SummaryProviderOrder.parse(" ollama ,OLLAMA,zzz"),
        )
        assertEquals(
            "ollama,local,mlx,minimax,openrouter,zai",
            SummaryProviderOrder.encode(SummaryProviderOrder.parse("ollama")),
        )
    }

    @Test
    fun `summary sanitize clamps match Swift init rules`() {
        assertEquals(60_000, SummarySettingsDefaults.sanitizeMaxPromptChars(null))
        assertEquals(60_000, SummarySettingsDefaults.sanitizeMaxPromptChars(3_999))
        assertEquals(4_000, SummarySettingsDefaults.sanitizeMaxPromptChars(4_000))
        assertEquals(280, SummarySettingsDefaults.sanitizeMaxOutputTokens(null))
        assertEquals(280, SummarySettingsDefaults.sanitizeMaxOutputTokens(119))
        assertEquals(120, SummarySettingsDefaults.sanitizeMaxOutputTokens(120))
        assertEquals(1, SummarySettingsDefaults.sanitizeRetryCount(null))
        assertEquals(0, SummarySettingsDefaults.sanitizeRetryCount(-3))
        assertEquals(25, SummarySettingsDefaults.sanitizeBatchSize(null))
        assertEquals(1, SummarySettingsDefaults.sanitizeBatchSize(0))
        assertEquals(120, SummarySettingsDefaults.sanitizeFirstLoadBatchSize(null))
        assertEquals(1, SummarySettingsDefaults.sanitizeFirstLoadBatchSize(-1))
        assertEquals(20.0, SummarySettingsDefaults.sanitizeRequestTimeoutSeconds(null), 0.0)
        assertEquals(20.0, SummarySettingsDefaults.sanitizeRequestTimeoutSeconds(0.0), 0.0)
        assertEquals(20.0, SummarySettingsDefaults.sanitizeRequestTimeoutSeconds(-2.0), 0.0)
        assertEquals(8, SummarySettingsDefaults.sanitizeMaxConcurrency(null))
        assertEquals(1, SummarySettingsDefaults.sanitizeMaxConcurrency(0))
        assertEquals(0, SummarySettingsDefaults.sanitizeTimeLimitMinutes(null))
        assertEquals(0, SummarySettingsDefaults.sanitizeTimeLimitMinutes(-5))
    }

    @Test
    fun `gateway and summary defaults match Swift`() {
        assertEquals("http://127.0.0.1:18789", ChatBackendDefaults.OPENCLAW_GATEWAY_BASE_URL)
        assertEquals("http://127.0.0.1:8642", ChatBackendDefaults.HERMES_GATEWAY_BASE_URL)
        assertEquals("http://127.0.0.1:8765", ChatBackendDefaults.PI_AGENT_GATEWAY_BASE_URL)
        assertEquals("", ChatBackendDefaults.REALTIME_RELAY_URL)
        assertTrue(ChatBackendDefaults.COMPUTER_USE_KILL_SWITCH)
        assertTrue(ChatBackendDefaults.MEDIA_KILL_SWITCH)
        assertTrue(ChatBackendDefaults.WAR_ROOM_KILL_SWITCH)
        assertEquals("qwen/qwen3.5-9b", SummarySettingsDefaults.OPENROUTER_PRIMARY_MODEL)
        assertEquals("openai/gpt-5-nano", SummarySettingsDefaults.OPENROUTER_FALLBACK_MODEL)
        assertEquals("mlx-community/Qwen3-4B-4bit", SummarySettingsDefaults.MLX_MODEL)
    }
}
