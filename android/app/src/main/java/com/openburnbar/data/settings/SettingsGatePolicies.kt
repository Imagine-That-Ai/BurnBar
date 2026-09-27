package com.openburnbar.data.settings

import com.openburnbar.data.models.AgentProvider
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/**
 * Pure gate-policy port of the `SettingsManager` cluster's portable core:
 * - `AgentLens/Models/ChatBackendID.swift` (identity + CSV list codec)
 * - `AgentLens/Models/HermesModelID.swift` (model picker + CSV list codec)
 * - `AgentLens/Models/Settings/SummaryProviderID.swift` + `SummarySettings.swift`
 *   (provider order parse + init-time default/clamp rules)
 * - `ChatBackendSettings.resolvedHermesChatModel/resolvedPiChatModel`
 * - `SettingsManager.decodeJSONStringArray/encodeJSONStringArray` (lossless
 *   string-list codec incl. the manual-serializer fallback)
 *
 * Platform-owned machinery (UserDefaults/SharedPreferences persistence,
 * Keychain secret migration, debounced flush, `@Observable` fan-out) stays
 * platform-native; this file owns the decision tables, codecs, defaults, and
 * error shapes so every platform resolves the same values for the same inputs.
 * Persisted tokens (CSV raw values, JSON keys) are byte-compatible with Swift.
 */

// MARK: - ChatBackendId

enum class ChatBackendId(
    val rawValue: String,
    val displayName: String,
    val shortLabel: String,
    val glyph: String,
    val agentProvider: AgentProvider,
    val requiresCliAssistantConsent: Boolean,
) {
    CODEX("codex", "Codex", "Codex", "↻", AgentProvider.CODEX, true),
    CLAUDE("claude", "Claude Code", "Claude", "✦", AgentProvider.CLAUDE_CODE, true),
    HERMES("hermes", "Hermes", "Hermes", "☿", AgentProvider.HERMES, false),
    OPENCLAW("openclaw", "OpenClaw", "Claw", "⚡", AgentProvider.OPEN_CLAW, false),
    OPEN_CLAUDE("openclaude", "OpenClaude", "OClaude", "✸", AgentProvider.OPEN_CLAUDE, true),
    OMP("omp", "OMP", "OMP", "⌘", AgentProvider.OMP, true),
    PI_AGENT("piAgent", "Pi Agent", "Pi", "π", AgentProvider.PI_AGENT, false),
    DROID("droid", "Droid", "Droid", "◆", AgentProvider.FACTORY, true),
    FORGE("forge", "Forge", "Forge", "▰", AgentProvider.FORGE_DEV, true),
    ANTIGRAVITY("antigravity", "Antigravity", "AGY", "✧", AgentProvider.ANTIGRAVITY, true),
    CURSOR_AGENT("cursorAgent", "Cursor Agent", "Cursor", "➤", AgentProvider.CURSOR_AGENT, true),
    JUNIE("junie", "Junie", "Junie", "✽", AgentProvider.JUNIE, true),
    FX("fx", "fx", "fx", "ƒ", AgentProvider.FX, true),
    GROK("grok", "Grok", "Grok", "⚡", AgentProvider.XAI, true),
    KIMI("kimi", "Kimi", "Kimi", "☾", AgentProvider.KIMI, true),
    ;

    companion object {
        /**
         * Swift's hand-built `ChatBackendID.allCases` — NOT declaration order:
         * Pi Agent sorts ahead of the OpenClaw family. This is the order
         * enabled backends render in and the order a default engine falls
         * back through.
         */
        val allCases: List<ChatBackendId> =
            listOf(
                CODEX,
                CLAUDE,
                HERMES,
                PI_AGENT,
                OPENCLAW,
                OPEN_CLAUDE,
                OMP,
                DROID,
                FORGE,
                ANTIGRAVITY,
                CURSOR_AGENT,
                JUNIE,
                FX,
                GROK,
                KIMI,
            )

        fun fromRawValueOrNull(rawValue: String): ChatBackendId? = entries.find { it.rawValue == rawValue }

        /**
         * Swift `decodeEnabledList(fromCSV:)`: split on ",", trim, drop
         * empties, drop unknown tokens. Order-preserving and lossless for
         * known tokens.
         */
        fun decodeEnabledList(csv: String): List<ChatBackendId> = csv.split(",")
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .mapNotNull { fromRawValueOrNull(it) }

        /** Swift `encodeEnabledList(_:)`. */
        fun encodeEnabledList(backends: List<ChatBackendId>): String = backends.joinToString(",") { it.rawValue }
    }
}

// MARK: - HermesModelId

enum class HermesModelId(
    val rawValue: String,
    val displayName: String,
    val agentProvider: AgentProvider,
    val hermesModelOverride: String,
) {
    CODEX("codex", "Codex", AgentProvider.CODEX, "codex"),
    CLAUDE("claude", "Claude", AgentProvider.CLAUDE_CODE, "claude"),
    ZAI("zai", "Z.ai", AgentProvider.ZAI, "zai"),
    KIMI("kimi", "Kimi", AgentProvider.KIMI, "kimi"),
    MINIMAX("minimax", "MiniMax", AgentProvider.MINIMAX, "minimax"),
    OLLAMA("ollama", "Ollama", AgentProvider.OLLAMA, "ollama"),
    ;

    /** Swift `shortLabel`: the compact row reuses the display name. */
    val shortLabel: String get() = displayName

    companion object {
        /**
         * Swift `HermesModelID.defaultEnabled`: the minimum-default triple
         * shown when the user hasn't customized the list.
         */
        val defaultEnabled: List<HermesModelId> = listOf(CODEX, CLAUDE, OLLAMA)

        fun fromRawValueOrNull(rawValue: String): HermesModelId? = entries.find { it.rawValue == rawValue }

        fun decodeEnabledList(csv: String): List<HermesModelId> = csv.split(",")
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .mapNotNull { fromRawValueOrNull(it) }

        fun encodeEnabledList(models: List<HermesModelId>): String = models.joinToString(",") { it.rawValue }
    }
}

// MARK: - SummaryProviderId

enum class SummaryProviderId(val rawValue: String) {
    LOCAL("local"),
    MLX("mlx"),
    MINIMAX("minimax"),
    OPENROUTER("openrouter"),
    ZAI("zai"),
    OLLAMA("ollama"),
    ;

    companion object {
        fun fromRawValueOrNull(rawValue: String): SummaryProviderId? = entries.find { it.rawValue == rawValue }
    }
}

// MARK: - Enabled-list policies

object SettingsEnabledListPolicies {
    /**
     * Swift `ChatBackendSettings.setChatBackendEnabled` as a pure list
     * transform: enabling appends (deduped), disabling removes all copies.
     */
    fun withChatBackendEnabled(current: List<ChatBackendId>, id: ChatBackendId, enabled: Boolean): List<ChatBackendId> = if (enabled) {
        if (current.contains(id)) current else current + id
    } else {
        current.filter { it != id }
    }

    /** Swift `ChatBackendSettings.setHermesModelEnabled` as a pure transform. */
    fun withHermesModelEnabled(current: List<HermesModelId>, id: HermesModelId, enabled: Boolean): List<HermesModelId> = if (enabled) {
        if (current.contains(id)) current else current + id
    } else {
        current.filter { it != id }
    }

    /**
     * Swift `enabledHermesModels` getter: an empty persisted list means "never
     * customized" and resolves to the minimum-default triple.
     */
    fun enabledHermesModelsOrDefault(csv: String): List<HermesModelId> {
        val list = HermesModelId.decodeEnabledList(csv)
        return if (list.isEmpty()) HermesModelId.defaultEnabled else list
    }

    /**
     * Swift `ChatBackendSettings.init` migration: a persisted CSV wins; else a
     * legacy single `chatBackendID` token upgrades to a one-element CSV; else
     * the list starts empty (which the UI treats as "all on" downstream).
     */
    fun migrateChatBackendCsv(existingCsv: String?, legacySingleRawValue: String?): String {
        if (existingCsv != null) return existingCsv
        val only = legacySingleRawValue?.let { ChatBackendId.fromRawValueOrNull(it) }
        return if (only != null) ChatBackendId.encodeEnabledList(listOf(only)) else ""
    }

    /**
     * Swift `ChatBackendSettings.applyHermesModelSelection` decision core: the
     * selection mirrors into `hermesChatModelOverride` so the existing chat
     * resolution path picks it up; clearing the selection clears the override
     * so the gateway-advertised default wins.
     */
    fun hermesModelOverrideForSelection(model: HermesModelId?): String = model?.hermesModelOverride ?: ""
}

// MARK: - Chat model resolution

object ChatModelResolution {
    /**
     * Swift `resolvedHermesChatModel`: explicit override wins, then the
     * gateway-advertised model, then the `"hermes"` fallback. Blank (after
     * trimming) counts as absent on both inputs.
     */
    fun resolvedHermesChatModel(override: String, gatewayAdvertisedModel: String?): String {
        val trimmed = override.trim()
        if (trimmed.isNotEmpty()) return trimmed
        val advertised = gatewayAdvertisedModel?.trim()
        if (!advertised.isNullOrEmpty()) return advertised
        return "hermes"
    }

    /** Swift `resolvedPiChatModel`: same chain with the `"pi"` fallback. */
    fun resolvedPiChatModel(override: String, gatewayAdvertisedModel: String?): String {
        val trimmed = override.trim()
        if (trimmed.isNotEmpty()) return trimmed
        val advertised = gatewayAdvertisedModel?.trim()
        if (!advertised.isNullOrEmpty()) return advertised
        return "pi"
    }
}

// MARK: - String-list JSON codec

object SettingsJsonArray {
    private const val CONTROL_CHARACTER_LIMIT = 0x20
    private const val HEX_RADIX = 16
    private const val UNICODE_ESCAPE_WIDTH = 4

    private val json = Json { encodeDefaults = true }

    /**
     * Swift `decodeJSONStringArray`: malformed JSON (or a non-array payload)
     * decodes to `[]`; elements are trimmed and empties dropped. Never throws.
     */
    fun decode(jsonString: String): List<String> {
        val element = runCatching { json.parseToJsonElement(jsonString) }.getOrNull()
        val array = element as? kotlinx.serialization.json.JsonArray ?: return emptyList()
        return array.mapNotNull { item ->
            // Swift decodes a strictly-typed [String]: a non-string element
            // fails the whole decode to []. (JsonPrimitive.content would
            // coerce numbers/bools to text, so gate on isString.)
            val primitive = item as? kotlinx.serialization.json.JsonPrimitive ?: return emptyList()
            if (!primitive.isString) return emptyList()
            primitive.content.trim()
        }.filter { it.isNotEmpty() }
    }

    /**
     * Swift `encodeJSONStringArray`: values are trimmed and empties dropped,
     * then JSON-encoded. On the (infeasible) encoder failure the values are
     * preserved via [manuallySerialize] — never collapsed to `"[]"` — because
     * collapsing would permanently drop the user's saved list on next flush.
     */
    fun encode(values: List<String>): String {
        val normalized = values.map { it.trim() }.filter { it.isNotEmpty() }
        return runCatching {
            json.encodeToString(ListSerializer(String.serializer()), normalized)
        }.getOrElse {
            manuallySerialize(normalized)
        }
    }

    /**
     * Swift `manuallySerializeJSONStringArray`: deterministic, infallible
     * JSON-array serialization. Escapes per RFC 8259 and matches Foundation's
     * `\/` forward-slash escape so the fallback output is byte-identical to
     * the Swift happy path for the same values.
     */
    fun manuallySerialize(values: List<String>): String {
        val elements =
            values.joinToString(",") { value ->
                buildString {
                    append('"')
                    for (char in value) {
                        when (char) {
                            '"' -> append("\\\"")
                            '\\' -> append("\\\\")
                            '/' -> append("\\/")
                            '\b' -> append("\\b")
                            '' -> append("\\f")
                            '\n' -> append("\\n")
                            '\r' -> append("\\r")
                            '\t' -> append("\\t")
                            else ->
                                if (char.code < CONTROL_CHARACTER_LIMIT) {
                                    append("\\u" + char.code.toString(HEX_RADIX).padStart(UNICODE_ESCAPE_WIDTH, '0'))
                                } else {
                                    append(char)
                                }
                        }
                    }
                    append('"')
                }
            }
        return "[$elements]"
    }
}

// MARK: - Summary provider order + defaults

object SummaryProviderOrder {
    const val DEFAULT_CSV = "local,mlx,minimax,openrouter,zai,ollama"

    val DEFAULT_ORDER: List<SummaryProviderId> =
        listOf(
            SummaryProviderId.LOCAL,
            SummaryProviderId.MLX,
            SummaryProviderId.MINIMAX,
            SummaryProviderId.OPENROUTER,
            SummaryProviderId.ZAI,
            SummaryProviderId.OLLAMA,
        )

    /**
     * Swift `SummarySettings.summaryProviderOrder`: tokens are trimmed +
     * lowercased, unknowns dropped; an empty parse resolves to the default
     * order; otherwise the parse is deduped (first wins) and any missing
     * providers are appended in `allCases` order so the result is always a
     * complete permutation.
     */
    fun parse(csv: String): List<SummaryProviderId> {
        val parsed =
            csv.split(",")
                .map { it.trim().lowercase() }
                .mapNotNull { SummaryProviderId.fromRawValueOrNull(it) }
        if (parsed.isEmpty()) return DEFAULT_ORDER
        val deduped = parsed.distinct()
        return deduped + SummaryProviderId.entries.filter { it !in deduped }
    }

    /** Swift `setSummaryProviderOrder(_:)` persistence shape. */
    fun encode(order: List<SummaryProviderId>): String = order.joinToString(",") { it.rawValue }
}

object SummarySettingsDefaults {
    const val AUTO_SESSION_SUMMARIES_ENABLED = true
    const val OPENROUTER_PRIMARY_MODEL = "qwen/qwen3.5-9b"
    const val OPENROUTER_FALLBACK_MODEL = "openai/gpt-5-nano"
    const val MINIMAX_MODEL = "gpt-5.5"
    const val ZAI_MODEL = "glm-5-turbo"
    const val OLLAMA_MODEL = "llama3.2"
    const val OLLAMA_BASE_URL = "http://127.0.0.1:11434"
    const val LOCAL_MODEL = "qwen3.5:9b"
    const val LOCAL_BASE_URL = "http://127.0.0.1:11434"
    const val MLX_MODEL = "mlx-community/Qwen3-4B-4bit"
    const val MLX_BASE_URL = "http://127.0.0.1:8080"
    const val MAX_PROMPT_CHARS = 60_000
    const val MAX_OUTPUT_TOKENS = 280
    const val RETRY_COUNT = 1
    const val BATCH_SIZE = 25
    const val FIRST_LOAD_BATCH_SIZE = 120
    const val REQUEST_TIMEOUT_SECONDS = 20.0
    const val MAX_CONCURRENCY = 8
    const val TIME_LIMIT_MINUTES = 0
    const val MIN_PERSISTED_PROMPT_CHARS = 4_000
    const val MIN_PERSISTED_OUTPUT_TOKENS = 120

    /**
     * Swift `SummarySettings.init` clamp rules for already-persisted values.
     * Each returns the effective value for a stored integer/double, or the
     * default when the key was never persisted (null).
     */
    fun sanitizeMaxPromptChars(stored: Int?): Int = stored?.let { if (it >= MIN_PERSISTED_PROMPT_CHARS) it else MAX_PROMPT_CHARS } ?: MAX_PROMPT_CHARS

    fun sanitizeMaxOutputTokens(stored: Int?): Int = stored?.let { if (it >= MIN_PERSISTED_OUTPUT_TOKENS) it else MAX_OUTPUT_TOKENS } ?: MAX_OUTPUT_TOKENS

    fun sanitizeRetryCount(stored: Int?): Int = stored?.let { maxOf(it, 0) } ?: RETRY_COUNT

    fun sanitizeBatchSize(stored: Int?): Int = stored?.let { maxOf(it, 1) } ?: BATCH_SIZE

    fun sanitizeFirstLoadBatchSize(stored: Int?): Int = stored?.let { maxOf(it, 1) } ?: FIRST_LOAD_BATCH_SIZE

    fun sanitizeRequestTimeoutSeconds(stored: Double?): Double = stored?.let { if (it > 0) it else REQUEST_TIMEOUT_SECONDS } ?: REQUEST_TIMEOUT_SECONDS

    fun sanitizeMaxConcurrency(stored: Int?): Int = stored?.let { maxOf(it, 1) } ?: MAX_CONCURRENCY

    fun sanitizeTimeLimitMinutes(stored: Int?): Int = stored?.let { maxOf(it, 0) } ?: TIME_LIMIT_MINUTES
}

object ChatBackendDefaults {
    const val OPENCLAW_GATEWAY_BASE_URL = "http://127.0.0.1:18789"
    const val HERMES_GATEWAY_BASE_URL = "http://127.0.0.1:8642"
    const val PI_AGENT_GATEWAY_BASE_URL = "http://127.0.0.1:8765"
    const val OLLAMA_BASE_URL = "http://127.0.0.1:11434"

    /** Swift `HermesRealtimeRelayProtocol.defaultHostedRelayURLString` (unset). */
    const val REALTIME_RELAY_URL = ""
    const val MEDIA_BLOB_TRANSFER_ENABLED = true
    const val COMPUTER_USE_KILL_SWITCH = true
    const val COMPUTER_USE_PHONE_CONTROL_RESPECTS_DENY_REGIONS = true
    const val MEDIA_KILL_SWITCH = true
    const val WAR_ROOM_KILL_SWITCH = true
}
