package com.openburnbar.data.hermes

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
        assertEquals("Hello, Hermes.", (runs[0] as HermesAtomRun.Text).text)
    }

    @Test
    fun atom_only_yields_atom_run() {
        val runs = HermesAtomParser.parse("[Session AB12](burnbar://session?id=abcd1234)")
        assertEquals(1, runs.size)
        val atom = runs[0] as HermesAtomRun.Atom
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
        assertEquals("Open ", (runs[0] as HermesAtomRun.Text).text)
        assertEquals("your session", (runs[1] as HermesAtomRun.Atom).label)
        assertEquals(" now.", (runs[2] as HermesAtomRun.Text).text)
    }

    @Test
    fun mentions_are_atomic_and_keep_handle() {
        val runs = HermesAtomParser.parse("hey @alberto-nunez, see this")
        val mention = runs.firstOrNull { it is HermesAtomRun.Mention } as? HermesAtomRun.Mention
        assertTrue("mention should be present: $runs", mention != null)
        assertEquals("@alberto-nunez", mention!!.handle)
    }

    @Test
    fun code_spans_are_atomic() {
        val runs = HermesAtomParser.parse("call `getCwd()` here")
        val code = runs.firstOrNull { it is HermesAtomRun.Code } as? HermesAtomRun.Code
        assertTrue("code span missing: $runs", code != null)
        assertEquals("getCwd()", code!!.code)
    }

    @Test
    fun ill_formed_atom_link_falls_back_to_text() {
        val runs = HermesAtomParser.parse("[broken](not-a-scheme://x)")
        // No atom recognised → entire string stays as a text run.
        assertEquals(1, runs.size)
        assertTrue(runs[0] is HermesAtomRun.Text)
        assertEquals("[broken](not-a-scheme://x)", (runs[0] as HermesAtomRun.Text).text)
    }

    @Test
    fun cost_pattern_promotes_to_cost_atom() {
        val runs = HermesAtomParser.parse("You spent \$42.18 this week")
        val cost = runs.firstOrNull { it is HermesAtomRun.Atom } as? HermesAtomRun.Atom
        assertTrue("expected cost atom: $runs", cost?.atom is HermesAtom.Cost)
        assertEquals("\$42.18", cost!!.label)
    }

    @Test
    fun known_model_id_becomes_atom() {
        val runs = HermesAtomParser.parse("switch to claude-sonnet-4.6 please")
        val atom = runs.firstOrNull { it is HermesAtomRun.Atom } as? HermesAtomRun.Atom
        assertTrue("expected model atom: $runs", atom?.atom is HermesAtom.Model)
        assertEquals("claude-sonnet-4.6", atom!!.label)
    }

    @Test
    fun atom_empty_label_falls_back_to_atom_default_label() {
        // Label is whitespace — fallback comes from atom.fallbackLabel.
        val runs = HermesAtomParser.parse("[ ](burnbar://provider?token=anthropic)")
        val atom = runs[0] as HermesAtomRun.Atom
        assertEquals("Anthropic", atom.label)
    }
}
