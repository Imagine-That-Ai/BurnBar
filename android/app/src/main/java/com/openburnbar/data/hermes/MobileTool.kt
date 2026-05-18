package com.openburnbar.data.hermes

/**
 * Capability bucket used by the chat surface to group tool cards in the
 * Mercury tool rail (Search / Code / File / Web / System). Mirrors the
 * grouping iOS uses inside `HermesToolCard.swift`.
 */
enum class MobileToolCategoryGroup(val displayLabel: String) {
    SEARCH("Search"),
    CODE("Code"),
    FILE("File"),
    WEB("Web"),
    SYSTEM("System")
}

/**
 * Descriptor for one mobile tool the chat surface advertises to Hermes.
 * The catalog (`MobileToolCatalog`) is the single source of truth for
 * which tools are available; each entry is a small value type so the
 * UI can render a tool card before / during / after invocation.
 *
 * Mirrors `MobileTool` (Swift protocol + descriptor) in
 * `OpenBurnBarMobile/Services/Tools/MobileToolCatalog.swift`. The
 * Android side currently only models the metadata + dispatch contract
 * for the tools the chat surface needs to render — server-side
 * execution (read_file, search, web_search) stays in the Hermes
 * backend; `burnbar_atom_open` is dispatched locally via
 * [HermesAtomNavigator].
 */
data class MobileTool(
    val id: String,
    val name: String,
    val description: String,
    /** Symbolic icon hint — UI maps to `Icons.Filled.*`. */
    val icon: String,
    val categoryGroup: MobileToolCategoryGroup
)
