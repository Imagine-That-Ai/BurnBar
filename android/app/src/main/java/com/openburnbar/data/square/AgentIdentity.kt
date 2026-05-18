package com.openburnbar.data.square

import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.HermesConnectionRecord

// MARK: - Agent Identity (Hermes Square §6.1)
//
// Kotlin parity for the Swift `AgentIdentity` in OpenBurnBarCore. Same
// stable URI shape (`agent://burnbar/<token>` for built-ins,
// `agent://third-party/<vendor>/<token>` for installed agents).
//
// Kept lean for Android Phase A — capability bits, dispatch transports,
// install sources, and persona slots match the iOS surface 1:1 so the
// pinned grid + brand zone + federated search work symmetrically.

enum class AgentTier(val token: String) {
    SERVICE("service"),
    SUBSCRIPTION("subscription");

    val displayLabel: String get() = when (this) {
        SERVICE -> "Service"
        SUBSCRIPTION -> "Subscription"
    }

    val inboxFolderLabel: String get() = when (this) {
        SERVICE -> "Inbox"
        SUBSCRIPTION -> "Subscriptions"
    }

    companion object {
        const val SUBSCRIPTION_MONTHLY_BUDGET = 4
        const val SUBSCRIPTION_MONTHLY_HARD_CAP = 12

        fun fromToken(value: String?): AgentTier =
            values().firstOrNull { it.token == value } ?: SERVICE
    }
}

enum class AgentAvailability(val token: String) {
    ONLINE("online"),
    OFFLINE("offline"),
    DEGRADED("degraded"),
    UNKNOWN("unknown");

    val displayLabel: String get() = when (this) {
        ONLINE -> "Online"
        OFFLINE -> "Offline"
        DEGRADED -> "Degraded"
        UNKNOWN -> "Unknown"
    }

    val isDispatchable: Boolean get() = this != OFFLINE

    companion object {
        fun fromToken(value: String?): AgentAvailability =
            values().firstOrNull { it.token == value } ?: UNKNOWN
    }
}

/** Bitmask-style capability declaration. Mirrors `AgentCapabilities` on iOS. */
data class AgentCapabilities(val rawValue: Int) {
    fun contains(other: AgentCapabilities): Boolean =
        (rawValue and other.rawValue) == other.rawValue

    fun union(other: AgentCapabilities): AgentCapabilities =
        AgentCapabilities(rawValue or other.rawValue)

    val displayPills: List<String> get() {
        val out = mutableListOf<String>()
        if (contains(TOOL_USE)) out.add("Tool use")
        if (contains(VISION)) out.add("Vision")
        if (contains(AUDIO)) out.add("Voice")
        if (contains(AGENT_LOOPS)) out.add("Agent loops")
        if (contains(FILE_EDITS)) out.add("File edits")
        if (contains(SHELL)) out.add("Shell")
        if (contains(WEB_BROWSE)) out.add("Web")
        if (contains(CODE_EXECUTION)) out.add("Code execution")
        if (contains(IMAGE_GEN)) out.add("Image gen")
        if (contains(MEMORY)) out.add("Memory")
        if (contains(STREAMING_DIFF)) out.add("Streaming diff")
        if (contains(MCP_UI)) out.add("MCP-UI")
        return out
    }

    companion object {
        val TOOL_USE       = AgentCapabilities(1 shl 0)
        val VISION         = AgentCapabilities(1 shl 1)
        val AUDIO          = AgentCapabilities(1 shl 2)
        val AGENT_LOOPS    = AgentCapabilities(1 shl 3)
        val FILE_EDITS     = AgentCapabilities(1 shl 4)
        val SHELL          = AgentCapabilities(1 shl 5)
        val WEB_BROWSE     = AgentCapabilities(1 shl 6)
        val CODE_EXECUTION = AgentCapabilities(1 shl 7)
        val IMAGE_GEN      = AgentCapabilities(1 shl 8)
        val MEMORY         = AgentCapabilities(1 shl 9)
        val STREAMING_DIFF = AgentCapabilities(1 shl 10)
        val MCP_UI         = AgentCapabilities(1 shl 11)

        val EMPTY = AgentCapabilities(0)
        val FULL_CHAT = TOOL_USE
            .union(VISION).union(AUDIO).union(IMAGE_GEN).union(MEMORY).union(MCP_UI)
        val FULL_CLI = TOOL_USE
            .union(AGENT_LOOPS).union(FILE_EDITS).union(SHELL).union(STREAMING_DIFF)
    }
}

sealed class AgentInstallSource {
    object BuiltIn : AgentInstallSource()
    data class UserInstalled(val manifestURL: String) : AgentInstallSource()
    data class SharedByTeammate(val uid: String) : AgentInstallSource()
    data class Marketplace(val catalogID: String) : AgentInstallSource()

    val displayLabel: String get() = when (this) {
        is BuiltIn -> "Built-in"
        is UserInstalled -> "User-installed"
        is SharedByTeammate -> "Shared by teammate"
        is Marketplace -> "Marketplace"
    }

    val canBeUninstalled: Boolean get() = this !is BuiltIn
}

sealed class AgentDispatchTransport {
    object NativeRelay : AgentDispatchTransport()
    data class MacRelay(val runtime: String) : AgentDispatchTransport()
    data class HttpGateway(val endpoint: String) : AgentDispatchTransport()
    data class McpServer(val url: String) : AgentDispatchTransport()

    val displayLabel: String get() = when (this) {
        is NativeRelay -> "Native relay"
        is MacRelay -> "Mac relay"
        is HttpGateway -> "HTTP gateway"
        is McpServer -> "MCP server"
    }

    val requiresMacBridge: Boolean get() = this is MacRelay
}

data class AgentRecentStats(
    val threadCount: Int = 0,
    val missionCount: Int = 0,
    val burnUSD: Double = 0.0,
    val successRate: Double = 0.0,         // 0…1
    val medianRoundtripSeconds: Double? = null,
    val windowDays: Int = 7
) {
    companion object {
        val EMPTY = AgentRecentStats()
    }
}

data class AgentPersonaModel(
    val id: String,
    val name: String,
    val description: String,
    val systemPromptAdditions: String? = null,
    val permittedTools: List<String> = emptyList(),
    val permittedFileGlobs: List<String> = emptyList(),
    val permittedShellPrefixes: List<String> = emptyList(),
    val permitShell: Boolean = true,
    val permitFileEdits: Boolean = true,
    val temperatureOverride: Double? = null,
    val preferredModel: String? = null,
    val isDefault: Boolean = false
) {
    companion object {
        val DEFAULT_PERSONA = AgentPersonaModel(
            id = "default",
            name = "Default",
            description = "Full capability. No additional constraints beyond the agent's own defaults.",
            isDefault = true
        )
        val TECH_REVIEWER = AgentPersonaModel(
            id = "tech-reviewer",
            name = "Tech Reviewer",
            description = "Read-only. Reviews code, runs grep / lsp, never edits files or executes shells.",
            permittedTools = listOf("read_file", "grep", "ls", "lsp", "tree"),
            permitShell = false,
            permitFileEdits = false
        )
        val DOC_WRITER = AgentPersonaModel(
            id = "doc-writer",
            name = "Doc Writer",
            description = "Edits docs only. Markdown, RST, and inline comments. No shell.",
            permittedTools = listOf("read_file", "edit_file", "grep", "ls"),
            permittedFileGlobs = listOf("docs/**", "**/*.md", "**/*.rst", "README*"),
            permitShell = false,
            permitFileEdits = true
        )
        val TRIAGE = AgentPersonaModel(
            id = "triage",
            name = "Triage",
            description = "Reads, classifies, and proposes. Never modifies code or state.",
            permittedTools = listOf("read_file", "grep", "ls", "lsp"),
            permittedShellPrefixes = listOf("git log", "git diff", "git blame", "gh"),
            permitShell = true,
            permitFileEdits = false
        )

        val DEFAULT_CLI_SEED_SET = listOf(DEFAULT_PERSONA, TECH_REVIEWER, DOC_WRITER, TRIAGE)
        val DEFAULT_CHAT_SEED_SET = listOf(DEFAULT_PERSONA)
    }
}

data class AgentIdentity(
    val id: String,
    val runtimeID: AssistantRuntimeID? = null,
    val displayName: String,
    val glyph: String,
    val paletteHex: String,
    val tier: AgentTier = AgentTier.SERVICE,
    val availability: AgentAvailability = AgentAvailability.UNKNOWN,
    val installSource: AgentInstallSource = AgentInstallSource.BuiltIn,
    val capabilities: AgentCapabilities = AgentCapabilities.EMPTY,
    val dispatchTransport: AgentDispatchTransport = AgentDispatchTransport.NativeRelay,
    val personas: List<AgentPersonaModel> = emptyList(),
    val lastSevenDays: AgentRecentStats? = null,
    val lastRefreshedAtEpoch: Long? = null,
    val tagline: String? = null
) {
    companion object {
        fun builtInURI(runtime: AssistantRuntimeID): String =
            "agent://burnbar/${runtime.token}"

        fun builtInRuntime(uri: String): AssistantRuntimeID? {
            val prefix = "agent://burnbar/"
            if (!uri.startsWith(prefix)) return null
            val token = uri.substring(prefix.length)
            return AssistantRuntimeID.values().firstOrNull { it.token == token }
        }

        const val PAIRED_MAC_URI_PREFIX = "device://paired-mac/"

        fun pairedMacURI(connectionID: String): String =
            "$PAIRED_MAC_URI_PREFIX$connectionID"

        fun pairedMac(connection: HermesConnectionRecord): AgentIdentity =
            AgentIdentity(
                id = pairedMacURI(connection.id),
                runtimeID = null,
                displayName = connection.displayName.ifBlank { "My Mac" },
                glyph = "🖥",
                paletteHex = "8B9DC3",
                tier = AgentTier.SERVICE,
                availability = when (connection.status.name.lowercase()) {
                    "online" -> AgentAvailability.ONLINE
                    "offline" -> AgentAvailability.OFFLINE
                    "degraded" -> AgentAvailability.DEGRADED
                    else -> AgentAvailability.UNKNOWN
                },
                installSource = AgentInstallSource.BuiltIn,
                capabilities = AgentCapabilities.EMPTY,
                dispatchTransport = AgentDispatchTransport.NativeRelay,
                personas = emptyList(),
                lastSevenDays = null,
                lastRefreshedAtEpoch = connection.lastSeenAt ?: connection.updatedAt,
                tagline = "Mirror, call, or control this Mac"
            )

        fun builtIn(
            runtime: AssistantRuntimeID,
            availability: AgentAvailability = AgentAvailability.UNKNOWN,
            lastSevenDays: AgentRecentStats? = null,
            lastRefreshedAtEpoch: Long? = null
        ): AgentIdentity {
            val (palette, tagline, capabilities, transport) = when (runtime) {
                AssistantRuntimeID.HERMES -> Quad(
                    "AEA69C",
                    "Editorial synthesis and mission triage.",
                    AgentCapabilities.FULL_CHAT,
                    AgentDispatchTransport.NativeRelay
                )
                AssistantRuntimeID.PI -> Quad(
                    "7C3AED",
                    "Conversational sidekick. Warm, fast, casual.",
                    AgentCapabilities.FULL_CHAT,
                    AgentDispatchTransport.NativeRelay
                )
                AssistantRuntimeID.CLAUDE -> Quad(
                    "CC785C",
                    "Anthropic Claude Code via your Mac.",
                    AgentCapabilities.FULL_CLI.union(AgentCapabilities.VISION).union(AgentCapabilities.MCP_UI),
                    AgentDispatchTransport.MacRelay("claude")
                )
                AssistantRuntimeID.CODEX -> Quad(
                    "00A67E",
                    "OpenAI Codex via your Mac.",
                    AgentCapabilities.FULL_CLI.union(AgentCapabilities.CODE_EXECUTION).union(AgentCapabilities.MCP_UI),
                    AgentDispatchTransport.MacRelay("codex")
                )
                AssistantRuntimeID.OPEN_CLAW -> Quad(
                    "FF6B6B",
                    "Local-first agent runtime. Yours by default.",
                    AgentCapabilities.FULL_CLI.union(AgentCapabilities.MEMORY).union(AgentCapabilities.MCP_UI),
                    AgentDispatchTransport.MacRelay("openclaw")
                )
            }
            return AgentIdentity(
                id = builtInURI(runtime),
                runtimeID = runtime,
                displayName = runtime.displayName,
                glyph = runtime.glyph,
                paletteHex = palette,
                tier = AgentTier.SERVICE,
                availability = availability,
                installSource = AgentInstallSource.BuiltIn,
                capabilities = capabilities,
                dispatchTransport = transport,
                personas = emptyList(),
                lastSevenDays = lastSevenDays,
                lastRefreshedAtEpoch = lastRefreshedAtEpoch,
                tagline = tagline
            )
        }

        val defaultBuiltIns: List<AgentIdentity> =
            AssistantRuntimeID.values().map { builtIn(it) }
    }
}

/** Local 4-tuple — Kotlin's stdlib only ships Pair / Triple. */
private data class Quad<A, B, C, D>(val a: A, val b: B, val c: C, val d: D)
