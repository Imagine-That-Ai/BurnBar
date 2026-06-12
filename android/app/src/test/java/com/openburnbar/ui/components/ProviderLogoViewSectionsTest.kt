
package com.openburnbar.ui.components

import com.openburnbar.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Token-key → logo resolution tests for `ProviderLogoViewSections`: each
 * family resolver matches its own brands only, and [drawableForModelTokenKey]
 * applies them in precedence order with the Hermes glyph as the final
 * fallback. Keys arrive pre-lowercased from the token surface.
 */
class ProviderLogoViewSectionsTest {
    @Test
    fun `built in runtimes win over embedded foundation model names`() {
        // "droid" outranks the "claude" substring — a Droid session powered by
        // a Claude model must keep the Droid logo.
        assertEquals(R.drawable.factory_logo, drawableForModelTokenKey("factory-droid-claude-opus"))
        assertEquals(R.drawable.logo_openclaw, drawableForModelTokenKey("open_claw-session"))
        assertEquals(R.drawable.logo_forge, drawableForModelTokenKey("forgedev-gpt-5"))
        assertEquals(R.drawable.logo_antigravity, drawableForModelTokenKey("google-antigravity"))
    }

    @Test
    fun `pi and hermes runtimes match exact and path forms only`() {
        assertEquals(R.drawable.pi_runtime_glyph, piHermesRuntimeDrawable("pi"))
        assertEquals(R.drawable.pi_runtime_glyph, piHermesRuntimeDrawable("pi-2"))
        assertEquals(R.drawable.pi_runtime_glyph, piHermesRuntimeDrawable("inflection/pi"))
        assertEquals(R.drawable.logo_hermes, piHermesRuntimeDrawable("hermes"))
        assertEquals(R.drawable.logo_hermes, piHermesRuntimeDrawable("nous/hermes"))
        // Substring matches must NOT fire: "pi" inside another word is not Pi.
        assertNull(piHermesRuntimeDrawable("api-gateway"))
        assertNull(piHermesRuntimeDrawable("spike"))
        assertNull(piHermesRuntimeDrawable("hermes-3-llama")) // not an exact/path hermes key
    }

    @Test
    fun `anthropic openai family resolves claude gpt and codex`() {
        assertEquals(R.drawable.logo_anthropic, anthropicOpenAiModelDrawable("claude-sonnet-4-5"))
        assertEquals(R.drawable.logo_anthropic, anthropicOpenAiModelDrawable("anthropic/opus"))
        assertEquals(R.drawable.logo_open_ai, anthropicOpenAiModelDrawable("gpt-4o-mini"))
        assertEquals(R.drawable.logo_open_ai, anthropicOpenAiModelDrawable("openai/o3"))
        assertEquals(R.drawable.logo_codex, anthropicOpenAiModelDrawable("codex-mini"))
        assertNull(anthropicOpenAiModelDrawable("gemini-pro"))
    }

    @Test
    fun `asian provider family covers each brand alias`() {
        assertEquals(R.drawable.logo_deep_seek, asianProviderModelDrawable("deepseek-v3"))
        assertEquals(R.drawable.kimi_logo, asianProviderModelDrawable("moonshot-v1"))
        assertEquals(R.drawable.logo_mini_max, asianProviderModelDrawable("abab6.5"))
        assertEquals(R.drawable.logo_qwen, asianProviderModelDrawable("qwq-32b"))
        assertEquals(R.drawable.logo_zai, asianProviderModelDrawable("glm-4.6"))
        assertEquals(R.drawable.logo_alibaba, asianProviderModelDrawable("tongyi-wanx"))
        assertNull(asianProviderModelDrawable("mistral-large"))
    }

    @Test
    fun `western provider family covers each brand alias`() {
        assertEquals(R.drawable.logo_meta, westernProviderModelDrawable("llama-3.3-70b"))
        assertEquals(R.drawable.logo_mistral, westernProviderModelDrawable("mixtral-8x22b"))
        assertEquals(R.drawable.logo_grok, westernProviderModelDrawable("xai/grok-4"))
        assertEquals(R.drawable.logo_cohere, westernProviderModelDrawable("command-r-plus"))
        assertEquals(R.drawable.logo_perplexity, westernProviderModelDrawable("sonar-reasoning"))
        assertNull(westernProviderModelDrawable("nova-pro"))
    }

    @Test
    fun `cloud and local family covers apple amazon and ollama`() {
        assertEquals(R.drawable.logo_apple, cloudAndLocalModelDrawable("mlx-community-model"))
        assertEquals(R.drawable.logo_amazon, cloudAndLocalModelDrawable("bedrock/nova-lite"))
        assertEquals(R.drawable.logo_ollama, cloudAndLocalModelDrawable("ollama/llama3"))
        assertNull(cloudAndLocalModelDrawable("claude-haiku"))
    }

    @Test
    fun `google family resolves gemini and google keys`() {
        assertEquals(R.drawable.google_logo, googleModelDrawable("gemini-2.5-pro"))
        assertEquals(R.drawable.google_logo, googleModelDrawable("google/text-bison"))
        assertNull(googleModelDrawable("grok-4"))
    }

    @Test
    fun `precedence runs family by family before the hermes fallback`() {
        // Google outranks the western family for a combined key…
        assertEquals(R.drawable.google_logo, drawableForModelTokenKey("google-llama-hosted"))
        // …and the asian family outranks the western family.
        assertEquals(R.drawable.logo_qwen, drawableForModelTokenKey("qwen-grok-mix"))
        // Unmatched keys land on the Hermes glyph, never null.
        assertEquals(R.drawable.logo_hermes, drawableForModelTokenKey("totally-unknown-model"))
        assertEquals(R.drawable.logo_hermes, drawableForModelTokenKey(""))
    }
}
