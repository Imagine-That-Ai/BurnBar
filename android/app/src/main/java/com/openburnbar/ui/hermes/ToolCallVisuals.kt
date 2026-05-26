package com.openburnbar.ui.hermes

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SettingsApplications
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.ui.graphics.vector.ImageVector
import com.openburnbar.data.hermes.MobileToolCatalog
import com.openburnbar.data.hermes.MobileToolCategoryGroup

internal enum class ToolCallVisualKind(val accessibilityLabel: String) {
    OPEN("Open in BurnBar"),
    FILE("File"),
    TERMINAL("Terminal"),
    SEARCH("Search"),
    WEB("Web"),
    EDIT("Edit"),
    MEMORY("Memory"),
    IMAGE("Image"),
    CODE("Code"),
    SYSTEM("System")
}

internal fun toolCallVisualKind(name: String): ToolCallVisualKind {
    MobileToolCatalog.tool(name)?.let { tool ->
        if (tool.id == "burnbar_atom_open") return ToolCallVisualKind.OPEN
        return when (tool.categoryGroup) {
            MobileToolCategoryGroup.SEARCH -> ToolCallVisualKind.SEARCH
            MobileToolCategoryGroup.CODE -> ToolCallVisualKind.CODE
            MobileToolCategoryGroup.FILE -> ToolCallVisualKind.FILE
            MobileToolCategoryGroup.WEB -> ToolCallVisualKind.WEB
            MobileToolCategoryGroup.SYSTEM -> ToolCallVisualKind.SYSTEM
        }
    }

    val n = name.lowercase()
    return when {
        n.contains("burnbar_atom_open") || n.contains("open_in") || n.contains("open in") -> ToolCallVisualKind.OPEN
        n.contains("bash") || n.contains("exec") || n.contains("run") ||
            n.contains("terminal") || n.contains("shell") || n.contains("command") -> ToolCallVisualKind.TERMINAL
        n.contains("web") || n.contains("browser") || n.contains("fetch") ||
            n.contains("http") || n.contains("url") || n.contains("link") -> ToolCallVisualKind.WEB
        n.contains("search") || n.contains("grep") || n.contains("glob") ||
            n.contains("find") || n.contains("query") -> ToolCallVisualKind.SEARCH
        n.contains("edit") || n.contains("patch") || n.contains("replace") -> ToolCallVisualKind.EDIT
        n.contains("read") || n.contains("file") || n.contains("write") ||
            n.contains("document") || n.contains("doc") -> ToolCallVisualKind.FILE
        n.contains("memory") || n.contains("skill") || n.contains("learn") ||
            n.contains("context") -> ToolCallVisualKind.MEMORY
        n.contains("image") || n.contains("vision") || n.contains("screenshot") ||
            n.contains("photo") -> ToolCallVisualKind.IMAGE
        n.contains("code") || n.contains("build") || n.contains("test") ||
            n.contains("compile") -> ToolCallVisualKind.CODE
        else -> ToolCallVisualKind.SYSTEM
    }
}

internal fun toolCallIcon(kind: ToolCallVisualKind): ImageVector = when (kind) {
    ToolCallVisualKind.OPEN -> Icons.AutoMirrored.Filled.OpenInNew
    ToolCallVisualKind.FILE -> Icons.Filled.Description
    ToolCallVisualKind.TERMINAL -> Icons.Filled.Terminal
    ToolCallVisualKind.SEARCH -> Icons.Filled.Search
    ToolCallVisualKind.WEB -> Icons.Filled.Public
    ToolCallVisualKind.EDIT -> Icons.Filled.Edit
    ToolCallVisualKind.MEMORY -> Icons.Filled.Psychology
    ToolCallVisualKind.IMAGE -> Icons.Filled.Image
    ToolCallVisualKind.CODE -> Icons.Filled.Code
    ToolCallVisualKind.SYSTEM -> Icons.Filled.SettingsApplications
}
