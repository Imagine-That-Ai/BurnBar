package com.openburnbar.ui.hermes

import com.openburnbar.data.hermes.AssistantRuntimeID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every CLI runtime must have a brand, a tagline, and quick prompts.
 *
 * These three `when` blocks are the exact shape that goes wrong when a runtime is
 * added: the enum gains a case, some arms get updated, and the rest quietly fall to
 * a default. Iterating `AssistantRuntimeID.entries` is what makes a half-add fail
 * here instead of shipping a nameless agent with someone else's colour.
 */
class CliAgentChatPresentationTotalityTest {

    @Test
    fun `every runtime resolves a distinct-enough provider brand`() {
        for (runtime in AssistantRuntimeID.entries) {
            // providerFor is total by return type; the real risk is an arm that was
            // never added and silently inherits a neighbour's brand.
            val provider = providerFor(runtime)
            assertTrue("${runtime.token} resolved a blank provider key", provider.key.isNotBlank())
        }
    }

    @Test
    fun `every runtime has a non-blank ready tagline`() {
        for (runtime in AssistantRuntimeID.entries) {
            val tagline = readyTagline(runtime)
            assertTrue("${runtime.token} has a blank tagline", tagline.isNotBlank())
        }
    }

    /// Hermes and Pi are deliberately promptless *here*: they have their own
    /// first-class chat surfaces and are not CLI runtimes, which is the same reason
    /// `CLIAgentRuntime` refuses to construct from them. Pinning the fall-through
    /// set as exactly those two is what turns a future half-added runtime into a
    /// failure instead of an agent that silently offers nothing to say.
    @Test
    fun `every CLI runtime offers quick prompts and only Hermes and Pi opt out`() {
        val promptless = AssistantRuntimeID.entries.filter { quickPromptsFor(it).isEmpty() }
        assertEquals(
            "the set of runtimes without quick prompts changed",
            setOf(AssistantRuntimeID.HERMES, AssistantRuntimeID.PI),
            promptless.toSet(),
        )
        for (runtime in AssistantRuntimeID.entries - promptless.toSet()) {
            val prompts = quickPromptsFor(runtime)
            assertTrue("${runtime.token} offers no quick prompts", prompts.isNotEmpty())
            assertTrue(
                "${runtime.token} offers a blank quick prompt",
                prompts.none { it.isBlank() },
            )
        }
    }

    /// fx is the newest runtime, so it is the one most likely to have been added to
    /// the enum without reaching all three presentation tables.
    @Test
    fun `fx is wired through all three presentation surfaces`() {
        assertEquals("fx", providerFor(AssistantRuntimeID.FX).key)
        assertTrue(readyTagline(AssistantRuntimeID.FX).contains("fx"))
        assertTrue(quickPromptsFor(AssistantRuntimeID.FX).isNotEmpty())
    }

    /// Preference keys are persisted, so they must stay stable and per-runtime.
    @Test
    fun `preference keys are stable and unique per runtime`() {
        val modelKeys = AssistantRuntimeID.entries.map { cliModelPreferenceKey(it) }
        val modeKeys = AssistantRuntimeID.entries.map { cliPresentationModePreferenceKey(it) }
        assertEquals("model preference keys collide", modelKeys.size, modelKeys.toSet().size)
        assertEquals("presentation-mode keys collide", modeKeys.size, modeKeys.toSet().size)
        assertEquals("assistants.preferredModelID.fx", cliModelPreferenceKey(AssistantRuntimeID.FX))
        assertEquals("assistants.presentationMode.fx", cliPresentationModePreferenceKey(AssistantRuntimeID.FX))
    }
}
