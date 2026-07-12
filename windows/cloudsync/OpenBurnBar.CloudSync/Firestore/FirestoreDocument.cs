using System;
using System.Text.Json;
using System.Text.Json.Nodes;
using OpenBurnBar.CloudSync.Json;

namespace OpenBurnBar.CloudSync.Firestore;

/// <summary>
/// A decoded Firestore REST document: its resource <see cref="Name"/>, its
/// typed-value <see cref="Fields"/>, and the server <see cref="CreateTime"/> /
/// <see cref="UpdateTime"/> timestamps. This is the shape returned by
/// <c>documents.get</c> and each <c>documents:runQuery</c> result row.
/// </summary>
public sealed class FirestoreDocument
{
    public FirestoreDocument(string name, CloudSyncFields fields, DateTimeOffset? createTime = null, DateTimeOffset? updateTime = null)
    {
        Name = name;
        Fields = fields;
        CreateTime = createTime;
        UpdateTime = updateTime;
    }

    public string Name { get; }
    public CloudSyncFields Fields { get; }
    public DateTimeOffset? CreateTime { get; }
    public DateTimeOffset? UpdateTime { get; }

    /// <summary>The document id (last path segment of <see cref="Name"/>).</summary>
    public string DocumentId => FirestoreDatabase.LeafId(Name);

    /// <summary>
    /// Serialize this document to the REST body used by <c>documents.patch</c> /
    /// create — <c>{ "name": ..., "fields": { ... } }</c>. Canonical (sorted-key)
    /// bytes so a fixture round-trip is byte-stable.
    /// </summary>
    public byte[] ToRestJsonBytes(bool includeName = true)
    {
        var obj = new JsonObject();
        if (includeName)
        {
            obj["name"] = Name;
        }
        obj["fields"] = FirestoreValueCodec.EncodeFields(Fields.Values);
        return CanonicalJson.SerializeToUtf8Bytes(obj);
    }

    /// <summary>Just the <c>{ "fields": { ... } }</c> payload (patch body without the name).</summary>
    public static byte[] FieldsRestJsonBytes(CloudSyncFields fields)
    {
        var obj = new JsonObject { ["fields"] = FirestoreValueCodec.EncodeFields(fields.Values) };
        return CanonicalJson.SerializeToUtf8Bytes(obj);
    }

    /// <summary>Parse a Firestore REST document object into a <see cref="FirestoreDocument"/>.</summary>
    public static FirestoreDocument FromRestJson(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new FormatException($"Firestore document must be an object, got {element.ValueKind}.");
        }

        string name = element.TryGetProperty("name", out JsonElement nameEl) && nameEl.ValueKind == JsonValueKind.String
            ? nameEl.GetString()!
            : string.Empty;

        CloudSyncFields fields = element.TryGetProperty("fields", out JsonElement fieldsEl)
            ? FirestoreValueCodec.DecodeFields(fieldsEl)
            : new CloudSyncFields();

        DateTimeOffset? created = ReadTime(element, "createTime");
        DateTimeOffset? updated = ReadTime(element, "updateTime");

        return new FirestoreDocument(name, fields, created, updated);
    }

    /// <summary>Parse a Firestore REST document from a raw JSON byte payload (documents.get response).</summary>
    public static FirestoreDocument FromRestJson(byte[] json)
    {
        using var document = JsonDocument.Parse(json);
        return FromRestJson(document.RootElement);
    }

    private static DateTimeOffset? ReadTime(JsonElement element, string key)
    {
        if (element.TryGetProperty(key, out JsonElement el) && el.ValueKind == JsonValueKind.String)
        {
            return FirestoreValueCodec.ParseTimestamp(el.GetString()!);
        }
        return null;
    }
}
