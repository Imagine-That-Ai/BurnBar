package com.openburnbar.ui.components

import com.openburnbar.data.models.AgentProvider
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/**
 * Gate-policy port of `OpenBurnBarMobile/Models/SwarmBackgroundPreferences.swift`.
 *
 * The render-plan power policy, the decorative-effects gate, the visibility
 * lattice, and the persisted-preferences codec are the cross-platform contract:
 * Android must resolve the exact same plan (and the exact same persisted
 * defaults) as iOS for the same inputs. The particle simulation itself lives in
 * [SwarmBackground.kt][SwarmBackground]; this file owns only the gating layer.
 *
 * Wire values (location/condition raw strings, preference JSON keys, glyph
 * display names) are byte-compatible with the Swift `Codable` forms so
 * preferences round-trip across platforms.
 */

// MARK: - Location / condition

enum class SwarmBackgroundLocation(val wireValue: String) {
    DISABLED("Disabled"),
    AGENTS_TAB("Agents Tab Only"),
    EVERYWHERE("Everywhere"),
    ;

    companion object {
        fun fromWireValueOrNull(wireValue: String): SwarmBackgroundLocation? = entries.find { it.wireValue == wireValue }
    }
}

enum class SwarmBackgroundCondition(val wireValue: String) {
    ALWAYS("Always"),
    POWER_CONNECTED("Power Connected Only"),
    WIFI_ONLY("Wi-Fi Only"),
    ;

    companion object {
        fun fromWireValueOrNull(wireValue: String): SwarmBackgroundCondition? = entries.find { it.wireValue == wireValue }
    }
}

// MARK: - Visibility lattice

enum class MobileBackgroundVisibility {
    PROMINENT,
    SUBTLE,
    OBSCURED,
    HIDDEN,
    ;

    private val restrictionRank: Int
        get() =
            when (this) {
                PROMINENT -> 0
                SUBTLE -> 1
                OBSCURED -> 2
                HIDDEN -> 3
            }

    /**
     * Swift `MobileBackgroundVisibility.constrained(by:)`: the more restrictive
     * of the two wins. Ties resolve to `this`.
     */
    fun constrained(byInherited: MobileBackgroundVisibility): MobileBackgroundVisibility =
        if (restrictionRank >= byInherited.restrictionRank) this else byInherited
}

// MARK: - Render plan

enum class SwarmRenderMode {
    LIVE,
    STATIC_BACKDROP,
    DISABLED_FALLBACK,
}

data class SwarmBackgroundRenderPlan(
    val mode: SwarmRenderMode,
    val maxFrameRate: Double?,
    val particleScale: Double,
    val motionSpeedMultiplierScale: Double,
    val allowsAutoCycling: Boolean,
    val allowsSparkles: Boolean,
    val isBatteryThrottled: Boolean,
) {
    companion object {
        val PROMINENT_LIVE =
            SwarmBackgroundRenderPlan(
                mode = SwarmRenderMode.LIVE,
                maxFrameRate = 30.0,
                particleScale = 1.0,
                motionSpeedMultiplierScale = 1.0,
                allowsAutoCycling = true,
                allowsSparkles = true,
                isBatteryThrottled = false,
            )
        val SUBTLE_LIVE =
            SwarmBackgroundRenderPlan(
                mode = SwarmRenderMode.LIVE,
                maxFrameRate = 15.0,
                particleScale = 0.45,
                motionSpeedMultiplierScale = 0.55,
                allowsAutoCycling = false,
                allowsSparkles = false,
                isBatteryThrottled = true,
            )
        val STATIC_BACKDROP =
            SwarmBackgroundRenderPlan(
                mode = SwarmRenderMode.STATIC_BACKDROP,
                maxFrameRate = null,
                particleScale = 0.0,
                motionSpeedMultiplierScale = 0.0,
                allowsAutoCycling = false,
                allowsSparkles = false,
                isBatteryThrottled = true,
            )
        val DISABLED_FALLBACK =
            SwarmBackgroundRenderPlan(
                mode = SwarmRenderMode.DISABLED_FALLBACK,
                maxFrameRate = null,
                particleScale = 0.0,
                motionSpeedMultiplierScale = 0.0,
                allowsAutoCycling = false,
                allowsSparkles = false,
                isBatteryThrottled = false,
            )
    }
}

// MARK: - Power policy

object SwarmBackgroundPowerPolicy {
    /**
     * Swift `SwarmBackgroundPowerPolicy.resolve`: the guard chain is order
     * sensitive — location → condition → scene/visibility → motion/obscured →
     * low-power — and each early return is a distinct plan. Keep in lockstep.
     */
    fun resolve(
        location: SwarmBackgroundLocation,
        conditionMet: Boolean,
        requestedVisibility: MobileBackgroundVisibility,
        scenePhaseActive: Boolean,
        isLowPowerModeEnabled: Boolean,
        reduceMotion: Boolean,
    ): SwarmBackgroundRenderPlan {
        if (location == SwarmBackgroundLocation.DISABLED) {
            return SwarmBackgroundRenderPlan.DISABLED_FALLBACK
        }
        if (!conditionMet) {
            return SwarmBackgroundRenderPlan.STATIC_BACKDROP
        }
        if (!scenePhaseActive || requestedVisibility == MobileBackgroundVisibility.HIDDEN) {
            return SwarmBackgroundRenderPlan.STATIC_BACKDROP
        }
        if (reduceMotion || requestedVisibility == MobileBackgroundVisibility.OBSCURED) {
            return SwarmBackgroundRenderPlan.STATIC_BACKDROP
        }
        if (isLowPowerModeEnabled) {
            return if (requestedVisibility == MobileBackgroundVisibility.PROMINENT) {
                SwarmBackgroundRenderPlan.SUBTLE_LIVE
            } else {
                SwarmBackgroundRenderPlan.STATIC_BACKDROP
            }
        }
        return if (requestedVisibility == MobileBackgroundVisibility.PROMINENT) {
            SwarmBackgroundRenderPlan.PROMINENT_LIVE
        } else {
            SwarmBackgroundRenderPlan.SUBTLE_LIVE
        }
    }
}

object MobileDecorativeRenderPolicy {
    /**
     * Swift `MobileDecorativeRenderPolicy.allowsLiveEffects`: live decorative
     * effects run only while the scene is active and the background is at
     * least subtle (neither hidden nor obscured).
     */
    fun allowsLiveEffects(visibility: MobileBackgroundVisibility, scenePhaseActive: Boolean): Boolean = scenePhaseActive &&
        visibility != MobileBackgroundVisibility.HIDDEN &&
        visibility != MobileBackgroundVisibility.OBSCURED
}

// MARK: - Environment condition

object SwarmEnvironmentConditionEvaluator {
    /**
     * Pure decision core of Swift `SwarmEnvironmentMonitor.meetsCondition`:
     * the platform monitor owns the sensors; the gate owns the truth table.
     */
    fun meetsCondition(condition: SwarmBackgroundCondition, isPowerConnected: Boolean, isWifiConnected: Boolean): Boolean = when (condition) {
        SwarmBackgroundCondition.ALWAYS -> true
        SwarmBackgroundCondition.POWER_CONNECTED -> isPowerConnected
        SwarmBackgroundCondition.WIFI_ONLY -> isWifiConnected
    }
}

// MARK: - Persisted preferences

data class SwarmBackgroundPreferences(
    val location: SwarmBackgroundLocation = SwarmBackgroundLocation.DISABLED,
    val condition: SwarmBackgroundCondition = SwarmBackgroundCondition.ALWAYS,
    val selectedGlyphs: List<AgentProvider> = AgentProvider.swarmGlyphProviders,
    val isAvatarEnabled: Boolean = true,
    val isBrandTextEnabled: Boolean = true,
    val excludeBrandShapes: Boolean = false,
) {
    fun toJsonString(): String = toJsonString(this)

    companion object {
        const val USER_DEFAULTS_KEY = "swarmBackgroundPreferencesV2"

        private const val KEY_LOCATION = "location"
        private const val KEY_CONDITION = "condition"
        private const val KEY_SELECTED_GLYPHS = "selectedGlyphs"
        private const val KEY_IS_AVATAR_ENABLED = "isAvatarEnabled"
        private const val KEY_IS_BRAND_TEXT_ENABLED = "isBrandTextEnabled"
        private const val KEY_EXCLUDE_BRAND_SHAPES = "excludeBrandShapes"

        private val json = Json { encodeDefaults = true }

        val DEFAULT_JSON: String = SwarmBackgroundPreferences().toJsonString()

        /**
         * Swift `SwarmBackgroundPreferences.from(jsonString:)`: a missing key
         * (or an explicit null, per `decodeIfPresent`) falls back to that
         * field's default, but any structural failure —
         * malformed JSON, a mistyped value, an unknown location/condition wire
         * value, or an unrecognized glyph token — discards the whole payload
         * and returns defaults. That all-or-nothing shape is what makes a
         * corrupt write self-heal instead of half-applying.
         */
        fun from(jsonString: String): SwarmBackgroundPreferences {
            val root = runCatching { json.parseToJsonElement(jsonString) as? JsonObject }.getOrNull()
                ?: return SwarmBackgroundPreferences()
            return decodeObject(root) ?: SwarmBackgroundPreferences()
        }

        private fun JsonObject.fieldOrNull(key: String): JsonElement? {
            val element = this[key] ?: return null
            return if (element is JsonNull) null else element
        }

        private sealed interface Decoded<out T> {
            data class Value<T>(val value: T) : Decoded<T>

            data object Missing : Decoded<Nothing>

            data object Invalid : Decoded<Nothing>
        }

        private fun decodeLocation(root: JsonObject): Decoded<SwarmBackgroundLocation> {
            val element = root.fieldOrNull(KEY_LOCATION) ?: return Decoded.Missing
            val text = (element as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return Decoded.Invalid
            val location = SwarmBackgroundLocation.fromWireValueOrNull(text) ?: return Decoded.Invalid
            return Decoded.Value(location)
        }

        private fun decodeCondition(root: JsonObject): Decoded<SwarmBackgroundCondition> {
            val element = root.fieldOrNull(KEY_CONDITION) ?: return Decoded.Missing
            val text = (element as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return Decoded.Invalid
            val condition = SwarmBackgroundCondition.fromWireValueOrNull(text) ?: return Decoded.Invalid
            return Decoded.Value(condition)
        }

        private fun decodeGlyphs(root: JsonObject): Decoded<List<AgentProvider>> {
            val element = root.fieldOrNull(KEY_SELECTED_GLYPHS) ?: return Decoded.Missing
            val array: JsonArray = element as? JsonArray ?: return Decoded.Invalid
            val glyphs =
                array.map { item ->
                    val primitive = item as? JsonPrimitive ?: return Decoded.Invalid
                    if (!primitive.isString) return Decoded.Invalid
                    AgentProvider.entries.find { it.displayName == primitive.content } ?: return Decoded.Invalid
                }
            return Decoded.Value(glyphs)
        }

        private fun decodeFlag(root: JsonObject, key: String): Decoded<Boolean> {
            val element = root.fieldOrNull(key) ?: return Decoded.Missing
            val flag = (element as? JsonPrimitive)?.booleanOrNull ?: return Decoded.Invalid
            return Decoded.Value(flag)
        }

        private fun decodeObject(root: JsonObject): SwarmBackgroundPreferences? {
            // A present-but-mistyped value fails the whole payload (Swift's
            // decodeIfPresent throws); only a missing key or explicit null
            // falls back to the field default.
            val location =
                when (val decoded = decodeLocation(root)) {
                    is Decoded.Value -> decoded.value
                    is Decoded.Missing -> SwarmBackgroundLocation.DISABLED
                    is Decoded.Invalid -> return null
                }
            val condition =
                when (val decoded = decodeCondition(root)) {
                    is Decoded.Value -> decoded.value
                    is Decoded.Missing -> SwarmBackgroundCondition.ALWAYS
                    is Decoded.Invalid -> return null
                }
            val selectedGlyphs =
                when (val decoded = decodeGlyphs(root)) {
                    is Decoded.Value -> decoded.value
                    is Decoded.Missing -> AgentProvider.swarmGlyphProviders
                    is Decoded.Invalid -> return null
                }
            val isAvatarEnabled =
                when (val decoded = decodeFlag(root, KEY_IS_AVATAR_ENABLED)) {
                    is Decoded.Value -> decoded.value
                    is Decoded.Missing -> true
                    is Decoded.Invalid -> return null
                }
            val isBrandTextEnabled =
                when (val decoded = decodeFlag(root, KEY_IS_BRAND_TEXT_ENABLED)) {
                    is Decoded.Value -> decoded.value
                    is Decoded.Missing -> true
                    is Decoded.Invalid -> return null
                }
            val excludeBrandShapes =
                when (val decoded = decodeFlag(root, KEY_EXCLUDE_BRAND_SHAPES)) {
                    is Decoded.Value -> decoded.value
                    is Decoded.Missing -> false
                    is Decoded.Invalid -> return null
                }
            return SwarmBackgroundPreferences(
                location = location,
                condition = condition,
                selectedGlyphs = selectedGlyphs,
                isAvatarEnabled = isAvatarEnabled,
                isBrandTextEnabled = isBrandTextEnabled,
                excludeBrandShapes = excludeBrandShapes,
            )
        }

        private fun toJsonString(prefs: SwarmBackgroundPreferences): String {
            val obj =
                JsonObject(
                    mapOf(
                        KEY_LOCATION to JsonPrimitive(prefs.location.wireValue),
                        KEY_CONDITION to JsonPrimitive(prefs.condition.wireValue),
                        KEY_SELECTED_GLYPHS to JsonArray(prefs.selectedGlyphs.map { JsonPrimitive(it.displayName) }),
                        KEY_IS_AVATAR_ENABLED to JsonPrimitive(prefs.isAvatarEnabled),
                        KEY_IS_BRAND_TEXT_ENABLED to JsonPrimitive(prefs.isBrandTextEnabled),
                        KEY_EXCLUDE_BRAND_SHAPES to JsonPrimitive(prefs.excludeBrandShapes),
                    ),
                )
            return json.encodeToString(JsonObject.serializer(), obj)
        }
    }
}

// MARK: - Persisted store mapping

/**
 * Decodes the stored location wire value. A missing, blank, or unrecognized
 * value falls back to [SwarmBackgroundLocation.EVERYWHERE]: Android's swarm
 * has always been on, so the persisted default preserves the historical
 * always-on look until the user picks otherwise in Settings. The JSON codec
 * default stays DISABLED (the iOS cross-platform contract); this default
 * applies only to the Android DataStore keys.
 */
internal fun swarmLocationFromStoredValue(raw: String?): SwarmBackgroundLocation {
    if (raw.isNullOrBlank()) return SwarmBackgroundLocation.EVERYWHERE
    return SwarmBackgroundLocation.fromWireValueOrNull(raw) ?: SwarmBackgroundLocation.EVERYWHERE
}

/**
 * Decodes the stored condition wire value. A missing, blank, or unrecognized
 * value falls back to [SwarmBackgroundCondition.ALWAYS], matching both the
 * JSON codec and iOS.
 */
internal fun swarmConditionFromStoredValue(raw: String?): SwarmBackgroundCondition {
    if (raw.isNullOrBlank()) return SwarmBackgroundCondition.ALWAYS
    return SwarmBackgroundCondition.fromWireValueOrNull(raw) ?: SwarmBackgroundCondition.ALWAYS
}

// MARK: - Settings section visibility

/**
 * Mirrors the iOS `SwarmBackgroundSettingsView` gate (`if prefs.location !=
 * .disabled`): the When/condition picker (and the formation controls it
 * heads) only render once the swarm is enabled somewhere.
 */
internal fun swarmConditionSectionVisible(location: SwarmBackgroundLocation): Boolean = location != SwarmBackgroundLocation.DISABLED
