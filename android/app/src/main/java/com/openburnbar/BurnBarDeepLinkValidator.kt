package com.openburnbar

/**
 * T-AND-03 — pure validator/whitelist for inbound `burnbar://` deep links.
 *
 * `MainActivity` is an exported, BROWSABLE entry point, so any app (or a crafted web link)
 * can hand it a `burnbar://...` URI. The navigation graph addresses every tab/screen by a
 * fixed set of hosts and only a few dynamic path/query parameters. Before a release build
 * lets such a URI reach the nav host, [isAllowed] confirms the host is one we publish and
 * that any dynamic parameter is well-formed — so a hostile or malformed link (unknown host,
 * an over-long / control-character `connectionId`, a path-traversal `slug`) is dropped at the
 * door rather than flowing into a screen. Pure (no Android types) so the whitelist is
 * unit-testable without a device.
 *
 * Kept deliberately conservative: an unknown host is REJECTED (default-deny), and a known
 * host with a malformed dynamic segment is REJECTED. Static-only hosts (no dynamic segment)
 * are always accepted.
 */
object BurnBarDeepLinkValidator {
    const val SCHEME = "burnbar"

    /** Hosts with no dynamic segment — accepted as long as the path is empty. */
    private val STATIC_HOSTS =
        setOf(
            "pulse",
            "burn",
            "insights",
            "streams",
            "search",
            "hermes",
            "chat",
            "assistants",
            "you",
            "cloud",
            "data",
            "computer-use",
            "paired-mac",
            "dashboard",
            "quickglance",
        )

    /**
     * Hosts that carry exactly one dynamic segment, paired with the validator for that
     * segment's RAW (still URL-encoded) value.
     */
    private val DYNAMIC_HOSTS: Map<String, (String) -> Boolean> =
        mapOf(
            // burnbar://insights/{slug}
            "insights" to ::isSafeSlug,
            // burnbar://agent/{uri}
            "agent" to ::isSafeEncodedSegment,
            // burnbar://mercury/call/{connectionId}  and  burnbar://paired-mac/{connectionId}
            "mercury" to ::isSafeConnectionPath,
            "paired-mac" to ::isSafeConnectionId,
        )

    /** Max length of any single dynamic deep-link segment (raw, pre-decode). */
    private const val MAX_SEGMENT_LENGTH = 256

    /** First printable ASCII code point; anything below is a control character. */
    private const val FIRST_PRINTABLE_ASCII = 0x20

    /** DEL control character code point. */
    private const val DEL_CHAR = 0x7f

    /**
     * @param scheme the URI scheme (e.g. "burnbar"); a non-`burnbar` scheme is not ours,
     *   so we do not police it (return true — let the platform route it normally).
     * @param host the URI authority/host (e.g. "mercury").
     * @param pathSegments the decoded-by-the-caller path segments after the host
     *   (e.g. ["call", "abc123"] for `burnbar://mercury/call/abc123`).
     */
    fun isAllowed(scheme: String?, host: String?, pathSegments: List<String>): Boolean {
        // Not our scheme → not our business; do not block.
        if (scheme != null && !scheme.equals(SCHEME, ignoreCase = true)) return true
        val normalizedHost = host?.lowercase() ?: return false

        // Static host with no extra path is always fine.
        if (pathSegments.isEmpty()) return normalizedHost in STATIC_HOSTS || normalizedHost in DYNAMIC_HOSTS

        val validator = DYNAMIC_HOSTS[normalizedHost] ?: return false
        // The last segment is the dynamic value; everything before it must be a fixed
        // literal of the known route (e.g. the "call" in mercury/call/{id}).
        return validator(pathSegments.joinToString("/"))
    }

    private fun isSafeConnectionPath(path: String): Boolean {
        val segments = path.split('/')
        return when (segments.size) {
            // mercury/{connectionId} is not a route; mercury/call/{connectionId} is.
            2 -> segments[0] == "call" && isSafeConnectionId(segments[1])
            else -> false
        }
    }

    /**
     * Connection ids are short, opaque, server-issued tokens. Restrict to a conservative
     * URL-safe charset and bounded length so a forged link cannot smuggle control bytes or a
     * giant payload into a call/pairing screen.
     */
    fun isSafeConnectionId(value: String): Boolean =
        value.isNotEmpty() &&
            value.length <= MAX_SEGMENT_LENGTH &&
            value.all { it.isAsciiAlphanumeric() || it == '-' || it == '_' || it == '.' }

    /** Insights slugs are lowercase token paths; reject traversal / control characters. */
    fun isSafeSlug(value: String): Boolean =
        value.isNotEmpty() &&
            value.length <= MAX_SEGMENT_LENGTH &&
            ".." !in value &&
            value.all { it.isAsciiAlphanumeric() || it == '-' || it == '_' }

    /**
     * The agent `{uri}` segment is itself URL-encoded and decoded + looked up against a
     * registry by the screen (an unknown id pops back), so the validator only needs to bound
     * the length and reject control characters here.
     */
    fun isSafeEncodedSegment(value: String): Boolean =
        value.isNotEmpty() &&
            value.length <= MAX_SEGMENT_LENGTH &&
            value.none { it.code < FIRST_PRINTABLE_ASCII || it.code == DEL_CHAR }

    private fun Char.isAsciiAlphanumeric(): Boolean =
        this in 'A'..'Z' || this in 'a'..'z' || this in '0'..'9'
}
