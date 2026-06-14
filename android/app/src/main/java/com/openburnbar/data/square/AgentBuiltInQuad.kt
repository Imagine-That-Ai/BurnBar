
package com.openburnbar.data.square

import com.openburnbar.data.hermes.AssistantRuntimeID

internal data class AgentBuiltInQuad(
    val paletteHex: String,
    val tagline: String,
    val capabilities: AgentCapabilities,
    val transport: AgentDispatchTransport,
)

private val macCliCapabilities =
    AgentCapabilities.FULL_CLI.union(AgentCapabilities.CODE_EXECUTION).union(AgentCapabilities.MCP_UI)

private val builtInQuads: Map<AssistantRuntimeID, AgentBuiltInQuad> =
    mapOf(
        AssistantRuntimeID.HERMES to
            AgentBuiltInQuad(
                paletteHex = "AEA69C",
                tagline = "Editorial synthesis and mission triage.",
                capabilities = AgentCapabilities.FULL_CHAT,
                transport = AgentDispatchTransport.NativeRelay,
            ),
        AssistantRuntimeID.PI to
            AgentBuiltInQuad(
                paletteHex = "7C3AED",
                tagline = "Conversational sidekick. Warm, fast, casual.",
                capabilities = AgentCapabilities.FULL_CHAT,
                transport = AgentDispatchTransport.NativeRelay,
            ),
        AssistantRuntimeID.CLAUDE to
            AgentBuiltInQuad(
                paletteHex = "CC785C",
                tagline = "Anthropic Claude Code via your Mac.",
                capabilities = AgentCapabilities.FULL_CLI.union(AgentCapabilities.VISION).union(AgentCapabilities.MCP_UI),
                transport = AgentDispatchTransport.MacRelay("claude"),
            ),
        AssistantRuntimeID.CODEX to
            AgentBuiltInQuad(
                paletteHex = "00A67E",
                tagline = "OpenAI Codex via your Mac.",
                capabilities = macCliCapabilities,
                transport = AgentDispatchTransport.MacRelay("codex"),
            ),
        AssistantRuntimeID.OPEN_CLAW to
            AgentBuiltInQuad(
                paletteHex = "FF6B6B",
                tagline = "Local-first agent runtime. Yours by default.",
                capabilities = AgentCapabilities.FULL_CLI.union(AgentCapabilities.MEMORY).union(AgentCapabilities.MCP_UI),
                transport = AgentDispatchTransport.MacRelay("openclaw"),
            ),
        AssistantRuntimeID.DROID to
            AgentBuiltInQuad(
                paletteHex = "8B5CF6",
                tagline = "Factory Droid via your Mac.",
                capabilities = macCliCapabilities,
                transport = AgentDispatchTransport.MacRelay("droid"),
            ),
        AssistantRuntimeID.FORGE to
            AgentBuiltInQuad(
                paletteHex = "F97316",
                tagline = "Forge coding agent via your Mac.",
                capabilities = macCliCapabilities,
                transport = AgentDispatchTransport.MacRelay("forge"),
            ),
        AssistantRuntimeID.ANTIGRAVITY to
            AgentBuiltInQuad(
                paletteHex = "6C63FF",
                tagline = "Google Antigravity via your Mac.",
                capabilities = macCliCapabilities,
                transport = AgentDispatchTransport.MacRelay("antigravity"),
            ),
        AssistantRuntimeID.GROK to
            AgentBuiltInQuad(
                paletteHex = "111827",
                tagline = "Grok CLI via your Mac.",
                capabilities = macCliCapabilities,
                transport = AgentDispatchTransport.MacRelay("grok"),
            ),
        AssistantRuntimeID.CURSOR_AGENT to
            AgentBuiltInQuad(
                paletteHex = "0F172A",
                tagline = "Cursor Agent via your Mac.",
                capabilities = macCliCapabilities,
                transport = AgentDispatchTransport.MacRelay("cursorAgent"),
            ),
    )

internal fun agentBuiltInQuad(runtime: AssistantRuntimeID): AgentBuiltInQuad = builtInQuads.getValue(runtime)
