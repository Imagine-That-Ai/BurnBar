package com.openburnbar.data.hermes

enum class HermesChatRole {
    USER, ASSISTANT, SYSTEM
}

enum class HermesTokenCountSource {
    PROVIDER_USAGE, ESTIMATED_TEXT
}

data class HermesTokenUsageStats(
    val promptTokens: Int? = null,
    val outputTokens: Int? = null,
    val totalTokens: Int? = null,
    val generationDurationSeconds: Double? = null,
    val totalDurationSeconds: Double? = null
)

data class HermesChatMessage(
    val id: String = java.util.UUID.randomUUID().toString(),
    val role: HermesChatRole = HermesChatRole.ASSISTANT,
    val text: String = "",
    val toolCalls: List<HermesToolCall> = emptyList(),
    val attachments: List<HermesAttachment> = emptyList(),
    val requestedModelID: String? = null,
    val responseModelID: String? = null,
    val modelName: String? = null,
    val timestamp: Long = System.currentTimeMillis(),
    val isStreaming: Boolean = false,
    val isError: Boolean = false,
    val outputTokenCount: Int? = null,
    val totalTokenCount: Int? = null,
    val tokenCountSource: HermesTokenCountSource? = null,
    val providerGenerationDurationSeconds: Double? = null,
    val providerTotalDurationSeconds: Double? = null
) {
    val tokensPerSecond: Double?
        get() {
            if (isError || outputTokenCount == null || outputTokenCount <= 0) return null
            val duration = providerGenerationDurationSeconds
                ?: return null
            return if (duration > 0) outputTokenCount / duration else null
        }

    val isTokensPerSecondEstimated: Boolean
        get() = tokenCountSource == HermesTokenCountSource.ESTIMATED_TEXT

    val tokensPerSecondDisplayText: String?
        get() {
            val tps = tokensPerSecond ?: return null
            val value = when {
                tps >= 100 -> "%.0f".format(tps)
                tps >= 10 -> "%.1f".format(tps)
                else -> "%.2f".format(tps)
            }
            val prefix = if (isTokensPerSecondEstimated) "~" else ""
            return "${prefix}${value} tok/s"
        }
}

data class HermesToolCall(
    val id: String = "",
    val name: String = "",
    val status: String = "running"
)

data class HermesAttachment(
    val id: String = java.util.UUID.randomUUID().toString(),
    val fileName: String,
    val mimeType: String,
    val uriString: String? = null,
    val thumbnailUriString: String? = null,
    /** Absolute file-system path after materialising the content URI. */
    val absolutePath: String? = null,
    val sizeBytes: Long? = null
) {
    val isImage: Boolean
        get() = mimeType.startsWith("image/")

    val isText: Boolean
        get() = mimeType.startsWith("text/") ||
            mimeType == "application/json" ||
            mimeType == "application/xml"

    val isPdf: Boolean
        get() = mimeType == "application/pdf"
}
