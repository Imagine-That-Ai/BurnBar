package com.openburnbar.ui.pulse

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The fallback shown when a user has no avatar image.
 *
 * Pure string handling, and the only part of `UserAvatarBubble` that can be wrong
 * without being obviously wrong on screen: a blank result renders an empty circle
 * rather than falling through to the placeholder glyph.
 */
class AvatarInitialsTest {

    @Test
    fun `takes the first letter of the first two words`() {
        assertEquals("AN", avatarInitials("Alberto Nunez"))
        assertEquals("AN", avatarInitials("Alberto Nunez Garcia"))
        assertEquals("A", avatarInitials("Alberto"))
    }

    // Hyphenated names split too, so "Mary-Jane" is MJ rather than M.
    @Test
    fun `splits on hyphens as well as spaces`() {
        assertEquals("MJ", avatarInitials("Mary-Jane"))
        assertEquals("JP", avatarInitials("Jean-Pierre Dupont"))
    }

    @Test
    fun `uppercases lowercase input`() {
        assertEquals("AB", avatarInitials("alberto burnbar"))
    }

    // Every shape that must yield null rather than a blank badge.
    @Test
    fun `null blank and separator-only names produce no initials`() {
        assertNull(avatarInitials(null))
        assertNull(avatarInitials(""))
        assertNull(avatarInitials("   "))
        assertNull(avatarInitials("-"))
        assertNull(avatarInitials(" - "))
    }

    // Leading separators must not consume one of the two slots and leave a
    // single-letter badge for a two-word name.
    @Test
    fun `leading and repeated separators do not eat an initial slot`() {
        assertEquals("AN", avatarInitials("  Alberto   Nunez"))
        assertEquals("AN", avatarInitials("--Alberto--Nunez"))
    }

    @Test
    fun `non-latin names keep their first characters`() {
        assertEquals("ЛТ", avatarInitials("Лев Толстой"))
    }
}
