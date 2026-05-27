package com.openburnbar.test

import com.openburnbar.data.hermes.HermesAtomRun
import org.junit.Assert.assertTrue

fun textRun(run: HermesAtomRun): HermesAtomRun.Text {
    check(run is HermesAtomRun.Text) { "Expected Text run, got $run" }
    return run
}

fun atomRun(run: HermesAtomRun): HermesAtomRun.Atom {
    check(run is HermesAtomRun.Atom) { "Expected Atom run, got $run" }
    return run
}

fun mentionRun(runs: List<HermesAtomRun>): HermesAtomRun.Mention {
    val mention = runs.firstOrNull { it is HermesAtomRun.Mention } as? HermesAtomRun.Mention
    assertTrue("Expected mention run in $runs", mention != null)
    return requireNotNull(mention)
}

fun codeRun(runs: List<HermesAtomRun>): HermesAtomRun.Code {
    val code = runs.firstOrNull { it is HermesAtomRun.Code } as? HermesAtomRun.Code
    assertTrue("Expected code run in $runs", code != null)
    return requireNotNull(code)
}

fun atomInRuns(runs: List<HermesAtomRun>): HermesAtomRun.Atom {
    val atom = runs.firstOrNull { it is HermesAtomRun.Atom } as? HermesAtomRun.Atom
    assertTrue("Expected atom run in $runs", atom != null)
    return requireNotNull(atom)
}
