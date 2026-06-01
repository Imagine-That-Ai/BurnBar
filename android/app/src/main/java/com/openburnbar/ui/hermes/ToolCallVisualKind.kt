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
    SYSTEM("System"),
}

internal fun toolCallVisualKind(name: String): ToolCallVisualKind =
    toolCallVisualKindFromCatalog(name) ?: toolCallVisualKindFromHeuristics(name)

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
