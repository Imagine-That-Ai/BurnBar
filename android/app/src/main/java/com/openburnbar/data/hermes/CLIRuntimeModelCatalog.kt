package com.openburnbar.data.hermes

import org.json.JSONObject

enum class CliModelSource(
    val displayLabel: String,
    val detailLabel: String,
    val showsOpenBurnBarProxyBadge: Boolean = false,
) {
    CLI_PROFILE(
        "CLI profile",
        "Uses this Mac CLI profile's subscription or auth.",
    ),
    DROID_STANDARD_QUOTA(
        "Droid Standard quota",
        "Consumes Droid Standard quota.",
    ),
    DROID_CORE_QUOTA(
        "Droid Core quota",
        "Consumes Droid Core quota.",
    ),
    DROID_CUSTOM_MODEL(
        "Droid custom model",
        "Uses a custom model configured in this Mac's Droid CLI.",
    ),
    OPENBURNBAR_PROXY(
        "OpenBurnBar proxy",
        "Uses API/OAuth through OpenBurnBar, not Droid quota.",
        showsOpenBurnBarProxyBadge = true,
    ),
    FORGE_AGENT(
        "Forge agent",
        "Runs the selected Forge agent.",
    ),
    ANTIGRAVITY_PROFILE(
        "Antigravity CLI profile",
        "Uses this Mac's Google Antigravity CLI auth and quota.",
    ),
    ANTIGRAVITY_MODEL_CATALOG(
        "Antigravity model catalog",
        "Cataloged for this Mac's Google Antigravity CLI auth and quota.",
    ),
    CLAUDE_MODEL_CATALOG(
        "Claude Code model catalog",
        "Cataloged for this Mac's Claude Code CLI auth and quota.",
    ),
    CURSOR_AGENT_PROFILE(
        "Cursor Agent CLI profile",
        "Uses this Mac's Cursor Agent CLI auth and quota.",
    ),
    CODEX_MODEL_CATALOG(
        "Codex live catalog",
        "Discovered from this Mac's Codex CLI model catalog.",
    ),
    GROK_MODEL_CATALOG(
        "Grok live catalog",
        "Discovered from this Mac's Grok Build CLI model catalog.",
    ),
    ;

    companion object {
        fun fromWire(value: String?): CliModelSource = when (value) {
            "cliProfile" -> CLI_PROFILE
            "droidStandardQuota" -> DROID_STANDARD_QUOTA
            "droidCoreQuota" -> DROID_CORE_QUOTA
            "droidCustomModel" -> DROID_CUSTOM_MODEL
            "openBurnBarProxy" -> OPENBURNBAR_PROXY
            "forgeAgent" -> FORGE_AGENT
            "antigravityProfile" -> ANTIGRAVITY_PROFILE
            "antigravityModelCatalog" -> ANTIGRAVITY_MODEL_CATALOG
            "claudeModelCatalog" -> CLAUDE_MODEL_CATALOG
            "cursorAgentProfile" -> CURSOR_AGENT_PROFILE
            "codexModelCatalog" -> CODEX_MODEL_CATALOG
            "grokModelCatalog" -> GROK_MODEL_CATALOG
            else -> CLI_PROFILE
        }
    }
}

data class CliRuntimeModelOption(
    val modelID: String,
    val displayName: String,
    val providerID: String,
    val providerName: String,
    val tier: String = "mid",
    val source: CliModelSource = CliModelSource.CLI_PROFILE,
)

data class CliRuntimeModelCatalogResponse(
    val runtime: String,
    val machineName: String?,
    val generatedAtEpochMillis: Long,
    val options: List<CliRuntimeModelOption>,
) {
    companion object {
        fun decode(raw: String): CliRuntimeModelCatalogResponse {
            val json = JSONObject(raw)
            val optionsJSON = json.optJSONArray("options")
            val rows = mutableListOf<CliRuntimeModelOption>()
            if (optionsJSON != null) {
                for (index in 0 until optionsJSON.length()) {
                    val item = optionsJSON.optJSONObject(index) ?: continue
                    rows +=
                        CliRuntimeModelOption(
                            modelID = item.optString("modelID"),
                            displayName = item.optString("displayName", item.optString("modelID")),
                            providerID = item.optString("providerID"),
                            providerName = item.optString("providerName"),
                            tier = item.optString("tier", "mid"),
                            source = CliModelSource.fromWire(item.optString("source")),
                        )
                }
            }
            return CliRuntimeModelCatalogResponse(
                runtime = json.optString("runtime"),
                machineName = json.optString("machineName").takeIf { it.isNotBlank() },
                generatedAtEpochMillis = json.optLong("generatedAtEpochMillis", 0L),
                options = rows,
            )
        }
    }
}
