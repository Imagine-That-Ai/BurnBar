package com.openburnbar

import com.openburnbar.data.firebase.FirestoreValueParsers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FirestoreValueParsersTest {
    @Test
    fun `parses iso timestamp strings into millis`() {
        assertEquals(
            1778457064512L,
            FirestoreValueParsers.millis("2026-05-10T23:51:04.512Z")
        )
    }

    @Test
    fun `picks canonical projectName before legacy snake case`() {
        val data = mapOf(
            "projectName" to "canonical",
            "project_name" to "legacy"
        )

        assertEquals("canonical", FirestoreValueParsers.string(data, "projectName", "project_name"))
    }

    @Test
    fun `returns null for missing strings`() {
        assertNull(FirestoreValueParsers.string(emptyMap(), "projectName", "project_name"))
    }
}
