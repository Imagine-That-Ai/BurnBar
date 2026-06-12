package com.openburnbar.data.insights

import com.openburnbar.data.assistants.CLIAgentChatPresentationMode
import com.openburnbar.data.assistants.CLIAgentMissionRequestPayloadFactory
import com.openburnbar.data.assistants.CLIAgentMissionRequestPayloadFactory.Core
import com.openburnbar.data.assistants.CLIAgentMissionRequestPayloadFactory.Execution
import com.openburnbar.data.assistants.CLIAgentMissionRequestPayloadFactory.Experience
import com.openburnbar.data.assistants.CLIAgentMissionRequestPayloadFactory.Metadata
import com.openburnbar.data.assistants.CLIAgentMissionRequestPayloadFactory.PayloadInput
import com.openburnbar.data.assistants.CLIAgentMissionRequestPayloadFactory.Permissions
import com.openburnbar.data.assistants.SkillRunDeliveryMode
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

private const val MISSION_SCHEMA_VERSION = 3

class CLIAgentMissionRequestPayloadFactoryTest {
    @Test
    fun `CLI agent mission request payload includes launch options without mutable parent events`() {
        val payload =
            CLIAgentMissionRequestPayloadFactory.build(
                PayloadInput(
                    core =
                    Core(
                        id = "mission-123",
                        title = "  Run cost mission  ",
                        prompt = "  Inspect provider routing cost  ",
                        missionKind = "cost_efficiency",
                    ),
                    execution =
                    Execution(
                        requestedRuntime = "opencode",
                        targetProject = "  ~/Developer/OpenBurnBar  ",
                        depth = "deep",
                        approvalMode = "risky_only",
                    ),
                    permissions = Permissions(commandsAllowed = true, fileEditsAllowed = false),
                    now = Instant.parse("2026-05-14T10:00:00Z"),
                ),
            )

        assertEquals("mission-123", payload["id"])
        assertEquals("Run cost mission", payload["title"])
        assertEquals("Inspect provider routing cost", payload["prompt"])
        assertEquals("cost_efficiency", payload["missionKind"])
        assertEquals("opencode", payload["requestedRuntime"])
        assertEquals("~/Developer/OpenBurnBar", payload["targetProject"])
        assertEquals("deep", payload["depth"])
        assertEquals("risky_only", payload["approvalMode"])
        assertEquals(true, payload["commandsAllowed"])
        assertEquals(false, payload["fileEditsAllowed"])
        assertEquals("android-insights", payload["source"])
        assertEquals("android-insights", payload["sourceSurface"])
        assertEquals("action_only", payload["deliveryMode"])
        assertEquals("native_chat", payload["presentationMode"])
        assertEquals("pending", payload["status"])
        assertEquals(MISSION_SCHEMA_VERSION, payload["schemaVersion"])
        assertFalse(payload.containsKey("events"))
    }

    @Test
    fun `CLI agent mission request payload includes Skill Run metadata`() {
        val payload =
            CLIAgentMissionRequestPayloadFactory.build(
                PayloadInput(
                    core =
                    Core(
                        id = "mission-skill",
                        title = "Explain yesterday",
                        prompt = "What happened yesterday?",
                        missionKind = "chat",
                    ),
                    execution =
                    Execution(
                        requestedRuntime = "hermes",
                        targetProject = null,
                        depth = "standard",
                        approvalMode = "existing_policy",
                    ),
                    permissions = Permissions(commandsAllowed = false, fileEditsAllowed = false),
                    metadata =
                    Metadata(
                        sourceSkillID = "what_happened",
                        sourceSurface = "android-hermes-square",
                        parentHermesThreadID = "thread-1",
                    ),
                    experience = Experience(deliveryMode = SkillRunDeliveryMode.FULL_STREAM),
                ),
            )

        assertEquals("what_happened", payload["sourceSkillID"])
        assertEquals("android-hermes-square", payload["sourceSurface"])
        assertEquals("full_stream", payload["deliveryMode"])
        assertEquals("thread-1", payload["parentHermesThreadID"])
    }

    @Test
    fun `CLI agent mission request payload includes visible Mac CLI presentation mode`() {
        val payload =
            CLIAgentMissionRequestPayloadFactory.build(
                PayloadInput(
                    core =
                    Core(
                        id = "mission-visible",
                        title = "Visible Codex",
                        prompt = "Run where I can watch it.",
                        missionKind = "chat",
                    ),
                    execution =
                    Execution(
                        requestedRuntime = "codex",
                        targetProject = null,
                        depth = "standard",
                        approvalMode = "existing_policy",
                    ),
                    permissions = Permissions(commandsAllowed = false, fileEditsAllowed = false),
                    metadata = Metadata(sourceSurface = "android-chat-mac-visible-cli"),
                    experience =
                    Experience(
                        deliveryMode = SkillRunDeliveryMode.FULL_STREAM,
                        presentationMode = CLIAgentChatPresentationMode.MAC_VISIBLE_CLI,
                    ),
                ),
            )

        assertEquals("android-chat-mac-visible-cli", payload["sourceSurface"])
        assertEquals("full_stream", payload["deliveryMode"])
        assertEquals("mac_visible_cli", payload["presentationMode"])
    }

    @Test
    fun `CLI agent mission request payload includes requested model id`() {
        val payload =
            CLIAgentMissionRequestPayloadFactory.build(
                PayloadInput(
                    core =
                    Core(
                        id = "mission-model",
                        title = "Run Codex",
                        prompt = "Answer using the selected model.",
                        missionKind = "chat",
                    ),
                    execution =
                    Execution(
                        requestedRuntime = "codex",
                        targetProject = null,
                        depth = "standard",
                        approvalMode = "existing_policy",
                        requestedModelID = "  gpt-5.5  ",
                    ),
                    permissions = Permissions(commandsAllowed = false, fileEditsAllowed = false),
                ),
            )

        assertEquals("codex", payload["requestedRuntime"])
        assertEquals("gpt-5.5", payload["requestedModelID"])
    }
}
