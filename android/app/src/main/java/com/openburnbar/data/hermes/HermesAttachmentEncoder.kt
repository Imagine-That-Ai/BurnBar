package com.openburnbar.data.hermes

import android.content.Context
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

/** Soft cap so the multimodal payload stays under typical Hermes limits. */
object HermesAttachmentLimits {
    /** ~8 MB inline payload ceiling per attachment. */
    const val MAX_INLINE_BYTES = 8L * 1024L * 1024L

    /** Total number of attachments allowed per send. */
    const val MAX_ATTACHMENTS = 6
}

/**
 * Translates Hermes attachments into a multimodal `content` JSON array.
 *
 * - Plain text: returns the prompt string unchanged.
 * - With attachments: returns a JSONArray with the prompt as a leading
 *   text part, then one part per attachment. Images become `image_url`
 *   parts with inline `data:` URLs; text/PDF/everything-else become
 *   inline `text` parts that quote the file body (size-capped).
 */
object HermesAttachmentEncoder {

    fun encodeUserTurn(prompt: String, attachments: List<HermesAttachment>): Any {
        if (attachments.isEmpty()) return prompt
        val array = JSONArray()
        if (prompt.isNotBlank()) {
            array.put(JSONObject().apply {
                put("type", "text")
                put("text", prompt)
            })
        }
        for (attachment in attachments) {
            array.put(encodePart(attachment))
        }
        return array
    }

    private fun encodePart(attachment: HermesAttachment): JSONObject {
        val bytes = readBytesSafely(attachment)
        if (attachment.isImage && bytes != null) {
            val b64 = Base64.getEncoder().encodeToString(bytes)
            return JSONObject().apply {
                put("type", "image_url")
                put("image_url", JSONObject().apply {
                    put("url", "data:${attachment.mimeType};base64,$b64")
                })
            }
        }
        val body = bytes?.let { decodeBodyForText(it, attachment.mimeType) }
            ?: "[unreadable attachment ${attachment.fileName}]"
        return JSONObject().apply {
            put("type", "text")
            put("text", "Attachment ${attachment.fileName} (${attachment.mimeType}):\n$body")
        }
    }

    private fun readBytesSafely(attachment: HermesAttachment): ByteArray? {
        val path = attachment.absolutePath
        if (!path.isNullOrBlank()) {
            return runCatching {
                val file = java.io.File(path)
                if (file.length() > HermesAttachmentLimits.MAX_INLINE_BYTES) {
                    file.inputStream().use { it.readNBytes(HermesAttachmentLimits.MAX_INLINE_BYTES.toInt()) }
                } else {
                    file.readBytes()
                }
            }.getOrNull()
        }
        return null
    }

    private fun decodeBodyForText(bytes: ByteArray, mimeType: String): String {
        if (mimeType.startsWith("text/") || mimeType == "application/json" || mimeType == "application/xml") {
            return runCatching { String(bytes, Charsets.UTF_8) }.getOrDefault("[binary content]")
        }
        return "[binary content, ${bytes.size} bytes]"
    }
}

/** Helpers for materialising a content-URI attachment to an app-private path. */
object HermesAttachmentLoader {

    /**
     * Copy the contents at [uri] to the cache dir and return the absolute
     * path so the encoder can read it without keeping a URI permission
     * grant alive.
     */
    fun materialise(context: Context, uri: Uri, suggestedName: String?): String? {
        return runCatching {
            val name = suggestedName?.takeIf { it.isNotBlank() }
                ?: "hermes-${System.currentTimeMillis()}.bin"
            val target = java.io.File(context.cacheDir, "hermes-attachments").apply {
                if (!exists()) mkdirs()
            }.resolve(name)
            context.contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            target.absolutePath
        }.getOrNull()
    }
}
