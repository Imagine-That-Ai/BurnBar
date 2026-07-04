using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Json;
using Xunit;

namespace OpenBurnBar.CloudSync.Tests;

/// <summary>
/// Proves the Firestore REST typed-value document codec: the single-key value
/// shapes (<c>stringValue</c> / <c>integerValue</c>-as-string / <c>doubleValue</c>
/// / <c>booleanValue</c> / <c>nullValue</c> / <c>timestampValue</c> /
/// <c>bytesValue</c> / <c>arrayValue.values</c> / <c>mapValue.fields</c>) both
/// round-trip and match a committed typed-value document fixture byte-for-byte
/// (after canonicalization).
/// </summary>
public sealed class FirestoreValueCodecTests
{
    private static readonly DateTimeOffset Created = new(2026, 7, 3, 10, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Integer_encodes_as_a_json_string_per_firestore_spec()
    {
        JsonNode node = FirestoreValueCodec.Encode(new CloudSyncValue.IntegerValue(42));
        Assert.Equal("42", node["integerValue"]!.GetValue<string>());
    }

    [Fact]
    public void Double_encodes_as_a_json_number()
    {
        JsonNode node = FirestoreValueCodec.Encode(new CloudSyncValue.DoubleValue(0.875));
        Assert.Equal(JsonValueKind.Number, JsonSerializer.SerializeToElement(node["doubleValue"]).ValueKind);
    }

    [Theory]
    [MemberData(nameof(RoundTripValues))]
    public void Value_round_trips_through_typed_value_json(CloudSyncValue value)
    {
        JsonNode encoded = FirestoreValueCodec.Encode(value);
        using var document = JsonDocument.Parse(encoded.ToJsonString());
        CloudSyncValue decoded = FirestoreValueCodec.Decode(document.RootElement);
        Assert.Equal(value, decoded);
    }

    public static IEnumerable<object[]> RoundTripValues() => new List<object[]>
    {
        new object[] { CloudSyncValue.NullValue.Instance },
        new object[] { new CloudSyncValue.BooleanValue(true) },
        new object[] { new CloudSyncValue.IntegerValue(9007199254740993L) }, // > 2^53, proves string encoding survives
        new object[] { new CloudSyncValue.DoubleValue(6.75) },
        new object[] { new CloudSyncValue.StringValue("hello/world") },
        new object[] { new CloudSyncValue.TimestampValue(Created) },
        new object[] { new CloudSyncValue.BytesValue(Encoding.UTF8.GetBytes("digest")) },
        new object[]
        {
            new CloudSyncValue.ArrayValue(new CloudSyncValue[]
            {
                new CloudSyncValue.StringValue("a"),
                new CloudSyncValue.IntegerValue(2),
            }),
        },
        new object[]
        {
            new CloudSyncValue.MapValue(new Dictionary<string, CloudSyncValue>
            {
                ["region"] = new CloudSyncValue.StringValue("us"),
                ["tier"] = new CloudSyncValue.IntegerValue(1),
            }),
        },
    };

    [Fact]
    public void Transform_sentinels_are_not_encodable_as_document_values()
    {
        Assert.Throws<InvalidOperationException>(() => FirestoreValueCodec.Encode(CloudSyncValue.ServerTimestamp.Instance));
        Assert.Throws<InvalidOperationException>(() => FirestoreValueCodec.Encode(CloudSyncValue.Delete.Instance));
    }

    [Fact]
    public void Document_encodes_to_the_committed_typed_value_fixture()
    {
        FirestoreDocument document = BuildProviderAccountDocument();
        byte[] actual = document.ToRestJsonBytes();

        byte[] fixture = Fixtures.ReadBytes("firestore", "provider_account_document.json");
        byte[] expected = CanonicalJson.SerializeToUtf8Bytes(JsonNode.Parse(fixture)!);

        Assert.Equal(Encoding.UTF8.GetString(expected), Encoding.UTF8.GetString(actual));
    }

    [Fact]
    public void Fixture_decodes_and_re_encodes_stably()
    {
        byte[] fixture = Fixtures.ReadBytes("firestore", "provider_account_document.json");
        FirestoreDocument parsed = FirestoreDocument.FromRestJson(fixture);

        Assert.Equal("acc-1", ((CloudSyncValue.StringValue)parsed.Fields["id"]!).Value);
        Assert.Equal(10, ((CloudSyncValue.IntegerValue)parsed.Fields["sortKey"]!).Value);
        Assert.Equal(0.875, ((CloudSyncValue.DoubleValue)parsed.Fields["score"]!).Value);
        Assert.IsType<CloudSyncValue.NullValue>(parsed.Fields["lastErrorCode"]);
        Assert.Equal(Created, ((CloudSyncValue.TimestampValue)parsed.Fields["createdAt"]!).Value);

        byte[] reEncoded = parsed.ToRestJsonBytes();
        byte[] expected = CanonicalJson.SerializeToUtf8Bytes(JsonNode.Parse(fixture)!);
        Assert.Equal(Encoding.UTF8.GetString(expected), Encoding.UTF8.GetString(reEncoded));
    }

    private static FirestoreDocument BuildProviderAccountDocument()
    {
        var fields = CloudSyncFields.From(new Dictionary<string, CloudSyncValue>
        {
            ["id"] = new CloudSyncValue.StringValue("acc-1"),
            ["sortKey"] = new CloudSyncValue.IntegerValue(10),
            ["isDefault"] = new CloudSyncValue.BooleanValue(true),
            ["score"] = new CloudSyncValue.DoubleValue(0.875),
            ["lastErrorCode"] = CloudSyncValue.NullValue.Instance,
            ["scopes"] = new CloudSyncValue.ArrayValue(new CloudSyncValue[]
            {
                new CloudSyncValue.StringValue("chat.read"),
                new CloudSyncValue.StringValue("chat.send"),
            }),
            ["connectContext"] = new CloudSyncValue.MapValue(new Dictionary<string, CloudSyncValue>
            {
                ["authMethodID"] = new CloudSyncValue.StringValue("am-1"),
                ["region"] = new CloudSyncValue.StringValue("us"),
            }),
            ["createdAt"] = new CloudSyncValue.TimestampValue(Created),
            ["digest"] = new CloudSyncValue.BytesValue(Encoding.UTF8.GetBytes("digest")),
        });

        const string name = "projects/openburnbar-demo/databases/(default)/documents/users/uid-1/provider_accounts/acc-1";
        return new FirestoreDocument(name, fields);
    }
}
