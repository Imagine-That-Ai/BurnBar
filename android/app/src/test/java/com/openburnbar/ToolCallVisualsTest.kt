package com.openburnbar

import com.openburnbar.ui.hermes.ToolCallVisualKind
import com.openburnbar.ui.hermes.toolCallVisualKind
import org.junit.Assert.assertEquals
import org.junit.Test

class ToolCallVisualsTest {
    @Test
    fun canonicalMobileToolsUseCatalogCategories() {
        assertEquals(ToolCallVisualKind.OPEN, toolCallVisualKind("burnbar_atom_open"))
        assertEquals(ToolCallVisualKind.FILE, toolCallVisualKind("read_file"))
        assertEquals(ToolCallVisualKind.SEARCH, toolCallVisualKind("search"))
        assertEquals(ToolCallVisualKind.WEB, toolCallVisualKind("web_search"))
    }

    @Test
    fun streamedCliToolNamesMapToRecognizableIcons() {
        assertEquals(ToolCallVisualKind.TERMINAL, toolCallVisualKind("bash_exec"))
        assertEquals(ToolCallVisualKind.SEARCH, toolCallVisualKind("ripgrep_find"))
        assertEquals(ToolCallVisualKind.WEB, toolCallVisualKind("browser_fetch"))
        assertEquals(ToolCallVisualKind.EDIT, toolCallVisualKind("apply_patch"))
        assertEquals(ToolCallVisualKind.MEMORY, toolCallVisualKind("skill_learn"))
        assertEquals(ToolCallVisualKind.IMAGE, toolCallVisualKind("screenshot_analyze"))
        assertEquals(ToolCallVisualKind.CODE, toolCallVisualKind("compile_test"))
        assertEquals(ToolCallVisualKind.SYSTEM, toolCallVisualKind("unknown_tool"))
    }
}
