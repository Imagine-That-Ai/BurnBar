package com.openburnbar.ui.components

import com.openburnbar.data.models.AgentProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Gate-parity tests for [SwarmBackgroundPolicy]: every resolve() guard, the
 * visibility lattice, the decorative-effects gate, the environment truth
 * table, and the persisted-preferences codec — all proven against the Swift
 * contract in `OpenBurnBarMobile/Models/SwarmBackgroundPreferences.swift`.
 */
class SwarmBackgroundPolicyTest {
    private fun resolve(
        location: SwarmBackgroundLocation = SwarmBackgroundLocation.EVERYWHERE,
        conditionMet: Boolean = true,
        requestedVisibility: MobileBackgroundVisibility = MobileBackgroundVisibility.PROMINENT,
        scenePhaseActive: Boolean = true,
        isLowPowerModeEnabled: Boolean = false,
        reduceMotion: Boolean = false,
    ) = SwarmBackgroundPowerPolicy.resolve(
        location = location,
        conditionMet = conditionMet,
        requestedVisibility = requestedVisibility,
        scenePhaseActive = scenePhaseActive,
        isLowPowerModeEnabled = isLowPowerModeEnabled,
        reduceMotion = reduceMotion,
    )

    @Test
    fun `disabled location resolves to the disabled fallback`() {
        assertEquals(SwarmBackgroundRenderPlan.DISABLED_FALLBACK, resolve(location = SwarmBackgroundLocation.DISABLED))
    }

    @Test
    fun `disabled wins over every other live signal`() {
        val plan =
            resolve(
                location = SwarmBackgroundLocation.DISABLED,
                conditionMet = true,
                requestedVisibility = MobileBackgroundVisibility.PROMINENT,
                scenePhaseActive = true,
                isLowPowerModeEnabled = true,
                reduceMotion = true,
            )
        assertEquals(SwarmBackgroundRenderPlan.DISABLED_FALLBACK, plan)
    }

    @Test
    fun `unmet condition resolves to the static backdrop`() {
        assertEquals(SwarmBackgroundRenderPlan.STATIC_BACKDROP, resolve(conditionMet = false))
    }

    @Test
    fun `inactive scene resolves to the static backdrop`() {
        assertEquals(SwarmBackgroundRenderPlan.STATIC_BACKDROP, resolve(scenePhaseActive = false))
    }

    @Test
    fun `hidden visibility resolves to the static backdrop`() {
        assertEquals(
            SwarmBackgroundRenderPlan.STATIC_BACKDROP,
            resolve(requestedVisibility = MobileBackgroundVisibility.HIDDEN),
        )
    }

    @Test
    fun `reduce motion resolves to the static backdrop`() {
        assertEquals(SwarmBackgroundRenderPlan.STATIC_BACKDROP, resolve(reduceMotion = true))
    }

    @Test
    fun `obscured visibility resolves to the static backdrop`() {
        assertEquals(
            SwarmBackgroundRenderPlan.STATIC_BACKDROP,
            resolve(requestedVisibility = MobileBackgroundVisibility.OBSCURED),
        )
    }

    @Test
    fun `obscured beats low power mode`() {
        val plan =
            resolve(
                requestedVisibility = MobileBackgroundVisibility.OBSCURED,
                isLowPowerModeEnabled = true,
            )
        assertEquals(SwarmBackgroundRenderPlan.STATIC_BACKDROP, plan)
    }

    @Test
    fun `low power prominent throttles to subtle live`() {
        assertEquals(
            SwarmBackgroundRenderPlan.SUBTLE_LIVE,
            resolve(isLowPowerModeEnabled = true),
        )
    }

    @Test
    fun `low power subtle degrades to the static backdrop`() {
        val plan =
            resolve(
                requestedVisibility = MobileBackgroundVisibility.SUBTLE,
                isLowPowerModeEnabled = true,
            )
        assertEquals(SwarmBackgroundRenderPlan.STATIC_BACKDROP, plan)
    }

    @Test
    fun `prominent resolves to prominent live with exact plan values`() {
        val plan = resolve()
        assertEquals(SwarmRenderMode.LIVE, plan.mode)
        assertEquals(30.0, plan.maxFrameRate!!, 0.0)
        assertEquals(1.0, plan.particleScale, 0.0)
        assertEquals(1.0, plan.motionSpeedMultiplierScale, 0.0)
        assertTrue(plan.allowsAutoCycling)
        assertTrue(plan.allowsSparkles)
        assertFalse(plan.isBatteryThrottled)
    }

    @Test
    fun `subtle resolves to subtle live with exact plan values`() {
        val plan = resolve(requestedVisibility = MobileBackgroundVisibility.SUBTLE)
        assertEquals(SwarmRenderMode.LIVE, plan.mode)
        assertEquals(15.0, plan.maxFrameRate!!, 0.0)
        assertEquals(0.45, plan.particleScale, 0.0)
        assertEquals(0.55, plan.motionSpeedMultiplierScale, 0.0)
        assertFalse(plan.allowsAutoCycling)
        assertFalse(plan.allowsSparkles)
        assertTrue(plan.isBatteryThrottled)
    }

    @Test
    fun `static backdrop and disabled fallback carry no frame budget`() {
        assertNull(SwarmBackgroundRenderPlan.STATIC_BACKDROP.maxFrameRate)
        assertNull(SwarmBackgroundRenderPlan.DISABLED_FALLBACK.maxFrameRate)
        assertTrue(SwarmBackgroundRenderPlan.STATIC_BACKDROP.isBatteryThrottled)
        assertFalse(SwarmBackgroundRenderPlan.DISABLED_FALLBACK.isBatteryThrottled)
    }

    @Test
    fun `agents tab location gates like everywhere once conditions hold`() {
        assertEquals(
            SwarmBackgroundRenderPlan.PROMINENT_LIVE,
            resolve(location = SwarmBackgroundLocation.AGENTS_TAB),
        )
    }

    @Test
    fun `wire values match the Swift raw strings`() {
        assertEquals("Disabled", SwarmBackgroundLocation.DISABLED.wireValue)
        assertEquals("Agents Tab Only", SwarmBackgroundLocation.AGENTS_TAB.wireValue)
        assertEquals("Everywhere", SwarmBackgroundLocation.EVERYWHERE.wireValue)
        assertEquals("Always", SwarmBackgroundCondition.ALWAYS.wireValue)
        assertEquals("Power Connected Only", SwarmBackgroundCondition.POWER_CONNECTED.wireValue)
        assertEquals("Wi-Fi Only", SwarmBackgroundCondition.WIFI_ONLY.wireValue)
        assertEquals(null, SwarmBackgroundLocation.fromWireValueOrNull("disabled"))
        assertEquals(null, SwarmBackgroundCondition.fromWireValueOrNull("always"))
    }

    @Test
    fun `constrained keeps the more restrictive visibility`() {
        assertEquals(
            MobileBackgroundVisibility.SUBTLE,
            MobileBackgroundVisibility.PROMINENT.constrained(MobileBackgroundVisibility.SUBTLE),
        )
        assertEquals(
            MobileBackgroundVisibility.SUBTLE,
            MobileBackgroundVisibility.SUBTLE.constrained(MobileBackgroundVisibility.PROMINENT),
        )
        assertEquals(
            MobileBackgroundVisibility.OBSCURED,
            MobileBackgroundVisibility.SUBTLE.constrained(MobileBackgroundVisibility.OBSCURED),
        )
        assertEquals(
            MobileBackgroundVisibility.HIDDEN,
            MobileBackgroundVisibility.PROMINENT.constrained(MobileBackgroundVisibility.HIDDEN),
        )
        assertEquals(
            MobileBackgroundVisibility.HIDDEN,
            MobileBackgroundVisibility.HIDDEN.constrained(MobileBackgroundVisibility.PROMINENT),
        )
        // Ties resolve to the receiver.
        assertEquals(
            MobileBackgroundVisibility.SUBTLE,
            MobileBackgroundVisibility.SUBTLE.constrained(MobileBackgroundVisibility.SUBTLE),
        )
    }

    @Test
    fun `live effects require an active scene and a visible background`() {
        assertTrue(
            MobileDecorativeRenderPolicy.allowsLiveEffects(MobileBackgroundVisibility.PROMINENT, true),
        )
        assertTrue(
            MobileDecorativeRenderPolicy.allowsLiveEffects(MobileBackgroundVisibility.SUBTLE, true),
        )
        assertFalse(
            MobileDecorativeRenderPolicy.allowsLiveEffects(MobileBackgroundVisibility.OBSCURED, true),
        )
        assertFalse(
            MobileDecorativeRenderPolicy.allowsLiveEffects(MobileBackgroundVisibility.HIDDEN, true),
        )
        assertFalse(
            MobileDecorativeRenderPolicy.allowsLiveEffects(MobileBackgroundVisibility.PROMINENT, false),
        )
    }

    @Test
    fun `environment conditions follow the sensor truth table`() {
        assertTrue(
            SwarmEnvironmentConditionEvaluator.meetsCondition(
                SwarmBackgroundCondition.ALWAYS,
                isPowerConnected = false,
                isWifiConnected = false,
            ),
        )
        assertTrue(
            SwarmEnvironmentConditionEvaluator.meetsCondition(
                SwarmBackgroundCondition.POWER_CONNECTED,
                isPowerConnected = true,
                isWifiConnected = false,
            ),
        )
        assertFalse(
            SwarmEnvironmentConditionEvaluator.meetsCondition(
                SwarmBackgroundCondition.POWER_CONNECTED,
                isPowerConnected = false,
                isWifiConnected = true,
            ),
        )
        assertTrue(
            SwarmEnvironmentConditionEvaluator.meetsCondition(
                SwarmBackgroundCondition.WIFI_ONLY,
                isPowerConnected = false,
                isWifiConnected = true,
            ),
        )
        assertFalse(
            SwarmEnvironmentConditionEvaluator.meetsCondition(
                SwarmBackgroundCondition.WIFI_ONLY,
                isPowerConnected = true,
                isWifiConnected = false,
            ),
        )
    }

    @Test
    fun `preference defaults match Swift`() {
        val prefs = SwarmBackgroundPreferences()
        assertEquals(SwarmBackgroundLocation.DISABLED, prefs.location)
        assertEquals(SwarmBackgroundCondition.ALWAYS, prefs.condition)
        assertEquals(AgentProvider.swarmGlyphProviders, prefs.selectedGlyphs)
        assertTrue(prefs.isAvatarEnabled)
        assertTrue(prefs.isBrandTextEnabled)
        assertFalse(prefs.excludeBrandShapes)
        assertEquals("swarmBackgroundPreferencesV2", SwarmBackgroundPreferences.USER_DEFAULTS_KEY)
    }

    @Test
    fun `glyph providers match the Swift list in order`() {
        val expected =
            listOf(
                "Factory",
                "Claude Code",
                "Codex",
                "OpenCode",
                "OpenClaw",
                "OpenClaude",
                "OMP",
                "Hermes",
                "Prime Agent",
                "Gemini CLI",
                "Junie",
                "Antigravity",
                "OpenAI",
                "OpenBurnBar",
                "DeepSeek",
                "MiniMax",
                "Zai",
                "xAI",
                "MiMo",
                "Cursor",
                "Copilot",
                "Kimi",
                "Aider",
                "Cline",
                "Kilo Code",
                "Roo Code",
                "Forge",
                "Augment",
                "Pi Agent",
                "Goose",
                "Ollama",
                "Windsurf",
                "Devin",
                "Warp",
                "Cursor Agent",
                "Muse",
                "fx",
            )
        assertEquals(expected, AgentProvider.swarmGlyphProviders.map { it.displayName })
    }

    @Test
    fun `preferences round trip through JSON`() {
        val prefs =
            SwarmBackgroundPreferences(
                location = SwarmBackgroundLocation.EVERYWHERE,
                condition = SwarmBackgroundCondition.WIFI_ONLY,
                selectedGlyphs = listOf(AgentProvider.CODEX, AgentProvider.XAI),
                isAvatarEnabled = false,
                isBrandTextEnabled = true,
                excludeBrandShapes = true,
            )
        assertEquals(prefs, SwarmBackgroundPreferences.from(prefs.toJsonString()))
    }

    @Test
    fun `empty object decodes to defaults`() {
        assertEquals(SwarmBackgroundPreferences(), SwarmBackgroundPreferences.from("{}"))
    }

    @Test
    fun `malformed JSON decodes to defaults`() {
        assertEquals(SwarmBackgroundPreferences(), SwarmBackgroundPreferences.from("not json"))
        assertEquals(SwarmBackgroundPreferences(), SwarmBackgroundPreferences.from("[1,2]"))
        assertEquals(SwarmBackgroundPreferences(), SwarmBackgroundPreferences.from(""))
    }

    @Test
    fun `missing keys fall back per field`() {
        val prefs = SwarmBackgroundPreferences.from("""{"location":"Everywhere"}""")
        assertEquals(SwarmBackgroundLocation.EVERYWHERE, prefs.location)
        assertEquals(SwarmBackgroundCondition.ALWAYS, prefs.condition)
        assertEquals(AgentProvider.swarmGlyphProviders, prefs.selectedGlyphs)
        assertTrue(prefs.isAvatarEnabled)
    }

    @Test
    fun `explicit nulls fall back per field`() {
        val prefs =
            SwarmBackgroundPreferences.from(
                """{"location":null,"condition":null,"selectedGlyphs":null,"isAvatarEnabled":null,"isBrandTextEnabled":null,"excludeBrandShapes":null}""",
            )
        assertEquals(SwarmBackgroundPreferences(), prefs)
    }

    @Test
    fun `unknown location discards the whole payload`() {
        val prefs =
            SwarmBackgroundPreferences.from(
                """{"location":"Yolo","condition":"Always","isAvatarEnabled":false}""",
            )
        assertEquals(SwarmBackgroundPreferences(), prefs)
    }

    @Test
    fun `unknown glyph token discards the whole payload`() {
        val prefs =
            SwarmBackgroundPreferences.from(
                """{"location":"Everywhere","selectedGlyphs":["Codex","Nope"]}""",
            )
        assertEquals(SwarmBackgroundPreferences(), prefs)
    }

    @Test
    fun `mistyped values discard the whole payload`() {
        assertEquals(
            SwarmBackgroundPreferences(),
            SwarmBackgroundPreferences.from("""{"isAvatarEnabled":"yes"}"""),
        )
        assertEquals(
            SwarmBackgroundPreferences(),
            SwarmBackgroundPreferences.from("""{"selectedGlyphs":"Codex"}"""),
        )
        assertEquals(
            SwarmBackgroundPreferences(),
            SwarmBackgroundPreferences.from("""{"selectedGlyphs":[42]}"""),
        )
    }

    @Test
    fun `default JSON parses back to defaults`() {
        assertEquals(
            SwarmBackgroundPreferences(),
            SwarmBackgroundPreferences.from(SwarmBackgroundPreferences.DEFAULT_JSON),
        )
        assertTrue(SwarmBackgroundPreferences.DEFAULT_JSON.contains("\"location\":\"Disabled\""))
        assertTrue(SwarmBackgroundPreferences.DEFAULT_JSON.contains("\"condition\":\"Always\""))
    }

    @Test
    fun `stored location decodes every wire value`() {
        assertEquals(SwarmBackgroundLocation.DISABLED, swarmLocationFromStoredValue("Disabled"))
        assertEquals(SwarmBackgroundLocation.AGENTS_TAB, swarmLocationFromStoredValue("Agents Tab Only"))
        assertEquals(SwarmBackgroundLocation.EVERYWHERE, swarmLocationFromStoredValue("Everywhere"))
    }

    @Test
    fun `stored location falls back to everywhere when missing or unrecognized`() {
        // Android's persisted default preserves the historical always-on look
        // (the JSON codec default stays disabled per the iOS contract).
        assertEquals(SwarmBackgroundLocation.EVERYWHERE, swarmLocationFromStoredValue(null))
        assertEquals(SwarmBackgroundLocation.EVERYWHERE, swarmLocationFromStoredValue(""))
        assertEquals(SwarmBackgroundLocation.EVERYWHERE, swarmLocationFromStoredValue("   "))
        assertEquals(SwarmBackgroundLocation.EVERYWHERE, swarmLocationFromStoredValue("Yolo"))
        // Wire values are case-sensitive, like the codec.
        assertEquals(SwarmBackgroundLocation.EVERYWHERE, swarmLocationFromStoredValue("everywhere"))
    }

    @Test
    fun `stored condition decodes every wire value`() {
        assertEquals(SwarmBackgroundCondition.ALWAYS, swarmConditionFromStoredValue("Always"))
        assertEquals(SwarmBackgroundCondition.POWER_CONNECTED, swarmConditionFromStoredValue("Power Connected Only"))
        assertEquals(SwarmBackgroundCondition.WIFI_ONLY, swarmConditionFromStoredValue("Wi-Fi Only"))
    }

    @Test
    fun `stored condition falls back to always when missing or unrecognized`() {
        assertEquals(SwarmBackgroundCondition.ALWAYS, swarmConditionFromStoredValue(null))
        assertEquals(SwarmBackgroundCondition.ALWAYS, swarmConditionFromStoredValue(""))
        assertEquals(SwarmBackgroundCondition.ALWAYS, swarmConditionFromStoredValue("   "))
        assertEquals(SwarmBackgroundCondition.ALWAYS, swarmConditionFromStoredValue("Yolo"))
        assertEquals(SwarmBackgroundCondition.ALWAYS, swarmConditionFromStoredValue("always"))
    }

    @Test
    fun `condition section shows only while the swarm is enabled somewhere`() {
        // Mirrors the iOS `if prefs.location != .disabled` gate.
        assertFalse(swarmConditionSectionVisible(SwarmBackgroundLocation.DISABLED))
        assertTrue(swarmConditionSectionVisible(SwarmBackgroundLocation.AGENTS_TAB))
        assertTrue(swarmConditionSectionVisible(SwarmBackgroundLocation.EVERYWHERE))
    }
}
