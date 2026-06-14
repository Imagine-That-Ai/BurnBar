package com.openburnbar.data.square

import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.missions.ActiveMission
import com.openburnbar.data.missions.MobileMissionConsoleHost

internal data class ThreadInboxRefreshParts(
    val cliSessionsByItemID: Map<String, CLIAgentSessionRecord>,
    val items: List<ThreadInboxItem>,
)

internal fun buildThreadInboxRefreshParts(
    parsed: List<CLIAgentSessionRecord>,
    history: AssistantChatHistoryStore?,
    missionHost: MobileMissionConsoleHost?,
): ThreadInboxRefreshParts {
    val cliSessionsByItemID = parsed.associateBy { "cli:${it.id}" }
    val merged = mutableListOf<ThreadInboxItem>()
    val mobileCLIThreadIDs = mutableSetOf<String>()
    history?.let { merged.addAll(threadInboxHistoryItems(it, mobileCLIThreadIDs)) }
    merged.addAll(threadInboxCliMirrorItems(parsed, mobileCLIThreadIDs))
    missionHost?.let { merged.addAll(threadInboxMissionItems(it)) }
    return ThreadInboxRefreshParts(cliSessionsByItemID, merged.sortedForInbox())
}

private fun threadInboxHistoryItems(history: AssistantChatHistoryStore, mobileCLIThreadIDs: MutableSet<String>): List<ThreadInboxItem> =
    history.threads.value.mapNotNull { thread ->
        val agentURI: String
        val source: ThreadInboxItem.Source
        val runtimeLower = thread.runtime.lowercase().trim()
        when (runtimeLower) {
            "hermes" -> {
                agentURI = AgentIdentity.builtInURI(AssistantRuntimeID.HERMES)
                source = ThreadInboxItem.Source.HERMES
            }
            "pi" -> {
                agentURI = AgentIdentity.builtInURI(AssistantRuntimeID.PI)
                source = ThreadInboxItem.Source.PI
            }
            "codex", "claude", "openclaw", "droid", "forge", "antigravity", "grok", "cursoragent", "cursor_agent", "cursor-agent" -> {
                val runtime =
                    when (runtimeLower) {
                        "codex" -> AssistantRuntimeID.CODEX
                        "claude" -> AssistantRuntimeID.CLAUDE
                        "openclaw" -> AssistantRuntimeID.OPEN_CLAW
                        "droid" -> AssistantRuntimeID.DROID
                        "forge" -> AssistantRuntimeID.FORGE
                        "antigravity" -> AssistantRuntimeID.ANTIGRAVITY
                        "grok" -> AssistantRuntimeID.GROK
                        "cursoragent", "cursor_agent", "cursor-agent" -> AssistantRuntimeID.CURSOR_AGENT
                        else -> return@mapNotNull null
                    }
                agentURI = AgentIdentity.builtInURI(runtime)
                source = ThreadInboxItem.Source.CLI_MIRROR
                mobileCLIThreadIDs.add(thread.id)
            }
            else -> return@mapNotNull null
        }
        ThreadInboxItem(
            id = "${source.token}:${thread.id}",
            agentURI = agentURI,
            title = thread.title.ifBlank { "(untitled)" },
            preview = thread.preview,
            lastActivityAtEpoch = thread.updatedAtMillis,
            unreadCount = 0,
            needsAttention = false,
            source = source,
            liveMissionID = null,
            searchText = listOf(thread.title, thread.preview, agentURI).joinToString(" "),
            customTitle = thread.customTitle,
            labelColorHex = thread.labelColorHex,
            isPinned = thread.isPinned,
            priorityOrder = thread.priorityOrder,
        )
    }

private fun threadInboxCliMirrorItems(parsed: List<CLIAgentSessionRecord>, mobileCLIThreadIDs: Set<String>): List<ThreadInboxItem> =
    parsed.filter { it.id !in mobileCLIThreadIDs }.map { record ->
        ThreadInboxItem(
            id = "cli:${record.id}",
            agentURI = record.agentURI,
            title = record.title.ifBlank { "(no title)" },
            preview = record.preview,
            lastActivityAtEpoch = record.updatedAtEpoch,
            unreadCount = 0,
            needsAttention = false,
            source = ThreadInboxItem.Source.CLI_MIRROR,
            liveMissionID = null,
            searchText = record.searchableText,
            customTitle = record.customTitle,
            labelColorHex = record.labelColorHex,
            isPinned = record.isPinned,
            priorityOrder = record.priorityOrder,
        )
    }

private fun threadInboxMissionItems(host: MobileMissionConsoleHost): List<ThreadInboxItem> = host.snapshot.value.activeMissions.map { tile ->
    val runtimeID =
        tile.runtimeID?.let { runtimeStr ->
            AssistantRuntimeID.values().firstOrNull { it.token == runtimeStr }
        }
    val agentURI = runtimeID?.let { AgentIdentity.builtInURI(it) } ?: "agent://burnbar/auto"
    ThreadInboxItem(
        id = "mission:${tile.id}",
        agentURI = agentURI,
        title = tile.title,
        preview = tile.phaseDetail ?: tile.phase.displayLabel,
        lastActivityAtEpoch = tile.startedAt?.toEpochMilli() ?: System.currentTimeMillis(),
        unreadCount = if (tile.approvalPending) 1 else 0,
        needsAttention = tile.approvalPending || tile.phase == ActiveMission.Phase.FAILED || tile.phase == ActiveMission.Phase.BLOCKED,
        source = ThreadInboxItem.Source.MISSION_GROUP,
        liveMissionID = tile.id,
    )
}
