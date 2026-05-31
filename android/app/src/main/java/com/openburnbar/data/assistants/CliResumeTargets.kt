package com.openburnbar.data.assistants

import androidx.annotation.DrawableRes
import com.openburnbar.R

// Kotlin mirror of OpenBurnBarCore's CLIAgentResumePresentation. Keeps the
// resume-target catalog, the native-resume capability table, the status copy,
// and the outcome composition identical to the Swift apps and the daemon
// (BurnBarResumeService). Source of truth remains the relay/daemon response;
// these helpers only describe it.

enum class CliResumeCapability(val label: String) {
    NATIVE("Native"),
    HANDOFF("Handoff");

    val explanation: String
        get() = when (this) {
            NATIVE -> "Continues this session in place."
            HANDOFF -> "Opens a Mac-local handoff package."
        }
}

/**
 * Mirrors `BurnBarResumeService.providerSupport`: only Claude Code and Codex
 * resume natively today; every other provider receives a handoff package.
 * `canonicalWireId` must already be a daemon-canonical id.
 */
fun cliProviderSupportsNativeResume(canonicalWireId: String): Boolean = when (canonicalWireId) {
    "claude_code", "codex" -> true
    else -> false
}

/**
 * A provider a mirrored CLI session can be restarted into via "Resume in…".
 * `wireId` is the daemon-canonical id (matches `normalizeProvider`) so it is
 * safe to send verbatim as `CLIAgentSessionActionRequest.targetRuntime`.
 */
enum class CliResumeTarget(
    val wireId: String,
    val displayName: String,
    val supportsNativeResume: Boolean,
    @param:DrawableRes @field:DrawableRes val logoRes: Int,
    val brandColor: Long,
) {
    CLAUDE_CODE("claude_code", "Claude Code", true, R.drawable.claude_code_logo, 0xFFCC785C),
    CODEX("codex", "Codex", true, R.drawable.codex_logo, 0xFF2563EB),
    DROID("droid", "Droid", false, R.drawable.factory_logo, 0xFF8B5CF6),
    FORGE("forge", "Forge", false, R.drawable.forge_logo, 0xFFF97316),
    ANTIGRAVITY("antigravity", "Antigravity", false, R.drawable.antigravity_logo, 0xFF6C63FF),
    GROK("grok", "Grok", false, R.drawable.grok_logo, 0xFF71767B),
    CURSOR_AGENT("cursor_agent", "Cursor Agent", false, R.drawable.cursor_logo, 0xFF00B8D4),
    OPENCODE("opencode", "OpenCode", false, R.drawable.open_code_logo, 0xFF0EA5E9),
    GEMINI("gemini", "Gemini CLI", false, R.drawable.gemini_cli_logo, 0xFF4285F4);

    val capability: CliResumeCapability
        get() = if (supportsNativeResume) CliResumeCapability.NATIVE else CliResumeCapability.HANDOFF

    companion object {
        val all: List<CliResumeTarget> = values().toList()

        /** Map a session's stored agent token to its resume target, if known. */
        fun forSessionAgent(token: String?): CliResumeTarget? {
            val k = token?.trim()?.lowercase()?.replace(Regex("[^a-z0-9]+"), "") ?: return null
            return when (k) {
                "claudecode", "claude" -> CLAUDE_CODE
                "codex" -> CODEX
                "droid", "factory" -> DROID
                "forge", "forgedev" -> FORGE
                "antigravity", "agy" -> ANTIGRAVITY
                "grok", "xai" -> GROK
                "cursoragent", "cursor" -> CURSOR_AGENT
                "opencode" -> OPENCODE
                "gemini", "geminicli" -> GEMINI
                else -> null
            }
        }
    }
}

/** How to present one `CLIAgentSessionActionStatus` outcome. Mirrors Swift. */
data class CliResumeStatusPresentation(
    val title: String,
    val shortLabel: String,
    val isSuccess: Boolean,
)

val CLIAgentSessionActionStatus.presentation: CliResumeStatusPresentation
    get() = when (this) {
        CLIAgentSessionActionStatus.NATIVE_RESUME ->
            CliResumeStatusPresentation("Native resume", "Native", true)
        CLIAgentSessionActionStatus.HANDOFF ->
            CliResumeStatusPresentation("Handoff package started", "Handoff", true)
        CLIAgentSessionActionStatus.PACKAGE_ONLY ->
            CliResumeStatusPresentation("Package ready", "Package", true)
        CLIAgentSessionActionStatus.SPAWNED ->
            CliResumeStatusPresentation("Opened on Mac", "Opened", true)
        CLIAgentSessionActionStatus.ERROR ->
            CliResumeStatusPresentation("Couldn’t restart", "Error", false)
    }

/** Display-ready summary of a completed session action. Mirrors Swift. */
data class CliResumeOutcome(
    val status: CLIAgentSessionActionStatus,
    val isSuccess: Boolean,
    val headline: String,
    val detail: String?,
    val recovery: String?,
) {
    companion object {
        fun from(
            response: CLIAgentSessionActionResponse,
            requestedTargetDisplayName: String?,
        ): CliResumeOutcome {
            val p = response.status.presentation
            val target = requestedTargetDisplayName
                ?: response.targetRuntime?.let { CliResumeTarget.forSessionAgent(it)?.displayName }
            val headline = if (response.status != CLIAgentSessionActionStatus.ERROR && !target.isNullOrEmpty()) {
                "${p.title} · $target"
            } else {
                p.title
            }
            val detail: String?
            val recovery: String?
            if (response.status == CLIAgentSessionActionStatus.ERROR) {
                detail = null
                recovery = response.errorRecovery?.takeIf { it.isNotBlank() }
                    ?: response.errorCode?.takeIf { it.isNotBlank() }?.let { "Error: $it" }
                    ?: "Update or restart OpenBurnBar on your Mac"
            } else {
                detail = successDetail(response)
                recovery = null
            }
            return CliResumeOutcome(response.status, p.isSuccess, headline, detail, recovery)
        }

        private fun successDetail(r: CLIAgentSessionActionResponse): String? {
            val parts = mutableListOf<String>()
            r.pid?.let { parts.add("PID $it") }
            val pkg = r.briefingPath?.takeIf { it.isNotBlank() }?.substringAfterLast('/')
            if (pkg != null) {
                parts.add(pkg)
            } else if (r.pid == null && r.argv.isNotEmpty()) {
                parts.add(r.argv.joinToString(" ").let { if (it.length <= 48) it else it.take(47) + "…" })
            }
            r.workingDirectory?.takeIf { it.isNotBlank() }?.let { parts.add(it) }
            if (parts.isEmpty()) {
                r.note?.takeIf { it.isNotBlank() }?.let { parts.add(it.replace('_', ' ')) }
            }
            return parts.joinToString(" · ").ifBlank { null }
        }
    }
}
