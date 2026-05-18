package com.openburnbar.data.hermes

/**
 * Static catalog of mobile-side tools the Android chat surface
 * advertises. Mirrors the iOS production catalog in
 * `OpenBurnBarMobile/Services/Tools/MobileToolCatalog.swift`.
 *
 * The Android catalog covers the four tools the Phase 4 spec calls out:
 *
 *  - `burnbar_atom_open` — local navigation tool dispatched through the
 *    injected [HermesAtomNavigator]. The other three are server-side
 *    tools the chat surface only needs to *render* (Hermes executes
 *    them); their entries here drive the Mercury tool-card visuals.
 *  - `read_file` — file reader (server-side).
 *  - `search` — local index search (server-side).
 *  - `web_search` — web search (server-side).
 */
object MobileToolCatalog {

    /** Canonical, ordered list of tools surfaced in the Mercury tool rail. */
    val tools: List<MobileTool> = listOf(
        MobileTool(
            id = "burnbar_atom_open",
            name = "Open in BurnBar",
            description = "Navigate the OpenBurnBar Android app to a specific surface (session, provider, project, model, window, quota, runtime).",
            icon = "open.in.new",
            categoryGroup = MobileToolCategoryGroup.SYSTEM
        ),
        MobileTool(
            id = "read_file",
            name = "Read file",
            description = "Read the contents of a file on disk and return them to Hermes.",
            icon = "doc.text",
            categoryGroup = MobileToolCategoryGroup.FILE
        ),
        MobileTool(
            id = "search",
            name = "Search local index",
            description = "Search the OpenBurnBar local conversation/code index for matching snippets.",
            icon = "magnifyingglass",
            categoryGroup = MobileToolCategoryGroup.SEARCH
        ),
        MobileTool(
            id = "web_search",
            name = "Web search",
            description = "Run an external web-search query and return summarized hits.",
            icon = "globe",
            categoryGroup = MobileToolCategoryGroup.WEB
        )
    )

    /** Look up a tool by the `tool_calls[].function.name` the model emits. */
    fun tool(name: String): MobileTool? = tools.firstOrNull { it.id == name }

    /** Group tools by capability for the Mercury tool rail. */
    fun grouped(): Map<MobileToolCategoryGroup, List<MobileTool>> =
        tools.groupBy { it.categoryGroup }

    /**
     * Dispatch a streamed tool call locally when the catalog knows how
     * to. Currently handles `burnbar_atom_open` (parses the `atom_url`
     * argument and routes through [HermesAtomNavigator]).
     *
     * Returns `true` when the call was handled locally so the chat
     * surface can mark it as `"done"` even if the Hermes backend
     * doesn't echo a follow-up.
     */
    fun dispatchLocal(
        toolName: String,
        argumentsJson: String,
        navigator: HermesAtomNavigator?
    ): Boolean {
        if (toolName != "burnbar_atom_open") return false
        val nav = navigator ?: return false
        val url = extractAtomUrl(argumentsJson) ?: return false
        val atom = HermesAtomURL.decode(url) ?: return false
        nav.open(atom)
        return true
    }

    /**
     * Pull an `atom_url` string out of a streamed tool-call arguments
     * JSON blob. Permissive — accepts either canonical JSON or the
     * partial fragments OpenAI emits during a tool-call delta.
     */
    private fun extractAtomUrl(arguments: String): String? {
        val trimmed = arguments.trim()
        if (trimmed.isEmpty()) return null
        return runCatching {
            val obj = org.json.JSONObject(trimmed)
            obj.optString("atom_url").takeIf { it.isNotEmpty() }
                ?: obj.optString("atomUrl").takeIf { it.isNotEmpty() }
                ?: obj.optString("url").takeIf { it.isNotEmpty() }
        }.getOrNull()
    }
}
