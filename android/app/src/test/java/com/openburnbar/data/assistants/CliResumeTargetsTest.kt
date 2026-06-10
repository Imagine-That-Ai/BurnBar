@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces; the
// 47/48-char truncation boundary is literal by design.

package com.openburnbar.data.assistants

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirror-contract tests for the CLI resume presentation layer: the
 * daemon-canonical wire ids, the native-vs-handoff capability table, the
 * fuzzy session-agent token normalization, and the [CliResumeOutcome]
 * headline/detail/recovery composition.
 */
class CliResumeTargetsTest {
    private fun response(
        status: CLIAgentSessionActionStatus,
        targetRuntime: String? = null,
        argv: List<String> = emptyList(),
        briefingPath: String? = null,
        workingDirectory: String? = null,
        pid: Int? = null,
        note: String? = null,
        errorCode: String? = null,
        errorRecovery: String? = null,
    ) = CLIAgentSessionActionResponse(
        status = status,
        targetRuntime = targetRuntime,
        argv = argv,
        briefingPath = briefingPath,
        workingDirectory = workingDirectory,
        pid = pid,
        cleanupAfterSeconds = null,
        note = note,
        errorCode = errorCode,
        errorRecovery = errorRecovery,
    )

    // ── catalog invariants ──

    @Test
    fun `only claude code and codex resume natively`() {
        assertTrue(cliProviderSupportsNativeResume("claude_code"))
        assertTrue(cliProviderSupportsNativeResume("codex"))
        assertFalse(cliProviderSupportsNativeResume("droid"))
        assertFalse(cliProviderSupportsNativeResume("gemini"))
        assertFalse(cliProviderSupportsNativeResume(""))

        // The enum table must agree with the daemon support function.
        for (target in CliResumeTarget.all) {
            assertEquals(target.wireId, cliProviderSupportsNativeResume(target.wireId), target.supportsNativeResume)
        }
    }

    @Test
    fun `wire ids are unique daemon canonical tokens`() {
        val wireIds = CliResumeTarget.all.map { it.wireId }
        assertEquals(wireIds.size, wireIds.toSet().size)
        for (wireId in wireIds) {
            assertTrue("non-canonical wire id: $wireId", wireId.matches(Regex("[a-z0-9_]+")))
        }
    }

    @Test
    fun `capability follows the native resume flag with user facing copy`() {
        assertEquals(CliResumeCapability.NATIVE, CliResumeTarget.CODEX.capability)
        assertEquals(CliResumeCapability.HANDOFF, CliResumeTarget.DROID.capability)
        assertEquals("Continues this session in place.", CliResumeCapability.NATIVE.explanation)
        assertEquals("Opens a Mac-local handoff package.", CliResumeCapability.HANDOFF.explanation)
    }

    // ── session-agent token normalization ──

    @Test
    fun `forSessionAgent normalizes case whitespace and separators`() {
        assertEquals(CliResumeTarget.CLAUDE_CODE, CliResumeTarget.forSessionAgent("  Claude Code "))
        assertEquals(CliResumeTarget.CLAUDE_CODE, CliResumeTarget.forSessionAgent("claude-code"))
        assertEquals(CliResumeTarget.CLAUDE_CODE, CliResumeTarget.forSessionAgent("claude"))
        assertEquals(CliResumeTarget.DROID, CliResumeTarget.forSessionAgent("Factory"))
        assertEquals(CliResumeTarget.CURSOR_AGENT, CliResumeTarget.forSessionAgent("cursor_agent"))
        assertEquals(CliResumeTarget.CURSOR_AGENT, CliResumeTarget.forSessionAgent("Cursor"))
        assertEquals(CliResumeTarget.GROK, CliResumeTarget.forSessionAgent("xAI"))
        assertEquals(CliResumeTarget.GEMINI, CliResumeTarget.forSessionAgent("gemini-cli"))
        assertEquals(CliResumeTarget.ANTIGRAVITY, CliResumeTarget.forSessionAgent("AGY"))
    }

    @Test
    fun `forSessionAgent returns null for unknown or absent tokens`() {
        assertNull(CliResumeTarget.forSessionAgent(null))
        assertNull(CliResumeTarget.forSessionAgent(""))
        assertNull(CliResumeTarget.forSessionAgent("some-future-agent"))
    }

    // ── status presentation ──

    @Test
    fun `every status maps to a presentation and only error is a failure`() {
        for (status in CLIAgentSessionActionStatus.values()) {
            val presentation = status.presentation
            assertEquals(status == CLIAgentSessionActionStatus.ERROR, !presentation.isSuccess)
            assertTrue(presentation.title.isNotBlank())
            assertTrue(presentation.shortLabel.isNotBlank())
        }
        assertEquals("Native resume", CLIAgentSessionActionStatus.NATIVE_RESUME.presentation.title)
        assertEquals("Couldn’t restart", CLIAgentSessionActionStatus.ERROR.presentation.title)
    }

    // ── outcome composition ──

    @Test
    fun `success headline appends the resolved target name`() {
        val outcome = CliResumeOutcome.from(
            response(CLIAgentSessionActionStatus.NATIVE_RESUME, targetRuntime = "codex", pid = 4242),
            requestedTargetDisplayName = null,
        )
        assertTrue(outcome.isSuccess)
        assertEquals("Native resume · Codex", outcome.headline)
        assertEquals("PID 4242", outcome.detail)
        assertNull(outcome.recovery)
    }

    @Test
    fun `error outcomes prefer recovery copy then error code then the generic hint`() {
        val withRecovery = CliResumeOutcome.from(
            response(CLIAgentSessionActionStatus.ERROR, errorRecovery = "Re-pair the Mac", errorCode = "E42"),
            requestedTargetDisplayName = "Codex",
        )
        assertFalse(withRecovery.isSuccess)
        // Error headlines never advertise the target that failed.
        assertEquals("Couldn’t restart", withRecovery.headline)
        assertEquals("Re-pair the Mac", withRecovery.recovery)
        assertNull(withRecovery.detail)

        val withCode = CliResumeOutcome.from(
            response(CLIAgentSessionActionStatus.ERROR, errorCode = "spawn_failed"),
            requestedTargetDisplayName = null,
        )
        assertEquals("Error: spawn_failed", withCode.recovery)

        val bare = CliResumeOutcome.from(response(CLIAgentSessionActionStatus.ERROR), requestedTargetDisplayName = null)
        assertEquals("Update or restart OpenBurnBar on your Mac", bare.recovery)
    }

    @Test
    fun `success detail prefers briefing package basename over argv`() {
        val outcome = CliResumeOutcome.from(
            response(
                CLIAgentSessionActionStatus.HANDOFF,
                targetRuntime = "droid",
                briefingPath = "/tmp/handoffs/session-9/briefing.md",
                argv = listOf("droid", "--resume"),
                workingDirectory = "/Users/me/project",
            ),
            requestedTargetDisplayName = "Droid",
        )
        assertEquals("Handoff package started · Droid", outcome.headline)
        assertEquals("briefing.md · /Users/me/project", outcome.detail)
    }

    @Test
    fun `argv detail truncates beyond 48 characters with an ellipsis`() {
        val longArgv = listOf("claude", "--resume", "0123456789012345678901234567890123456789")
        val joined = longArgv.joinToString(" ")
        assertTrue(joined.length > 48)
        val outcome = CliResumeOutcome.from(
            response(CLIAgentSessionActionStatus.SPAWNED, argv = longArgv),
            requestedTargetDisplayName = null,
        )
        assertEquals(joined.take(47) + "…", outcome.detail)

        val shortArgv = listOf("codex", "resume")
        val short = CliResumeOutcome.from(
            response(CLIAgentSessionActionStatus.SPAWNED, argv = shortArgv),
            requestedTargetDisplayName = null,
        )
        assertEquals("codex resume", short.detail)
    }

    @Test
    fun `with nothing else the note is humanized and an empty detail is null`() {
        val noted = CliResumeOutcome.from(
            response(CLIAgentSessionActionStatus.PACKAGE_ONLY, note = "package_only_mode"),
            requestedTargetDisplayName = null,
        )
        assertEquals("package only mode", noted.detail)

        val empty = CliResumeOutcome.from(
            response(CLIAgentSessionActionStatus.PACKAGE_ONLY),
            requestedTargetDisplayName = null,
        )
        assertNull(empty.detail)
    }
}
