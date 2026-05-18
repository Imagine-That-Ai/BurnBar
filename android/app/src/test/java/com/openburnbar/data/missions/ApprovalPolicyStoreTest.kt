package com.openburnbar.data.missions

import android.content.Context
import android.content.SharedPreferences
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import java.util.concurrent.ConcurrentHashMap
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Pure-JVM coverage for the `ApprovalPolicyStore`. We stub
 * `SharedPreferences` with an in-memory backing map so the JSON
 * serialise / restore round-trip can run without an Android device.
 */
class ApprovalPolicyStoreTest {

    private val backing = ConcurrentHashMap<String, String?>()
    private lateinit var context: Context

    @Before
    fun setUp() {
        backing.clear()
        // Reset the volatile singleton so each test starts fresh.
        val instanceField = ApprovalPolicyStore::class.java.getDeclaredField("instance")
        instanceField.isAccessible = true
        instanceField.set(null, null)

        val editor = mockk<SharedPreferences.Editor>(relaxed = true)
        val slotKey = slot<String>()
        val slotValue = slot<String?>()
        every { editor.putString(capture(slotKey), captureNullable(slotValue)) } answers {
            backing[slotKey.captured] = slotValue.captured
            editor
        }
        every { editor.apply() } answers {}
        every { editor.commit() } returns true

        val prefs = mockk<SharedPreferences>()
        every { prefs.getString(any(), any()) } answers {
            backing.getOrDefault(firstArg<String>(), secondArg<String?>())
        }
        every { prefs.edit() } returns editor

        context = mockk(relaxed = true)
        every { context.applicationContext } returns context
        every { context.getSharedPreferences(any(), any()) } returns prefs
    }

    @Test
    fun newly_created_store_is_empty() {
        val store = ApprovalPolicyStore.shared(context)
        assertTrue(store.policies.value.isEmpty())
    }

    @Test
    fun record_and_resolve_round_trip() {
        val store = ApprovalPolicyStore.shared(context)
        val policy = ApprovalPolicy(
            id = "p-1",
            agentURI = "agent://a",
            scopeKey = "tool::ripgrep",
            missionKind = "research",
            toolName = "ripgrep",
            fileGlob = null,
            runtimeID = "claude",
            targetProject = null,
            decision = ApprovalDecision.REMEMBER_ALLOW,
            displayLabel = "Allow ripgrep",
        )
        store.record(policy)
        val resolved = store.resolve(agentURI = "agent://a", scopeKey = "tool::ripgrep")
        assertNotNull(resolved)
        assertEquals(ApprovalDecision.REMEMBER_ALLOW, resolved!!.decision)
        assertEquals(1, resolved.matchCount)
    }

    @Test
    fun resolve_returns_null_for_unknown_scope() {
        val store = ApprovalPolicyStore.shared(context)
        store.record(
            ApprovalPolicy(
                id = "p-2",
                agentURI = "agent://b",
                scopeKey = "tool::edit",
                missionKind = null,
                toolName = "edit",
                fileGlob = null,
                runtimeID = null,
                targetProject = null,
                decision = ApprovalDecision.REMEMBER_DENY,
                displayLabel = "Deny edit",
            )
        )
        assertNull(store.resolve(agentURI = "agent://b", scopeKey = "tool::diff"))
    }

    @Test
    fun expired_policy_is_skipped_on_resolve() {
        val store = ApprovalPolicyStore.shared(context)
        store.record(
            ApprovalPolicy(
                id = "p-3",
                agentURI = "agent://c",
                scopeKey = "tool::shell",
                missionKind = null,
                toolName = "shell",
                fileGlob = null,
                runtimeID = null,
                targetProject = null,
                decision = ApprovalDecision.REMEMBER_ALLOW,
                displayLabel = "Once",
                expiresAtEpoch = System.currentTimeMillis() - 1_000,
            )
        )
        assertNull(store.resolve(agentURI = "agent://c", scopeKey = "tool::shell"))
    }

    @Test
    fun remove_drops_policy() {
        val store = ApprovalPolicyStore.shared(context)
        store.record(
            ApprovalPolicy(
                id = "p-4",
                agentURI = "agent://d",
                scopeKey = "tool::yank",
                missionKind = null,
                toolName = "yank",
                fileGlob = null,
                runtimeID = null,
                targetProject = null,
                decision = ApprovalDecision.REMEMBER_ALLOW,
                displayLabel = "yank",
            )
        )
        assertEquals(1, store.policies.value.size)
        store.remove("p-4")
        assertEquals(0, store.policies.value.size)
    }

    @Test
    fun class_key_concatenates_uri_and_scope() {
        assertEquals("agent://e|tool::run", ApprovalPolicyStore.classKey("agent://e", "tool::run"))
        assertEquals("|tool::run", ApprovalPolicyStore.classKey(null, "tool::run"))
    }
}
