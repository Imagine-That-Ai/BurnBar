@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.data.hermes

import com.openburnbar.test.atomInRuns
import com.openburnbar.test.atomRun
import com.openburnbar.test.codeRun
import com.openburnbar.test.mentionRun
import com.openburnbar.test.textRun
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Parity fixtures for `HermesAtomParser`. Each input string mirrors a
 * fixture the iOS suite (`HermesAtomParserTests.swift`) exercises so a
 * regression on one platform surfaces on the other.
 */
class HermesAtomParserTest {
    @Test
    fun plain_text_collapses_to_single_run() {
        val runs = HermesAtomParser.parse("Hello, Hermes.")
        assertEquals(1, runs.size)
        assertTrue(runs[0] is HermesAtomRun.Text)
        assertEquals("Hello, Hermes.", textRun(runs[0]).text)
    }

    @Test
    fun atom_only_yields_atom_run() {
        val runs = HermesAtomParser.parse("[Session AB12](burnbar://session?id=abcd1234)")
        assertEquals(1, runs.size)
        val atom = atomRun(runs[0])
        assertEquals(HermesAtomKind.SESSION, atom.atom.kind)
        assertEquals("Session AB12", atom.label)
    }

    @Test
    fun mixed_atom_and_text_segments() {
        val runs = HermesAtomParser.parse("Open [your session](burnbar://session?id=zzz) now.")
        assertEquals(3, runs.size)
        assertTrue(runs[0] is HermesAtomRun.Text)
        assertTrue(runs[1] is HermesAtomRun.Atom)
        assertTrue(runs[2] is HermesAtomRun.Text)
        assertEquals("Open ", textRun(runs[0]).text)
        assertEquals("your session", atomRun(runs[1]).label)
        assertEquals(" now.", textRun(runs[2]).text)
    }

    @Test
    fun mentions_are_atomic_and_keep_handle() {
        val runs = HermesAtomParser.parse("hey @alberto-nunez, see this")
        val mention = mentionRun(runs)
        assertEquals("@alberto-nunez", mention.handle)
    }

    @Test
    fun code_spans_are_atomic() {
        val runs = HermesAtomParser.parse("call `getCwd()` here")
        val code = codeRun(runs)
        assertEquals("getCwd()", code.code)
    }

    @Test
    fun ill_formed_atom_link_falls_back_to_text() {
        val runs = HermesAtomParser.parse("[broken](not-a-scheme://x)")
        // No atom recognised → entire string stays as a text run.
        assertEquals(1, runs.size)
        assertTrue(runs[0] is HermesAtomRun.Text)
        assertEquals("[broken](not-a-scheme://x)", textRun(runs[0]).text)
    }

    @Test
    fun cost_pattern_promotes_to_cost_atom() {
        val runs = HermesAtomParser.parse("You spent \$42.18 this week")
        val cost = atomInRuns(runs)
        assertTrue("expected cost atom: $runs", cost.atom is HermesAtom.Cost)
        assertEquals("\$42.18", cost.label)
    }

    @Test
    fun known_model_id_becomes_atom() {
        val runs = HermesAtomParser.parse("switch to claude-sonnet-4.6 please")
        val atom = atomInRuns(runs)
        assertTrue("expected model atom: $runs", atom.atom is HermesAtom.Model)
        assertEquals("claude-sonnet-4.6", atom.label)
    }

    @Test
    fun atom_empty_label_falls_back_to_atom_default_label() {
        // Label is whitespace — fallback comes from atom.fallbackLabel.
        val runs = HermesAtomParser.parse("[ ](burnbar://provider?token=anthropic)")
        val atom = atomRun(runs[0])
        assertEquals("Anthropic", atom.label)
    }
}
