using System;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using OpenBurnBar.CloudSync.Models;

namespace OpenBurnBar.CloudSync.Security;

/// <summary>
/// Fail-closed E2EE guard for the encrypted CloudSync write path.
///
/// Parity with the macOS invariant (AgentLens/Services/CloudSync/*): message
/// bodies, titles and previews are <b>sealed before upload</b> and a read failure
/// surfaces as an error rather than "an empty-thread masquerade". Concretely, when
/// a write is declared <see cref="E2EERequirement.EncryptionRequired"/>:
/// <list type="bullet">
///   <item>the document MUST carry a sealed ciphertext envelope
///         (relay / ratchet / signal) with non-empty ciphertext, and</item>
///   <item>the document MUST NOT carry a co-present plaintext field
///         (Hermes <c>text</c>, or any field the caller names).</item>
/// </list>
/// A violation throws <see cref="CloudSyncGatewayException"/>
/// (<see cref="CloudSyncGatewayErrorKind.E2EEFailClosed"/>) — the write is refused,
/// never downgraded to plaintext.
/// </summary>
public static class E2EEWriteGuard
{
    public enum E2EERequirement
    {
        /// <summary>Metadata-only / consented plaintext path — no ciphertext demanded.</summary>
        PlaintextAllowed,

        /// <summary>Content path — ciphertext envelope required, plaintext refused.</summary>
        EncryptionRequired,
    }

    /// <summary>Guard a Hermes gateway event doc before it is written.</summary>
    public static void AssertEventSealed(FirestoreHermesGatewayEventDoc doc, E2EERequirement requirement)
    {
        if (requirement != E2EERequirement.EncryptionRequired) return;
        AssertNoPlaintext(doc.Text, "text");
        AssertSealed(
            HasSealedEnvelope(doc.RelayEnvelope, doc.RatchetEnvelope, doc.SignalEnvelope),
            "hermes gateway event");
    }

    /// <summary>Guard a Hermes gateway message doc before it is written.</summary>
    public static void AssertMessageSealed(FirestoreHermesGatewayMessageDoc doc, E2EERequirement requirement)
    {
        if (requirement != E2EERequirement.EncryptionRequired) return;
        AssertNoPlaintext(doc.Text, "text");
        AssertSealed(
            HasSealedEnvelope(doc.RelayEnvelope, doc.RatchetEnvelope, doc.SignalEnvelope),
            "hermes gateway message");
    }

    /// <summary>
    /// Generic field-level guard for the untyped gateway write path: refuse a write
    /// that carries any <paramref name="plaintextKey"/> when a ciphertext envelope
    /// field is required to be present and non-empty.
    /// </summary>
    public static void AssertFieldsSealed(
        CloudSyncFields fields,
        string plaintextKey,
        string ciphertextKey,
        E2EERequirement requirement)
    {
        if (requirement != E2EERequirement.EncryptionRequired) return;

        if (fields[plaintextKey] is CloudSyncValue.StringValue { Value.Length: > 0 })
        {
            throw FailClosed($"plaintext field '{plaintextKey}' present on an encryption-required write");
        }

        bool sealedOk = fields[ciphertextKey] switch
        {
            CloudSyncValue.StringValue s => s.Value.Length > 0,
            CloudSyncValue.MapValue m => m.Fields.Count > 0,
            CloudSyncValue.BytesValue b => b.Value.Length > 0,
            _ => false,
        };
        AssertSealed(sealedOk, $"field '{ciphertextKey}'");
    }

    /// <summary>True when at least one envelope is present with non-empty ciphertext.</summary>
    public static bool HasSealedEnvelope(
        FirestoreGatewayRelayEnvelopeDoc? relay,
        FirestoreGatewayRatchetEnvelopeDoc? ratchet,
        FirestoreGatewaySignalEnvelopeDoc? signal)
    {
        if (relay is not null && relay.PayloadCiphertext.Length > 0) return true;
        if (ratchet is not null && ratchet.CiphertextBase64.Length > 0) return true;
        if (signal is not null && signal.CiphertextLayer.PayloadCiphertextB64.Length > 0) return true;
        return false;
    }

    private static void AssertNoPlaintext(string? plaintext, string fieldName)
    {
        if (!string.IsNullOrEmpty(plaintext))
        {
            throw FailClosed($"plaintext '{fieldName}' present on an encryption-required write");
        }
    }

    private static void AssertSealed(bool sealedOk, string what)
    {
        if (!sealedOk)
        {
            throw FailClosed($"no sealed ciphertext envelope for {what}");
        }
    }

    private static CloudSyncGatewayException FailClosed(string reason) =>
        new(CloudSyncGatewayErrorKind.E2EEFailClosed,
            $"E2EE fail-closed: {reason}. Refusing to transmit.");
}
