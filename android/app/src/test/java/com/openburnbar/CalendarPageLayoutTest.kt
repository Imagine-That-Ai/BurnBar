package com.openburnbar

import com.openburnbar.ui.calendar.CalendarCardKind
import com.openburnbar.ui.calendar.CalendarCardSpan
import com.openburnbar.ui.calendar.CalendarPageLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CalendarPageLayoutTest {

    @Test
    fun `default layout registers every card kind exactly once with its default span`() {
        val layout = CalendarPageLayout.DEFAULT
        assertEquals(CalendarCardKind.entries.toList(), layout.configs.map { it.kind })
        assertTrue(layout.hiddenConfigs.isEmpty())
        assertEquals(
            CalendarCardKind.entries.associate { it to it.defaultSpan },
            layout.configs.associate { it.kind to it.span },
        )
    }

    @Test
    fun `encode-decode round-trips order, visibility, and spans`() {
        val layout =
            CalendarPageLayout.DEFAULT
                .move(CalendarCardKind.PROJECT_FOCUS, -1)
                .setVisible(CalendarCardKind.MODEL_MIX, false)
                .setSpan(CalendarCardKind.PROVIDER_MIX, CalendarCardSpan.L)
        val decoded = CalendarPageLayout.decode(layout.encode())
        assertEquals(layout, decoded)
    }

    @Test
    fun `decode drops unknown kinds and appends missing kinds with defaults`() {
        val json =
            """
            [
              {"kind":"providerMix","isVisible":false,"span":3},
              {"kind":"notARealCard","isVisible":true,"span":2}
            ]
            """.trimIndent()
        val layout = CalendarPageLayout.decode(json)

        // Unknown kind is gone; providerMix kept its persisted state.
        assertEquals(CalendarCardKind.entries.size, layout.configs.size)
        assertTrue(layout.configs.none { it.kind.key == "notARealCard" })
        val providerMix = layout.configs.first { it.kind == CalendarCardKind.PROVIDER_MIX }
        assertEquals(false, providerMix.isVisible)
        assertEquals(CalendarCardSpan.L, providerMix.span)
        // Missing kinds appended after the persisted ones, with defaults.
        assertEquals(CalendarCardKind.PROVIDER_MIX, layout.configs.first().kind)
        assertTrue(layout.hiddenConfigs.map { it.kind } == listOf(CalendarCardKind.PROVIDER_MIX))
    }

    @Test
    fun `decode deduplicates repeated kinds keeping the first occurrence`() {
        val json =
            """
            [
              {"kind":"kpis","isVisible":false,"span":1},
              {"kind":"kpis","isVisible":true,"span":3}
            ]
            """.trimIndent()
        val layout = CalendarPageLayout.decode(json)
        val kpis = layout.configs.filter { it.kind == CalendarCardKind.KPIS }
        assertEquals(1, kpis.size)
        assertEquals(false, kpis.first().isVisible)
        assertEquals(CalendarCardSpan.S, kpis.first().span)
    }

    @Test
    fun `decode of malformed or blank JSON yields the default layout`() {
        assertEquals(CalendarPageLayout.DEFAULT, CalendarPageLayout.decode("not json"))
        assertEquals(CalendarPageLayout.DEFAULT, CalendarPageLayout.decode(""))
        assertEquals(CalendarPageLayout.DEFAULT, CalendarPageLayout.decode(null))
        assertEquals(CalendarPageLayout.DEFAULT, CalendarPageLayout.decode("{}"))
    }

    @Test
    fun `span falls back to the kind default when missing or out of range`() {
        val json =
            """
            [
              {"kind":"kpis"},
              {"kind":"providerMix","span":7}
            ]
            """.trimIndent()
        val layout = CalendarPageLayout.decode(json)
        assertEquals(
            CalendarCardKind.KPIS.defaultSpan,
            layout.configs.first { it.kind == CalendarCardKind.KPIS }.span,
        )
        assertEquals(
            CalendarCardKind.PROVIDER_MIX.defaultSpan,
            layout.configs.first { it.kind == CalendarCardKind.PROVIDER_MIX }.span,
        )
    }

    @Test
    fun `move reorders and clamps at the edges`() {
        val layout = CalendarPageLayout.DEFAULT
        val first = layout.configs.first().kind
        assertEquals(layout, layout.move(first, -1)) // already at the top

        val moved = layout.move(first, 1)
        assertNotEquals(layout, moved)
        assertEquals(first, moved.configs[1].kind)

        val last = layout.configs.last().kind
        assertEquals(layout, layout.move(last, 1)) // already at the bottom
    }

    @Test
    fun `hide and re-show keep the card in its slot`() {
        val layout = CalendarPageLayout.DEFAULT
        val hidden = layout.setVisible(CalendarCardKind.KPIS, false)
        assertEquals(listOf(CalendarCardKind.KPIS), hidden.hiddenConfigs.map { it.kind })
        // Hiding never reorders the rest.
        assertEquals(layout.configs.map { it.kind }, hidden.configs.map { it.kind })

        val shown = hidden.setVisible(CalendarCardKind.KPIS, true)
        assertEquals(layout, shown)
    }

    @Test
    fun `span cycle walks S-M-L and wraps`() {
        assertEquals(CalendarCardSpan.M, CalendarCardSpan.S.next())
        assertEquals(CalendarCardSpan.L, CalendarCardSpan.M.next())
        assertEquals(CalendarCardSpan.S, CalendarCardSpan.L.next())
    }

    @Test
    fun `reset returns the default layout`() {
        val changed =
            CalendarPageLayout.DEFAULT
                .setVisible(CalendarCardKind.KPIS, false)
                .move(CalendarCardKind.CACHE_ROI, -1)
        assertEquals(CalendarPageLayout.DEFAULT, changed.reset())
    }
}
