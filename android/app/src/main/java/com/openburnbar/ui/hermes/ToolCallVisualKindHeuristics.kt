package com.openburnbar.ui.hermes

internal fun toolCallVisualKindFromCatalog(name: String): ToolCallVisualKind? {
    val tool = com.openburnbar.data.hermes.MobileToolCatalog.tool(name) ?: return null
    if (tool.id == "burnbar_atom_open") return ToolCallVisualKind.OPEN
    return when (tool.categoryGroup) {
        com.openburnbar.data.hermes.MobileToolCategoryGroup.SEARCH -> ToolCallVisualKind.SEARCH
        com.openburnbar.data.hermes.MobileToolCategoryGroup.CODE -> ToolCallVisualKind.CODE
        com.openburnbar.data.hermes.MobileToolCategoryGroup.FILE -> ToolCallVisualKind.FILE
        com.openburnbar.data.hermes.MobileToolCategoryGroup.WEB -> ToolCallVisualKind.WEB
        com.openburnbar.data.hermes.MobileToolCategoryGroup.SYSTEM -> ToolCallVisualKind.SYSTEM
    }
}

private data class ToolCallHeuristicRule(val matches: (String) -> Boolean, val kind: ToolCallVisualKind)

private val toolCallHeuristicRules: List<ToolCallHeuristicRule> =
    listOf(
        ToolCallHeuristicRule({ n -> n.contains("burnbar_atom_open") || n.contains("open_in") || n.contains("open in") }, ToolCallVisualKind.OPEN),
        ToolCallHeuristicRule(
            { n -> n.contains("bash") || n.contains("exec") || n.contains("run") || n.contains("terminal") || n.contains("shell") || n.contains("command") },
            ToolCallVisualKind.TERMINAL,
        ),
        ToolCallHeuristicRule(
            { n -> n.contains("web") || n.contains("browser") || n.contains("fetch") || n.contains("http") || n.contains("url") || n.contains("link") },
            ToolCallVisualKind.WEB,
        ),
        ToolCallHeuristicRule(
            { n -> n.contains("search") || n.contains("grep") || n.contains("glob") || n.contains("find") || n.contains("query") },
            ToolCallVisualKind.SEARCH,
        ),
        ToolCallHeuristicRule({ n -> n.contains("edit") || n.contains("patch") || n.contains("replace") }, ToolCallVisualKind.EDIT),
        ToolCallHeuristicRule(
            { n -> n.contains("read") || n.contains("file") || n.contains("write") || n.contains("document") || n.contains("doc") },
            ToolCallVisualKind.FILE,
        ),
        ToolCallHeuristicRule(
            { n -> n.contains("memory") || n.contains("skill") || n.contains("learn") || n.contains("context") },
            ToolCallVisualKind.MEMORY,
        ),
        ToolCallHeuristicRule(
            { n -> n.contains("image") || n.contains("vision") || n.contains("screenshot") || n.contains("photo") },
            ToolCallVisualKind.IMAGE,
        ),
        ToolCallHeuristicRule(
            { n -> n.contains("code") || n.contains("build") || n.contains("test") || n.contains("compile") },
            ToolCallVisualKind.CODE,
        ),
    )

internal fun toolCallVisualKindFromHeuristics(name: String): ToolCallVisualKind {
    val normalized = name.lowercase()
    return toolCallHeuristicRules.firstOrNull { it.matches(normalized) }?.kind ?: ToolCallVisualKind.SYSTEM
}
