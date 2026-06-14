package com.openburnbar.data.hermes.relay

import com.google.android.gms.tasks.Tasks
import com.google.firebase.firestore.CollectionReference
import com.google.firebase.firestore.DocumentReference
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Source
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import java.util.Base64
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Unit coverage for [FirestoreIrohPairingPublicKeyProvider].
 *
 * M-006: the provider must read from the server only (`Source.SERVER`) so an
 * offline/cached public key cannot be trusted as the root of trust for the iroh
 * QUIC dial. Any Firestore failure must be surfaced as a [HermesRelayException].
 */
class FirestoreIrohPairingPublicKeyProviderTest {
    private val pairingPublicKeyBytes = ByteArray(32) { 0x11 }

    @Before
    fun stubAndroidBase64() {
        mockkStatic(android.util.Base64::class)
        every { android.util.Base64.encodeToString(any(), any()) } answers {
            Base64.getEncoder().encodeToString(firstArg<ByteArray>())
        }
        every { android.util.Base64.decode(any<String>(), any()) } answers {
            Base64.getDecoder().decode(firstArg<String>())
        }
    }

    @After
    fun restoreStaticMocks() {
        unmockkStatic(android.util.Base64::class)
    }

    private fun makeFirestore(documentRef: DocumentReference): FirebaseFirestore {
        val pairingKeysCollection = mockk<CollectionReference>(relaxed = true) {
            every { document("host") } returns documentRef
        }
        val userDocument = mockk<DocumentReference>(relaxed = true) {
            every { collection("iroh_pairing_keys") } returns pairingKeysCollection
        }
        val usersCollection = mockk<CollectionReference>(relaxed = true) {
            every { document(any()) } returns userDocument
        }
        return mockk<FirebaseFirestore>(relaxed = true) {
            every { collection("users") } returns usersCollection
        }
    }

    @Test
    fun fetchPublicKey_usesServerSourceAndReturnsDecodedKey() = runBlocking {
        val snapshot = mockk<DocumentSnapshot>(relaxed = true) {
            every { data } returns mapOf(
                "publicKeyBase64" to Base64.getEncoder().encodeToString(pairingPublicKeyBytes),
            )
        }
        val documentRef = mockk<DocumentReference>(relaxed = true) {
            every { get(Source.SERVER) } returns Tasks.forResult(snapshot)
        }
        val firestore = makeFirestore(documentRef)
        val provider = FirestoreIrohPairingPublicKeyProvider(firestore)

        val result = provider.fetchPublicKey("uid-1")

        assertTrue(result.contentEquals(pairingPublicKeyBytes))
        verify(exactly = 1) { documentRef.get(Source.SERVER) }
    }

    @Test
    fun fetchPublicKey_failsClosedWhenFirestoreThrows() {
        val documentRef = mockk<DocumentReference>(relaxed = true) {
            every { get(Source.SERVER) } returns Tasks.forException(RuntimeException("offline"))
        }
        val firestore = makeFirestore(documentRef)
        val provider = FirestoreIrohPairingPublicKeyProvider(firestore)

        assertThrows(HermesRelayException::class.java) {
            runBlocking { provider.fetchPublicKey("uid-1") }
        }
    }
}
