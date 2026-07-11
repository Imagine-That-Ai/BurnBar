using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using OpenBurnBar.App.Presentation.Memories;
using OpenBurnBar.CloudSync.Crypto;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// Seal/open <c>users/{uid}/memory_facts</c> documents — parity with Swift
/// <c>KnowledgeSyncService.encodeMemoryFact</c> + <c>MemoryCloudFactPayload</c>.
/// </summary>
public static class MemoryCloudFactCodec
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static string MemoryFactDocId(string memoryId, byte[] vaultKey) =>
        CloudVaultCrypto.PensieveSlugHmac($"memory-fact:{memoryId}", vaultKey);

    public static (string DocId, CloudSyncFields Data) EncodeFact(
        Memory memory,
        string body,
        string uid,
        byte[] vaultKey,
        DateTimeOffset now)
    {
        string docId = MemoryFactDocId(memory.Id, vaultKey);
        var aad = new CloudVaultAadContext(uid, "memory_facts", docId, "sealedMemory");
        var payload = new MemoryCloudFactPayload(
            SchemaVersion: 1,
            MemoryId: memory.Id,
            Text: body,
            Kind: memory.Kind.RawValue(),
            Scope: memory.Scope,
            Confidence: memory.Confidence,
            Citations: memory.Citations,
            ValidFrom: memory.ValidFrom,
            UpdatedAt: memory.UpdatedAt);

        byte[] payloadBytes = JsonSerializer.SerializeToUtf8Bytes(payload, JsonOptions);
        CloudVaultBlobEnvelope sealedEnvelope = CloudVaultCrypto.SealBlob(payloadBytes, vaultKey, aadContext: aad);

        var fields = new Dictionary<string, CloudSyncValue>(StringComparer.Ordinal)
        {
            ["uid"] = CloudSyncValue.Of(uid),
            ["docID"] = CloudSyncValue.Of(docId),
            ["schemaVersion"] = CloudSyncValue.Of(1),
            ["kind"] = CloudSyncValue.Of(memory.Kind.RawValue()),
            ["reviewStatus"] = CloudSyncValue.Of(memory.ReviewStatus.RawValue()),
            ["sourceKind"] = CloudSyncValue.Of("chat"),
            ["sealedMemory"] = BlobEnvelopeToMap(sealedEnvelope),
            ["citationCount"] = CloudSyncValue.Of(Math.Min(memory.Citations.Count, 50)),
            ["validFrom"] = CloudSyncValue.Of(memory.ValidFrom),
            ["updatedAt"] = CloudSyncValue.Of(memory.UpdatedAt),
            ["replicatedAt"] = CloudSyncValue.Of(now),
        };

        return (docId, new CloudSyncFields(fields));
    }

    public static Memory DecodeAuthority(MemoryCloudFactPayload payload, MemoryReviewStatus reviewStatus, DateTimeOffset createdAt)
    {
        MemoryKind kind = ParseKind(payload.Kind);
        return new Memory(
            Id: payload.MemoryId,
            Kind: kind,
            Scope: payload.Scope,
            Confidence: payload.Confidence,
            BodyRedacted: "[sealed]",
            ReviewStatus: reviewStatus,
            Citations: payload.Citations,
            ValidFrom: payload.ValidFrom,
            CreatedAt: createdAt,
            UpdatedAt: payload.UpdatedAt);
    }

    public static MemoryCloudFactPayload OpenPayload(
        CloudSyncFields doc,
        string uid,
        string docId,
        byte[] vaultKey)
    {
        CloudVaultBlobEnvelope envelope = MapToBlobEnvelope(RequireMap(doc, "sealedMemory"));
        var aad = new CloudVaultAadContext(uid, "memory_facts", docId, "sealedMemory");
        byte[] plaintext = CloudVaultCrypto.OpenBlob(envelope, vaultKey, aad);
        return JsonSerializer.Deserialize<MemoryCloudFactPayload>(plaintext, JsonOptions)
               ?? throw new InvalidOperationException("memory_facts payload JSON was empty.");
    }

    private static CloudSyncValue.MapValue BlobEnvelopeToMap(CloudVaultBlobEnvelope envelope)
    {
        var fields = new Dictionary<string, CloudSyncValue>(StringComparer.Ordinal)
        {
            ["schemaVersion"] = CloudSyncValue.Of(envelope.SchemaVersion),
            ["algorithm"] = CloudSyncValue.Of(envelope.Algorithm),
            ["keyVersion"] = CloudSyncValue.Of(envelope.KeyVersion),
            ["sealedBoxBase64"] = CloudSyncValue.Of(envelope.SealedBoxBase64),
        };
        if (envelope.PlaintextHmac is not null)
        {
            fields["plaintextHMAC"] = CloudSyncValue.Of(envelope.PlaintextHmac);
        }

        if (envelope.IntegrityHashVersion is not null)
        {
            fields["integrityHashVersion"] = CloudSyncValue.Of(envelope.IntegrityHashVersion.Value);
        }

        if (envelope.Aad is not null)
        {
            fields["aad"] = CloudSyncValue.Of(envelope.Aad);
        }

        return new CloudSyncValue.MapValue(fields);
    }

    private static CloudVaultBlobEnvelope MapToBlobEnvelope(CloudSyncValue.MapValue map)
    {
        IReadOnlyDictionary<string, CloudSyncValue> f = map.Fields;
        return new CloudVaultBlobEnvelope(
            SchemaVersion: ReadInt(f, "schemaVersion"),
            Algorithm: ReadString(f, "algorithm"),
            KeyVersion: ReadInt(f, "keyVersion"),
            PlaintextSha256: TryString(f, "plaintextSHA256"),
            PlaintextHmac: TryString(f, "plaintextHMAC"),
            IntegrityHashVersion: TryInt(f, "integrityHashVersion"),
            SealedBoxBase64: ReadString(f, "sealedBoxBase64"),
            Aad: TryString(f, "aad"));
    }

    private static CloudSyncValue.MapValue RequireMap(CloudSyncFields doc, string key)
    {
        if (!doc.Values.TryGetValue(key, out CloudSyncValue? value) || value is not CloudSyncValue.MapValue map)
        {
            throw new InvalidOperationException($"memory_facts document missing `{key}` map.");
        }

        return map;
    }

    private static MemoryKind ParseKind(string raw) => raw switch
    {
        "fact" => MemoryKind.Fact,
        "preference" => MemoryKind.Preference,
        "event" => MemoryKind.Event,
        "profile" => MemoryKind.Profile,
        "relationship" => MemoryKind.Relationship,
        _ => MemoryKind.Other,
    };

    public static MemoryReviewStatus ParseReviewStatus(string? raw) => raw switch
    {
        "approved" => MemoryReviewStatus.Approved,
        "rejected" => MemoryReviewStatus.Rejected,
        _ => MemoryReviewStatus.Quarantined,
    };

    private static string ReadString(IReadOnlyDictionary<string, CloudSyncValue> f, string key) =>
        f[key] is CloudSyncValue.StringValue s ? s.Value : throw new FormatException(key);

    private static int ReadInt(IReadOnlyDictionary<string, CloudSyncValue> f, string key) =>
        f[key] switch
        {
            CloudSyncValue.IntegerValue i => checked((int)i.Value),
            CloudSyncValue.DoubleValue d => (int)d.Value,
            _ => throw new FormatException(key),
        };

    private static string? TryString(IReadOnlyDictionary<string, CloudSyncValue> f, string key) =>
        f.TryGetValue(key, out CloudSyncValue? v) && v is CloudSyncValue.StringValue s ? s.Value : null;

    private static int? TryInt(IReadOnlyDictionary<string, CloudSyncValue> f, string key) =>
        f.TryGetValue(key, out CloudSyncValue? v) ? v switch
        {
            CloudSyncValue.IntegerValue i => checked((int)i.Value),
            CloudSyncValue.DoubleValue d => (int)d.Value,
            _ => (int?)null,
        } : null;
}

public sealed record MemoryCloudFactPayload(
    int SchemaVersion,
    string MemoryId,
    string Text,
    string Kind,
    MemoryScope Scope,
    double Confidence,
    IReadOnlyList<MemoryCitation> Citations,
    DateTimeOffset ValidFrom,
    DateTimeOffset UpdatedAt);