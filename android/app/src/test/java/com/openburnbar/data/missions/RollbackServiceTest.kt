package com.openburnbar.data.missions

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-JVM coverage for `RollbackService` helper logic. The Firestore
 * snapshot listeners themselves require an emulator (covered in the
 * instrumented suite); these tests pin the JSON encoder + state machine
 * so the Mac sees byte-identical scope payloads.
 */
class RollbackServiceTest {

    @Test
    fun full_session_serialises_to_full_session_kind() {
        assertEquals("{\"kind\":\"fullSession\"}", RollbackScope.FullSession.asJson)
        assertEquals("full_session", RollbackScope.FullSession.token)
    }

    @Test
    fun last_n_includes_count() {
        val scope = RollbackScope.LastN(count = 5)
        assertEquals("{\"kind\":\"lastN\",\"count\":5}", scope.asJson)
        assertEquals("last_5", scope.token)
    }

    @Test
    fun single_file_quotes_path() {
        val scope = RollbackScope.SingleFile("/Users/me/file.swift")
        assertEquals("{\"kind\":\"singleFile\",\"path\":\"/Users/me/file.swift\"}", scope.asJson)
        assertEquals("file", scope.token)
    }

    @Test
    fun single_file_escapes_special_chars() {
        val scope = RollbackScope.SingleFile("a\"b\\c\nd")
        val asJson = scope.asJson
        assertTrue("expected escaped quote in $asJson", asJson.contains("a\\\"b"))
        assertTrue("expected escaped backslash in $asJson", asJson.contains("b\\\\c"))
        assertTrue("expected escaped newline in $asJson", asJson.contains("c\\nd"))
    }

    @Test
    fun request_status_tokens_round_trip() {
        for (status in RollbackRequest.Status.values()) {
            assertEquals(status, RollbackRequest.Status.fromToken(status.token))
        }
        assertEquals(RollbackRequest.Status.PENDING, RollbackRequest.Status.fromToken(null))
        assertEquals(RollbackRequest.Status.PENDING, RollbackRequest.Status.fromToken("unknown"))
    }

    // `RollbackService.shared()` is exercised end-to-end against a
    // Firestore emulator in the instrumented suite; calling it on the
    // JVM trips FirebaseAuth.getInstance() which isn't bootstrapped
    // here.
}
