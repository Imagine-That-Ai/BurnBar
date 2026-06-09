package com.openburnbar.data.cloud.signalsession

import java.util.UUID
import org.signal.libsignal.protocol.IdentityKey
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.InvalidKeyIdException
import org.signal.libsignal.protocol.NoSessionException
import org.signal.libsignal.protocol.ReusedBaseKeyException
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.ecc.ECPublicKey
import org.signal.libsignal.protocol.groups.state.SenderKeyRecord
import org.signal.libsignal.protocol.state.IdentityKeyStore
import org.signal.libsignal.protocol.state.KyberPreKeyRecord
import org.signal.libsignal.protocol.state.PreKeyRecord
import org.signal.libsignal.protocol.state.SessionRecord
import org.signal.libsignal.protocol.state.SignalProtocolStore
import org.signal.libsignal.protocol.state.SignedPreKeyRecord

/**
 * Durable libsignal protocol store that persists THIS device's X3DH/PQXDH + Double Ratchet
 * state for REAL Signal sessions (the device<->device transport/session path) — the Android
 * peer of the Swift `OBBSignalProtocolStore`. One class conforms to all libsignal stores
 * (identity, pre-key, signed-pre-key, kyber-pre-key, session, sender-key) so the 3-arg
 * `SessionBuilder`/`SessionCipher` constructors can be used.
 *
 * Persistence: every record is serialized and written through [SignalRecordVault] under a
 * namespaced account (`trusted-identity:`, `prekey:`, `signed-prekey:`, `kyber-prekey:`,
 * `kyber-prekey-used:`, `session:`, `senderkey:`) so the stores never collide. Identity TOFU,
 * the kyber replay-guard, and the session/identity writes run under one lock so a concurrent
 * decrypt cannot lose a write. Semantics mirror the canonical `InMemorySignalProtocolStore`.
 */
class AndroidSignalProtocolStore(
    identityKeyPair: IdentityKeyPair,
    registrationId: Int,
    private val vault: SignalRecordVault,
    private val identityTrustEvaluator: ((SignalProtocolAddress, IdentityKey) -> Boolean)? = null,
    private val allowTestingTofu: Boolean = false,
) : SignalProtocolStore {

    // Backing fields named to avoid a JVM getter clash with the interface's
    // getIdentityKeyPair()/getLocalRegistrationId() overrides below.
    private val backingIdentity: IdentityKeyPair = identityKeyPair
    private val backingRegistrationId: Int = registrationId
    private val lock = Any()

    init {
        require(identityTrustEvaluator != null || allowTestingTofu) {
            "AndroidSignalProtocolStore production initialization requires an identity trust evaluator"
        }
    }

    companion object {
        fun testingTOFU(
            identityKeyPair: IdentityKeyPair,
            registrationId: Int,
            vault: SignalRecordVault = InMemorySignalRecordVault(),
        ): AndroidSignalProtocolStore =
            AndroidSignalProtocolStore(
                identityKeyPair = identityKeyPair,
                registrationId = registrationId,
                vault = vault,
                identityTrustEvaluator = null,
                allowTestingTofu = true,
            )
    }

    // MARK: - IdentityKeyStore

    override fun getIdentityKeyPair(): IdentityKeyPair = backingIdentity

    override fun getLocalRegistrationId(): Int = backingRegistrationId

    override fun saveIdentity(
        address: SignalProtocolAddress,
        identityKey: IdentityKey,
    ): IdentityKeyStore.IdentityChange = synchronized(lock) {
        val account = identityAccount(address)
        val existing = vault.read(account)?.let { IdentityKey(it) }
        vault.write(account, identityKey.serialize())
        if (existing == null || identityKey == existing) {
            IdentityKeyStore.IdentityChange.NEW_OR_UNCHANGED
        } else {
            IdentityKeyStore.IdentityChange.REPLACED_EXISTING
        }
    }

    override fun isTrustedIdentity(
        address: SignalProtocolAddress,
        identityKey: IdentityKey,
        direction: IdentityKeyStore.Direction,
    ): Boolean = synchronized(lock) {
        identityTrustEvaluator?.let { return@synchronized it(address, identityKey) }
        val trusted = vault.read(identityAccount(address))?.let { IdentityKey(it) }
        // Trust-on-first-use: unknown peers are trusted; a changed key is rejected.
        trusted == null || trusted == identityKey
    }

    override fun getIdentity(address: SignalProtocolAddress): IdentityKey? = synchronized(lock) {
        vault.read(identityAccount(address))?.let { IdentityKey(it) }
    }

    // MARK: - PreKeyStore

    override fun loadPreKey(id: Int): PreKeyRecord = synchronized(lock) {
        val bytes = vault.read("prekey:$id") ?: throw InvalidKeyIdException("no prekey with id $id")
        PreKeyRecord(bytes)
    }

    override fun storePreKey(id: Int, record: PreKeyRecord) = synchronized(lock) {
        vault.write("prekey:$id", record.serialize())
    }

    override fun containsPreKey(id: Int): Boolean = synchronized(lock) { vault.read("prekey:$id") != null }

    override fun removePreKey(id: Int) = synchronized(lock) { vault.delete("prekey:$id") }

    // MARK: - SignedPreKeyStore

    override fun loadSignedPreKey(id: Int): SignedPreKeyRecord = synchronized(lock) {
        val bytes = vault.read("signed-prekey:$id")
            ?: throw InvalidKeyIdException("no signed prekey with id $id")
        SignedPreKeyRecord(bytes)
    }

    override fun loadSignedPreKeys(): MutableList<SignedPreKeyRecord> = synchronized(lock) {
        vault.accounts("signed-prekey:")
            .mapNotNull { vault.read(it) }
            .map { SignedPreKeyRecord(it) }
            .toMutableList()
    }

    override fun storeSignedPreKey(id: Int, record: SignedPreKeyRecord) = synchronized(lock) {
        vault.write("signed-prekey:$id", record.serialize())
    }

    override fun containsSignedPreKey(id: Int): Boolean =
        synchronized(lock) { vault.read("signed-prekey:$id") != null }

    override fun removeSignedPreKey(id: Int) = synchronized(lock) { vault.delete("signed-prekey:$id") }

    // MARK: - KyberPreKeyStore

    override fun loadKyberPreKey(id: Int): KyberPreKeyRecord = synchronized(lock) {
        val bytes = vault.read("kyber-prekey:$id")
            ?: throw InvalidKeyIdException("no kyber prekey with id $id")
        KyberPreKeyRecord(bytes)
    }

    override fun loadKyberPreKeys(): MutableList<KyberPreKeyRecord> = synchronized(lock) {
        vault.accounts("kyber-prekey:")
            .filterNot { it.startsWith("kyber-prekey-used:") }
            .mapNotNull { vault.read(it) }
            .map { KyberPreKeyRecord(it) }
            .toMutableList()
    }

    override fun storeKyberPreKey(id: Int, record: KyberPreKeyRecord) = synchronized(lock) {
        vault.write("kyber-prekey:$id", record.serialize())
    }

    override fun containsKyberPreKey(id: Int): Boolean =
        synchronized(lock) { vault.read("kyber-prekey:$id") != null }

    override fun markKyberPreKeyUsed(
        kyberPreKeyId: Int,
        signedPreKeyId: Int,
        baseKey: ECPublicKey,
    ) = synchronized(lock) {
        // Replay guard (mirrors InMemoryKyberPreKeyStore): a base key reused for the same
        // (kyber id, signed-prekey id) pair is a replay. Seen base keys persist as a
        // concatenation of fixed-size serializations; the read-modify-write runs under the lock.
        val account = "kyber-prekey-used:$kyberPreKeyId:$signedPreKeyId"
        val base = baseKey.serialize()
        val seen = vault.read(account) ?: ByteArray(0)
        val chunk = base.size
        if (chunk > 0) {
            var offset = 0
            while (offset + chunk <= seen.size) {
                if (seen.copyOfRange(offset, offset + chunk).contentEquals(base)) {
                    throw ReusedBaseKeyException()
                }
                offset += chunk
            }
        }
        vault.write(account, seen + base)
    }

    // MARK: - SessionStore

    override fun loadSession(address: SignalProtocolAddress): SessionRecord? = synchronized(lock) {
        vault.read(sessionAccount(address))?.let { SessionRecord(it) }
    }

    override fun loadExistingSessions(
        addresses: MutableList<SignalProtocolAddress>,
    ): MutableList<SessionRecord> = synchronized(lock) {
        addresses.map { address ->
            val bytes = vault.read(sessionAccount(address))
                ?: throw NoSessionException("no session for ${address.name}.${address.deviceId}")
            SessionRecord(bytes)
        }.toMutableList()
    }

    override fun getSubDeviceSessions(name: String): MutableList<Int> = synchronized(lock) {
        val prefix = "session:${escape(name)}:"
        vault.accounts(prefix)
            .mapNotNull { it.removePrefix(prefix).toIntOrNull() }
            .filter { it != 1 }
            .toMutableList()
    }

    override fun storeSession(address: SignalProtocolAddress, record: SessionRecord) = synchronized(lock) {
        vault.write(sessionAccount(address), record.serialize())
    }

    override fun containsSession(address: SignalProtocolAddress): Boolean =
        synchronized(lock) { vault.read(sessionAccount(address)) != null }

    override fun deleteSession(address: SignalProtocolAddress) =
        synchronized(lock) { vault.delete(sessionAccount(address)) }

    override fun deleteAllSessions(name: String) = synchronized(lock) {
        val prefix = "session:${escape(name)}:"
        vault.accounts(prefix).forEach { vault.delete(it) }
    }

    // MARK: - SenderKeyStore (groups — unused by 1:1 sessions, present so this is a SignalProtocolStore)

    override fun storeSenderKey(
        sender: SignalProtocolAddress,
        distributionId: UUID,
        record: SenderKeyRecord,
    ) = synchronized(lock) {
        vault.write(senderKeyAccount(sender, distributionId), record.serialize())
    }

    override fun loadSenderKey(
        sender: SignalProtocolAddress,
        distributionId: UUID,
    ): SenderKeyRecord? = synchronized(lock) {
        vault.read(senderKeyAccount(sender, distributionId))?.let { SenderKeyRecord(it) }
    }

    // MARK: - Account naming (always called while `lock` is held)

    private fun identityAccount(address: SignalProtocolAddress): String =
        "trusted-identity:${escape(address.name)}:${address.deviceId}"

    private fun sessionAccount(address: SignalProtocolAddress): String =
        "session:${escape(address.name)}:${address.deviceId}"

    private fun senderKeyAccount(sender: SignalProtocolAddress, distributionId: UUID): String =
        "senderkey:${escape(sender.name)}:${sender.deviceId}:$distributionId"

    private fun escape(name: String): String = name.replace(":", "_").replace("/", "-")
}
