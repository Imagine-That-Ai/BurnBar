package com.openburnbar.data.square

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * `@Serializable` mirror of the Swift `CLIAgentSessionRecord` Codable used by the
 * Mac writer (`CLIAgentSessionCodec.encodeSealed`) and the iOS reader
 * (`CLIAgentSessionCodec.decodeSealed`). The Mac seals the **entire** record —
 * including the private `customTitle` and transcript `messages` — as a Cloud
 * Vault payload, JSON-encoded with `JSONEncoder.openBurnBarCloudPayload`
 * (ISO-8601 dates, sorted keys). Android opens that payload and decodes it here.
 *
 * Field names are pinned to the Swift property names so the JSON round-trips
 * byte-for-byte across surfaces:
 *   `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CLIAgentSessionRecord.swift`.
 *
 * Dates arrive as ISO-8601 strings (Swift `.iso8601` strategy); we keep them as
 * `String` here and convert to epoch millis in [toSessionRecord] so we never
 * depend on a kotlinx date serializer and stay tolerant of fractional seconds.
 */
@Serializable
internal data class CLIAgentSealedSessionPayload(
    val id: String = "",
    val agent: String = "",
    val sourceKind: String = "live_chat",
    val title: String = "",
    val preview: String = "",
    val modelName: String? = null,
    val workspaceLabel: String? = null,
    val createdAt: String? = null,
    val updatedAt: String? = null,
    val endedAt: String? = null,
    val schemaVersion: Int = 1,
    val messages: List<CLIAgentSealedMessage> = emptyList(),
    val tokenUsage: CLIAgentSealedTokenUsage? = null,
    val resumeHandle: CLIAgentSealedResumeHandle? = null,
    val encryptedTranscriptAvailable: Boolean = false,
    val customTitle: String? = null,
    val labelColorHex: String? = null,
    val isPinned: Boolean? = null,
    val priorityOrder: Int? = null,
)

@Serializable
internal data class CLIAgentSealedMessage(
    val id: String = "",
    val role: String = "assistant",
    val text: String = "",
    val timestamp: String? = null,
    val isError: Boolean = false,
    val toolUses: List<CLIAgentSealedToolUse> = emptyList(),
)

@Serializable
internal data class CLIAgentSealedToolUse(
    val id: String = "",
    val name: String = "tool",
    val status: String = "",
    val detail: String? = null,
    val startedAt: String? = null,
)

@Serializable
internal data class CLIAgentSealedResumeHandle(
    val providerSessionID: String = "",
    val projectLabel: String? = null,
    val commandHint: String? = null,
    val canResume: Boolean = false,
    val canFork: Boolean = false,
    val canForward: Boolean = true,
)

@Serializable
internal data class CLIAgentSealedTokenUsage(
    val inputTokens: Int = 0,
    val outputTokens: Int = 0,
    val cacheCreationTokens: Int = 0,
    val cacheReadTokens: Int = 0,
    val reasoningTokens: Int = 0,
)

/**
 * Shared JSON decoder for the sealed CLI-session payload. `ignoreUnknownKeys`
 * keeps Android forward-tolerant when the Mac writer ships new fields first;
 * `isLenient` tolerates the wire shape produced by `JSONEncoder`.
 */
internal val cliAgentSealedSessionJson: Json =
    Json {
        ignoreUnknownKeys = true
        isLenient = true
    }
