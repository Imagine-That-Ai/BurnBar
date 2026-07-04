using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using OpenBurnBar.CloudSync.Models;
using OpenBurnBar.CloudSync.Security;
using Xunit;

namespace OpenBurnBar.CloudSync.Tests;

/// <summary>
/// The E2EE fail-closed guard: an encryption-required write that carries plaintext
/// or lacks a sealed ciphertext envelope is refused (throws), never downgraded.
/// </summary>
public sealed class E2EEFailClosedTests
{
    private static readonly FirestoreGatewayRelayEnvelopeDoc SealedRelay = new()
    {
        PayloadCiphertext = "Y2lwaGVy",
        WrappedKey = "d3JhcA==",
        RelayEncryption = "hpke-v3",
        RelayKeyVersion = 4,
    };

    private static readonly FirestoreGatewayRelayEnvelopeDoc EmptyRelay = new()
    {
        PayloadCiphertext = "",
        WrappedKey = "",
        RelayEncryption = "hpke-v3",
        RelayKeyVersion = 4,
    };

    private static FirestoreHermesGatewayEventDoc Event(string? text, FirestoreGatewayRelayEnvelopeDoc? relay) => new()
    {
        Id = "evt-1",
        Sequence = 1,
        Kind = "message",
        DestinationId = "dest-1",
        SenderId = "uid-1",
        Text = text,
        AttachmentIds = new List<string>(),
        RelayEnvelope = relay,
        CreatedAt = "2026-07-03T10:00:00Z",
        SchemaVersion = 1,
    };

    [Fact]
    public void Sealed_event_with_no_plaintext_passes()
    {
        E2EEWriteGuard.AssertEventSealed(Event(text: null, SealedRelay), E2EEWriteGuard.E2EERequirement.EncryptionRequired);
    }

    [Fact]
    public void Encryption_required_event_with_plaintext_fails_closed()
    {
        CloudSyncGatewayException ex = Assert.Throws<CloudSyncGatewayException>(() =>
            E2EEWriteGuard.AssertEventSealed(Event(text: "hello", SealedRelay), E2EEWriteGuard.E2EERequirement.EncryptionRequired));
        Assert.Equal(CloudSyncGatewayErrorKind.E2EEFailClosed, ex.Kind);
    }

    [Fact]
    public void Encryption_required_event_without_a_sealed_envelope_fails_closed()
    {
        CloudSyncGatewayException ex = Assert.Throws<CloudSyncGatewayException>(() =>
            E2EEWriteGuard.AssertEventSealed(Event(text: null, relay: null), E2EEWriteGuard.E2EERequirement.EncryptionRequired));
        Assert.Equal(CloudSyncGatewayErrorKind.E2EEFailClosed, ex.Kind);
    }

    [Fact]
    public void Encryption_required_event_with_empty_ciphertext_fails_closed()
    {
        Assert.Throws<CloudSyncGatewayException>(() =>
            E2EEWriteGuard.AssertEventSealed(Event(text: null, EmptyRelay), E2EEWriteGuard.E2EERequirement.EncryptionRequired));
    }

    [Fact]
    public void Plaintext_allowed_path_permits_a_metadata_only_write()
    {
        // No throw: the consented, metadata-only path does not demand ciphertext.
        E2EEWriteGuard.AssertEventSealed(Event(text: "hello", relay: null), E2EEWriteGuard.E2EERequirement.PlaintextAllowed);
    }

    [Fact]
    public void Sealed_message_passes_and_plaintext_message_fails_closed()
    {
        FirestoreHermesGatewayMessageDoc sealed_ = new()
        {
            Id = "m1",
            ClientId = "c1",
            Kind = "user",
            DestinationId = "dest-1",
            AttachmentIds = new List<string>(),
            RelayEnvelope = SealedRelay,
            CreatedAt = "2026-07-03T10:00:00Z",
            SchemaVersion = 1,
        };
        E2EEWriteGuard.AssertMessageSealed(sealed_, E2EEWriteGuard.E2EERequirement.EncryptionRequired);

        FirestoreHermesGatewayMessageDoc leaky = sealed_ with { Text = "secret" };
        Assert.Throws<CloudSyncGatewayException>(() =>
            E2EEWriteGuard.AssertMessageSealed(leaky, E2EEWriteGuard.E2EERequirement.EncryptionRequired));
    }

    [Fact]
    public void Field_level_guard_refuses_plaintext_and_requires_ciphertext()
    {
        var withPlaintext = CloudSyncFields.From(new[]
        {
            new KeyValuePair<string, CloudSyncValue>("text", new CloudSyncValue.StringValue("secret")),
            new KeyValuePair<string, CloudSyncValue>("ciphertext", new CloudSyncValue.StringValue("Y2lwaGVy")),
        });
        Assert.Throws<CloudSyncGatewayException>(() =>
            E2EEWriteGuard.AssertFieldsSealed(withPlaintext, "text", "ciphertext", E2EEWriteGuard.E2EERequirement.EncryptionRequired));

        var missingCiphertext = CloudSyncFields.From(new[]
        {
            new KeyValuePair<string, CloudSyncValue>("ciphertext", new CloudSyncValue.StringValue("")),
        });
        Assert.Throws<CloudSyncGatewayException>(() =>
            E2EEWriteGuard.AssertFieldsSealed(missingCiphertext, "text", "ciphertext", E2EEWriteGuard.E2EERequirement.EncryptionRequired));

        var sealedFields = CloudSyncFields.From(new[]
        {
            new KeyValuePair<string, CloudSyncValue>("ciphertext", new CloudSyncValue.StringValue("Y2lwaGVy")),
        });
        E2EEWriteGuard.AssertFieldsSealed(sealedFields, "text", "ciphertext", E2EEWriteGuard.E2EERequirement.EncryptionRequired);
    }
}
