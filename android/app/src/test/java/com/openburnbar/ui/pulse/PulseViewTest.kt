@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.ui.pulse

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Avatar-fallback tests for `PulseView`: [avatarInitials] feeds the
 * letters-on-a-bubble fallback whenever no photo URL exists, so it must
 * extract at most two uppercase initials across spaces and hyphens and
 * degrade to null (plain bubble) instead of rendering blank text.
 */
class PulseViewTest {
    @Test
    fun `two word names produce two uppercase initials`() {
        assertEquals("AN", avatarInitials("Alberto Nunez"))
        assertEquals("AN", avatarInitials("alberto nunez"))
    }

    @Test
    fun `hyphenated names split like spaces`() {
        assertEquals("JL", avatarInitials("jean-luc picard"))
        assertEquals("MC", avatarInitials("Mary-Claire"))
    }

    @Test
    fun `long names clamp to the first two segments`() {
        assertEquals("AB", avatarInitials("Ada Byron King Lovelace"))
    }

    @Test
    fun `single names produce one initial`() {
        assertEquals("A", avatarInitials("alberto"))
    }

    @Test
    fun `unusable names fall back to null for the plain bubble`() {
        assertNull(avatarInitials(null))
        assertNull(avatarInitials(""))
        assertNull(avatarInitials("   "))
        assertNull(avatarInitials("--"))
    }

    @Test
    fun `extra separators between segments are skipped not rendered`() {
        // Consecutive separators yield empty segments with no first char.
        assertEquals("AN", avatarInitials("Alberto  Nunez"))
        assertEquals("AN", avatarInitials("Alberto - Nunez"))
    }
}
