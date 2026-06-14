package com.openburnbar

/**
 * T-AND-06 — pure scrubber for Sentry crash/ANR payloads + breadcrumbs.
 *
 * The Android app ships crash/ANR reports to Sentry. Those payloads (exception messages,
 * log/event messages, breadcrumb text, the `extras` bag) can incidentally embed fragments of
 * a user prompt or a credential — exactly the on-device-only secrets the rest of the app works
 * to never exfiltrate. This object redacts those fragments BEFORE the SDK ships anything off
 * device.
 *
 * Kept as a pure function of strings (no Sentry types) so the redaction rules are unit-testable
 * without the SDK; [SentryPrivacyInit] adapts the live `SentryEvent` / `Breadcrumb` onto it.
 */
object SentryPrivacyScrubber {
    const val REDACTED = "[redacted]"

    /**
     * Keys (case-insensitive, substring match) whose VALUE is always a secret and must be dropped
     * wholesale from a breadcrumb-data / extras map.
     */
    private val SENSITIVE_KEY_FRAGMENTS =
        listOf(
            "prompt",
            "credential",
            "password",
            "passcode",
            "secret",
            "token",
            "apikey",
            "api_key",
            "authorization",
            "auth_header",
            "vaultkey",
            "vault_key",
            "private_key",
            "privatekey",
            "seed",
            "mnemonic",
            "session_key",
            "sealedpayload",
            "plaintext",
            "message_text",
            "reply_text",
            "replytext",
        )

    /**
     * Inline patterns that look like a secret embedded in free text (e.g. an exception message
     * `"failed to seal prompt='buy 100 shares'"`). Each match's captured secret span is replaced
     * with [REDACTED]; the surrounding structure is preserved so the report is still useful.
     */
    private const val SECRET_KEY_ALTERNATION =
        "prompt|password|passcode|credential|secret|token|api[_-]?key|authorization|" +
            "vault[_-]?key|private[_-]?key|seed|mnemonic|plaintext|reply[_-]?text|message[_-]?text"

    /**
     * `key=value` / `key: value` where the key names a secret. Group 1 is the key (+ delimiter, kept
     * intact in the output); group 2 is the secret VALUE (redacted). A QUOTED value may contain
     * spaces and runs to the closing quote; an UNQUOTED value runs to the next whitespace / comma /
     * brace.
     */
    private val KEY_VALUE_PATTERN: Regex =
        Regex("(?i)(\\b(?:$SECRET_KEY_ALTERNATION)\\b\\s*[=:]\\s*)(\"[^\"]*\"|'[^']*'|[^\\s,}{]+)")

    /** `Bearer <token>` — redact the token, keep the scheme word. */
    private val BEARER_PATTERN: Regex = Regex("(?i)\\bBearer\\s+[A-Za-z0-9._\\-]+")

    /** Redact a free-text message (exception message, log message, breadcrumb message). */
    fun scrubMessage(message: String?): String? {
        if (message.isNullOrEmpty()) return message
        var scrubbed: String = message
        // key=value: keep the key + delimiter (group 1), redact the value (group 2).
        scrubbed = KEY_VALUE_PATTERN.replace(scrubbed) { match -> "${match.groupValues[1]}$REDACTED" }
        // Bearer tokens: keep the scheme word, redact the token.
        scrubbed = BEARER_PATTERN.replace(scrubbed) { _ -> "Bearer $REDACTED" }
        return scrubbed
    }

    /** True when [key] names a value that must be dropped wholesale from a data/extras map. */
    fun isSensitiveKey(key: String?): Boolean {
        if (key == null) return false
        val lower = key.lowercase()
        return SENSITIVE_KEY_FRAGMENTS.any { it in lower }
    }

    /**
     * Scrub a key/value map (breadcrumb `data`, event `extras`): sensitive keys have their value
     * replaced with [REDACTED]; every other string value is run through [scrubMessage] in case a
     * secret was embedded in otherwise-innocent text.
     */
    fun scrubDataMap(data: Map<String, Any?>): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>(data.size)
        for ((key, value) in data) {
            out[key] =
                when {
                    isSensitiveKey(key) -> REDACTED
                    value is String -> scrubMessage(value)
                    else -> value
                }
        }
        return out
    }
}
