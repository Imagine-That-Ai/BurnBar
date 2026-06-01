@file:Suppress("MagicNumber")
// detekt: test fixtures use literal wire-format / timeout values.

package com.openburnbar

import com.openburnbar.data.hermes.CliModelSource
import com.openburnbar.data.hermes.CliRuntimeModelCatalogResponse
import org.junit.Assert.assertEquals
import org.junit.Test

class CLIRuntimeModelCatalogTest {
    @Test
    fun cliRuntimeModelCatalogResponseDecodesSwiftWireShape() {
        val response = CliRuntimeModelCatalogResponse.decode(swiftWireShapeJson())

        assertEquals("droid", response.runtime)
        assertEquals("Alberto Mac", response.machineName)
        assertEquals(42L, response.generatedAtEpochMillis)
        assertEquals(CliModelSource.OPENBURNBAR_PROXY, response.options[0].source)
        assertEquals(CliModelSource.DROID_CORE_QUOTA, response.options[1].source)
        assertEquals(CliModelSource.ANTIGRAVITY_MODEL_CATALOG, response.options[2].source)
        assertEquals(CliModelSource.CLAUDE_MODEL_CATALOG, response.options[3].source)
        assertEquals(CliModelSource.CODEX_MODEL_CATALOG, response.options[4].source)
        assertEquals(CliModelSource.GROK_MODEL_CATALOG, response.options[5].source)
        assertEquals("Claude Opus 4.7 · Anthropic · via OpenBurnBar · Reasoning: default", response.options[0].displayName)
        assertEquals("Anthropic via OpenBurnBar API/OAuth", response.options[0].providerName)
    }

    private fun swiftWireShapeJson(): String = """
        {
          "runtime": "droid",
          "machineName": "Alberto Mac",
          "generatedAtEpochMillis": 42,
          "options": [
            {
              "modelID": "custom:OpenBurnBar-claude-opus-4-7-1",
              "displayName": "Claude Opus 4.7 · Anthropic · via OpenBurnBar · Reasoning: default",
              "providerID": "anthropic",
              "providerName": "Anthropic via OpenBurnBar API/OAuth",
              "tier": "flagship",
              "source": "openBurnBarProxy"
            },
            {
              "modelID": "glm-5.1",
              "displayName": "Droid Core (GLM-5.1) · Factory Droid Core · via OpenBurnBar · Reasoning: CLI default",
              "providerID": "factory",
              "providerName": "Factory Droid Core quota",
              "tier": "mid",
              "source": "droidCoreQuota"
            },
            {
              "modelID": "gemini-3.1-pro-preview",
              "displayName": "Gemini 3.1 Pro Preview · Google · via OpenBurnBar · Reasoning: CLI default",
              "providerID": "google",
              "providerName": "Google via Antigravity CLI",
              "tier": "flagship",
              "source": "antigravityModelCatalog"
            },
            {
              "modelID": "claude-opus-4-8",
              "displayName": "Claude Opus 4.8 · Anthropic · via OpenBurnBar · Reasoning: CLI default",
              "providerID": "anthropic",
              "providerName": "Anthropic via Claude Code CLI",
              "tier": "flagship",
              "source": "claudeModelCatalog"
            },
            {
              "modelID": "gpt-5.5",
              "displayName": "GPT-5.5 · OpenAI · via OpenBurnBar · Reasoning: medium",
              "providerID": "openai",
              "providerName": "OpenAI via Codex CLI",
              "tier": "flagship",
              "source": "codexModelCatalog"
            },
            {
              "modelID": "grok-build",
              "displayName": "grok-build · xAI · via OpenBurnBar · Reasoning: CLI default",
              "providerID": "xai",
              "providerName": "xAI via Grok Build CLI",
              "tier": "mid",
              "source": "grokModelCatalog"
            }
          ]
        }
    """.trimIndent()
}
