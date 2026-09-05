using System.Globalization;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Presentation.Memories;
using OpenBurnBar.CloudSync.Crypto;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using Xunit;

namespace OpenBurnBar.App.CloudSync.Tests;

public sealed class CloudSyncMemoryRoundTripTests
{
    private const string Uid = "user_test_1";

    [Fact]
    public async Task FakeGateway_MemoryFact_SealDecodeAndOpenBody_RoundTrips()
    {
        byte[] vaultKey = CloudVaultCrypto.GenerateVaultKey();
        var gateway = new FakeCloudSyncGateway();
        var store = new CloudSyncMemoryStore(gateway, Uid, vaultKey);

        var now = DateTimeOffset.Parse("2026-07-04T12:00:00Z", CultureInfo.InvariantCulture);
        var memory = new Memory(
            Id: "mem_alpha",
            Kind: MemoryKind.Fact,
            Scope: new MemoryScope(UserId: Uid),
            Confidence: 0.92,
            BodyRedacted: "[sealed]",
            ReviewStatus: MemoryReviewStatus.Approved,
            Citations: Array.Empty<MemoryCitation>(),
            ValidFrom: now.AddDays(-1),
            CreatedAt: now.AddDays(-1),
            UpdatedAt: now,
            SourceKind: MemorySourceKind.Chat);

        (string docId, CloudSyncFields fields) = MemoryCloudFactCodec.EncodeFact(
            memory,
            "The user prefers dark mode in the IDE.",
            Uid,
            vaultKey,
            now);

        string path = $"{store.CollectionPath}/{docId}";
        gateway.SetDocumentData(fields, path);

        MemoryPage page = await store.LoadPageAsync(
            new MemoryPageRequest(new MemoryScope(), IncludeQuarantined: true));
        Assert.Single(page.Items);
        Assert.Equal("mem_alpha", page.Items[0].Id);
        Assert.Equal(MemoryReviewStatus.Approved, page.Items[0].ReviewStatus);

        string? body = await store.OpenBodyAsync("mem_alpha");
        Assert.Equal("The user prefers dark mode in the IDE.", body);

        await Assert.ThrowsAsync<MemoryReviewMacOnlyException>(() =>
            store.SetStatusAsync("mem_alpha", MemoryReviewStatus.Rejected));
    }

    [Fact]
    public void DecodeAuthority_ToleratesUnknownMember()
    {
        // P3 / A1(i): unknown payload members at schemaVersion 2 must be tolerated by the deserializer.
        const string json = """
        {
            "schemaVersion": 2,
            "memoryID": "mem_unknown_prop",
            "text": "Known field text.",
            "kind": "fact",
            "scope": { "userId": "user_test_1" },
            "confidence": 0.88,
            "citations": [],
            "validFrom": "2026-09-05T00:00:00Z",
            "updatedAt": "2026-09-05T00:00:00Z",
            "futureField": "unrecognized_value",
            "futureNumber": 12345
        }
        """;

        var payload = System.Text.Json.JsonSerializer.Deserialize<MemoryCloudFactPayload>(
            json,
            new System.Text.Json.JsonSerializerOptions
            {
                PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase,
                PropertyNameCaseInsensitive = true,
                DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
            });

        Assert.NotNull(payload);
        Assert.Equal("mem_unknown_prop", payload.MemoryId);
        Assert.Equal("Known field text.", payload.Text);
        Assert.Equal("fact", payload.Kind);
        Assert.Equal(0.88, payload.Confidence);

        var createdAt = DateTimeOffset.Parse("2026-09-05T00:00:00Z", CultureInfo.InvariantCulture);
        Memory memory = MemoryCloudFactCodec.DecodeAuthority(payload, MemoryReviewStatus.Approved, createdAt);

        Assert.Equal("mem_unknown_prop", memory.Id);
        Assert.Equal(MemoryKind.Fact, memory.Kind);
        Assert.Equal(MemoryReviewStatus.Approved, memory.ReviewStatus);
        Assert.Equal(0.88, memory.Confidence);
    }

    [Fact]
    public void EncodeFact_WritesSchemaVersionTwoWithEveryV2Field()
    {
        byte[] vaultKey = CloudVaultCrypto.GenerateVaultKey();
        var now = DateTimeOffset.Parse("2026-09-05T12:00:00Z", CultureInfo.InvariantCulture);
        var validFrom = now.AddDays(-2);
        var validTo = now.AddHours(2);
        var memory = new Memory(
            Id: "mem_full_v2_001",
            Kind: MemoryKind.Fact,
            Scope: new MemoryScope(UserId: Uid, ProjectId: "proj_burnbar"),
            Confidence: 0.95,
            BodyRedacted: "[sealed]",
            ReviewStatus: MemoryReviewStatus.Approved,
            Citations: Array.Empty<MemoryCitation>(),
            ValidFrom: validFrom,
            CreatedAt: validFrom,
            UpdatedAt: now,
            SourceKind: MemorySourceKind.Chat,
            ValidTo: validTo,
            SupersededBy: "mem_superseded_target_002");

        var tags = new[] { "architecture", "v2-sync" };
        const string bodyHash = "112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00";
        const string projectId = "proj_burnbar_windows";
        const string engineScope = "project";
        const string previousBodyHash = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899";
        const string writerDevice = "device_win_box_01";

        (string docId, CloudSyncFields fields) = MemoryCloudFactCodec.EncodeFact(
            memory: memory,
            body: "Architectural invariants must be preserved at v2.",
            uid: Uid,
            vaultKey: vaultKey,
            now: now,
            documentIdentity: "mem_full_v2_001",
            tags: tags,
            bodyHash: bodyHash,
            projectId: projectId,
            engineScope: engineScope,
            previousBodyHash: previousBodyHash,
            writerDevice: writerDevice);

        Assert.NotNull(docId);
        Assert.NotNull(fields);

        // Open the payload from the sealed envelope to verify v2 fields inside ciphertext
        MemoryCloudFactPayload opened = MemoryCloudFactCodec.OpenPayload(fields, Uid, docId, vaultKey);

        Assert.Equal(2, opened.SchemaVersion);
        Assert.Equal("mem_full_v2_001", opened.MemoryId);
        Assert.Equal("Architectural invariants must be preserved at v2.", opened.Text);
        Assert.Equal("fact", opened.Kind);
        Assert.Equal(0.95, opened.Confidence);
        Assert.Equal(validFrom, opened.ValidFrom);
        Assert.Equal(now, opened.UpdatedAt);
        Assert.Equal(validTo, opened.ValidTo);
        Assert.Equal("mem_superseded_target_002", opened.SupersededBy);
        Assert.Equal(tags, opened.Tags);
        Assert.Equal(bodyHash, opened.BodyHash);
        Assert.Equal(projectId, opened.ProjectId);
        Assert.Equal(engineScope, opened.EngineScope);
        Assert.Equal(previousBodyHash, opened.PreviousBodyHash);
        Assert.Equal(writerDevice, opened.WriterDevice);
    }

    [Fact]
    public void EncodeFact_RefusesRepositoryKnowledge()
    {
        // Repository knowledge never leaves the device on any platform. Windows has no
        // engine-mirrored kind to relabel it as, so the codec must refuse outright.
        byte[] vaultKey = CloudVaultCrypto.GenerateVaultKey();
        var now = DateTimeOffset.Parse("2026-09-05T12:00:00Z", CultureInfo.InvariantCulture);
        var memory = new Memory(
            Id: "mem_code_kind_001",
            Kind: MemoryKind.Fact,
            Scope: new MemoryScope(UserId: Uid, ProjectId: "proj_burnbar"),
            Confidence: 0.9,
            BodyRedacted: "[sealed]",
            ReviewStatus: MemoryReviewStatus.Approved,
            Citations: Array.Empty<MemoryCitation>(),
            ValidFrom: now.AddDays(-1),
            CreatedAt: now.AddDays(-1),
            UpdatedAt: now,
            SourceKind: MemorySourceKind.Code);

        var error = Assert.Throws<ArgumentException>(() => MemoryCloudFactCodec.EncodeFact(
            memory: memory,
            body: "internal repository knowledge",
            uid: Uid,
            vaultKey: vaultKey,
            now: now));
        Assert.Contains("never leaves the device", error.Message);
    }

    [Fact]
    public void DecodeAuthority_PreservesValidToAndSupersededBy()
    {
        var validFrom = DateTimeOffset.Parse("2026-09-01T00:00:00Z", CultureInfo.InvariantCulture);
        var updatedAt = DateTimeOffset.Parse("2026-09-05T00:00:00Z", CultureInfo.InvariantCulture);
        var validTo = DateTimeOffset.Parse("2026-09-05T10:00:00Z", CultureInfo.InvariantCulture);
        var createdAt = DateTimeOffset.Parse("2026-09-01T00:00:00Z", CultureInfo.InvariantCulture);

        var payload = new MemoryCloudFactPayload(
            SchemaVersion: 2,
            MemoryId: "mem_retired_authority_test",
            Text: "Outdated fact that was superseded.",
            Kind: "fact",
            Scope: new MemoryScope(UserId: Uid),
            Confidence: 0.90,
            Citations: Array.Empty<MemoryCitation>(),
            ValidFrom: validFrom,
            UpdatedAt: updatedAt,
            ValidTo: validTo,
            SupersededBy: "mem_newer_fact_replacement",
            Tags: new[] { "legacy" },
            BodyHash: "hash123",
            ProjectId: "proj_1",
            EngineScope: "project",
            PreviousBodyHash: "prev123",
            WriterDevice: "device_mac_1");

        Memory authority = MemoryCloudFactCodec.DecodeAuthority(payload, MemoryReviewStatus.Approved, createdAt);

        Assert.Equal("mem_retired_authority_test", authority.Id);
        Assert.Equal(MemoryKind.Fact, authority.Kind);
        Assert.Equal(MemoryReviewStatus.Approved, authority.ReviewStatus);
        Assert.Equal(validTo, authority.ValidTo);
        Assert.Equal("mem_newer_fact_replacement", authority.SupersededBy);
    }

    [Fact]
    public void Decode_ARetiredSwiftSealedFixture_MaterialisesAsRetired()
    {
        // P9: A Windows device opening a v2 retired Mac fact materialises it as retired.
        string fixturePath = Path.Combine(AppContext.BaseDirectory, "Fixtures", "swift-sealed-v2-retired-fact.json");
        if (!File.Exists(fixturePath))
        {
            fixturePath = Path.Combine(Directory.GetCurrentDirectory(), "Fixtures", "swift-sealed-v2-retired-fact.json");
        }
        if (!File.Exists(fixturePath))
        {
            fixturePath = Path.GetFullPath("windows/tests/cloudsync-app/Fixtures/swift-sealed-v2-retired-fact.json");
        }

        string fixtureJson = File.ReadAllText(fixturePath);
        using var doc = System.Text.Json.JsonDocument.Parse(fixtureJson);
        var root = doc.RootElement;

        string uid = root.GetProperty("uid").GetString()!;
        string docId = root.GetProperty("docID").GetString()!;
        string vaultKeyHex = root.GetProperty("vaultKeyHex").GetString()!;
        byte[] vaultKey = Convert.FromHexString(vaultKeyHex);

        var dataElem = root.GetProperty("data");
        var sealedMemElem = dataElem.GetProperty("sealedMemory");

        var sealedFields = new Dictionary<string, CloudSyncValue>(StringComparer.Ordinal)
        {
            ["schemaVersion"] = CloudSyncValue.Of(sealedMemElem.GetProperty("schemaVersion").GetInt32()),
            ["algorithm"] = CloudSyncValue.Of(sealedMemElem.GetProperty("algorithm").GetString()!),
            ["keyVersion"] = CloudSyncValue.Of(sealedMemElem.GetProperty("keyVersion").GetInt32()),
            ["sealedBoxBase64"] = CloudSyncValue.Of(sealedMemElem.GetProperty("sealedBoxBase64").GetString()!),
            ["plaintextHMAC"] = CloudSyncValue.Of(sealedMemElem.GetProperty("plaintextHMAC").GetString()!),
            ["integrityHashVersion"] = CloudSyncValue.Of(sealedMemElem.GetProperty("integrityHashVersion").GetInt32()),
            ["aad"] = CloudSyncValue.Of(sealedMemElem.GetProperty("aad").GetString()!),
        };

        var docFields = new Dictionary<string, CloudSyncValue>(StringComparer.Ordinal)
        {
            ["uid"] = CloudSyncValue.Of(uid),
            ["docID"] = CloudSyncValue.Of(docId),
            ["schemaVersion"] = CloudSyncValue.Of(dataElem.GetProperty("schemaVersion").GetInt32()),
            ["kind"] = CloudSyncValue.Of(dataElem.GetProperty("kind").GetString()!),
            ["reviewStatus"] = CloudSyncValue.Of(dataElem.GetProperty("reviewStatus").GetString()!),
            ["sourceKind"] = CloudSyncValue.Of(dataElem.GetProperty("sourceKind").GetString()!),
            ["sealedMemory"] = new CloudSyncValue.MapValue(sealedFields),
            ["citationCount"] = CloudSyncValue.Of(dataElem.GetProperty("citationCount").GetInt32()),
            ["validFrom"] = CloudSyncValue.Of(DateTimeOffset.Parse(dataElem.GetProperty("validFrom").GetString()!, CultureInfo.InvariantCulture)),
            ["updatedAt"] = CloudSyncValue.Of(DateTimeOffset.Parse(dataElem.GetProperty("updatedAt").GetString()!, CultureInfo.InvariantCulture)),
            ["replicatedAt"] = CloudSyncValue.Of(DateTimeOffset.Parse(dataElem.GetProperty("replicatedAt").GetString()!, CultureInfo.InvariantCulture)),
        };

        var cloudSyncFields = new CloudSyncFields(docFields);

        // Open payload
        MemoryCloudFactPayload payload = MemoryCloudFactCodec.OpenPayload(cloudSyncFields, uid, docId, vaultKey);

        Assert.Equal(2, payload.SchemaVersion);
        Assert.NotNull(payload.ValidTo);
        Assert.NotNull(payload.SupersededBy);

        // Decode authority
        var createdAt = DateTimeOffset.Parse(dataElem.GetProperty("validFrom").GetString()!, CultureInfo.InvariantCulture);
        Memory memory = MemoryCloudFactCodec.DecodeAuthority(payload, MemoryReviewStatus.Approved, createdAt);

        // Assert: Materialises as RETIRED on Windows!
        Assert.NotNull(memory.ValidTo);
        Assert.Equal(DateTimeOffset.Parse("2026-09-05T14:30:00.000Z", CultureInfo.InvariantCulture), memory.ValidTo);
        Assert.Equal("mem_swift_replacement_fact_002", memory.SupersededBy);
    }

    [Fact]
    public void RoundTrip_SwiftSealedFixture_MatchesFieldForField()
    {
        string fixturePath = Path.Combine(AppContext.BaseDirectory, "Fixtures", "swift-sealed-v2-retired-fact.json");
        if (!File.Exists(fixturePath))
        {
            fixturePath = Path.Combine(Directory.GetCurrentDirectory(), "Fixtures", "swift-sealed-v2-retired-fact.json");
        }
        if (!File.Exists(fixturePath))
        {
            fixturePath = Path.GetFullPath("windows/tests/cloudsync-app/Fixtures/swift-sealed-v2-retired-fact.json");
        }

        string fixtureJson = File.ReadAllText(fixturePath);
        using var doc = System.Text.Json.JsonDocument.Parse(fixtureJson);
        var root = doc.RootElement;

        string uid = root.GetProperty("uid").GetString()!;
        string docId = root.GetProperty("docID").GetString()!;
        byte[] vaultKey = Convert.FromHexString(root.GetProperty("vaultKeyHex").GetString()!);

        var dataElem = root.GetProperty("data");
        var sealedMemElem = dataElem.GetProperty("sealedMemory");

        var sealedFields = new Dictionary<string, CloudSyncValue>(StringComparer.Ordinal)
        {
            ["schemaVersion"] = CloudSyncValue.Of(sealedMemElem.GetProperty("schemaVersion").GetInt32()),
            ["algorithm"] = CloudSyncValue.Of(sealedMemElem.GetProperty("algorithm").GetString()!),
            ["keyVersion"] = CloudSyncValue.Of(sealedMemElem.GetProperty("keyVersion").GetInt32()),
            ["sealedBoxBase64"] = CloudSyncValue.Of(sealedMemElem.GetProperty("sealedBoxBase64").GetString()!),
            ["plaintextHMAC"] = CloudSyncValue.Of(sealedMemElem.GetProperty("plaintextHMAC").GetString()!),
            ["integrityHashVersion"] = CloudSyncValue.Of(sealedMemElem.GetProperty("integrityHashVersion").GetInt32()),
            ["aad"] = CloudSyncValue.Of(sealedMemElem.GetProperty("aad").GetString()!),
        };

        var docFields = new Dictionary<string, CloudSyncValue>(StringComparer.Ordinal)
        {
            ["uid"] = CloudSyncValue.Of(uid),
            ["docID"] = CloudSyncValue.Of(docId),
            ["schemaVersion"] = CloudSyncValue.Of(dataElem.GetProperty("schemaVersion").GetInt32()),
            ["kind"] = CloudSyncValue.Of(dataElem.GetProperty("kind").GetString()!),
            ["reviewStatus"] = CloudSyncValue.Of(dataElem.GetProperty("reviewStatus").GetString()!),
            ["sourceKind"] = CloudSyncValue.Of(dataElem.GetProperty("sourceKind").GetString()!),
            ["sealedMemory"] = new CloudSyncValue.MapValue(sealedFields),
            ["citationCount"] = CloudSyncValue.Of(dataElem.GetProperty("citationCount").GetInt32()),
            ["validFrom"] = CloudSyncValue.Of(DateTimeOffset.Parse(dataElem.GetProperty("validFrom").GetString()!, CultureInfo.InvariantCulture)),
            ["updatedAt"] = CloudSyncValue.Of(DateTimeOffset.Parse(dataElem.GetProperty("updatedAt").GetString()!, CultureInfo.InvariantCulture)),
            ["replicatedAt"] = CloudSyncValue.Of(DateTimeOffset.Parse(dataElem.GetProperty("replicatedAt").GetString()!, CultureInfo.InvariantCulture)),
        };

        var cloudSyncFields = new CloudSyncFields(docFields);

        // 1. Open Swift-sealed fixture
        MemoryCloudFactPayload swiftDecoded = MemoryCloudFactCodec.OpenPayload(cloudSyncFields, uid, docId, vaultKey);

        // Verify field-for-field match with expected payload
        var expected = root.GetProperty("expectedPayload");
        Assert.Equal(expected.GetProperty("schemaVersion").GetInt32(), swiftDecoded.SchemaVersion);
        Assert.Equal(expected.GetProperty("memoryID").GetString(), swiftDecoded.MemoryId);
        Assert.Equal(expected.GetProperty("text").GetString(), swiftDecoded.Text);
        Assert.Equal(expected.GetProperty("kind").GetString(), swiftDecoded.Kind);
        Assert.Equal(expected.GetProperty("confidence").GetDouble(), swiftDecoded.Confidence);
        Assert.Equal(DateTimeOffset.Parse(expected.GetProperty("validFrom").GetString()!, CultureInfo.InvariantCulture), swiftDecoded.ValidFrom);
        Assert.Equal(DateTimeOffset.Parse(expected.GetProperty("updatedAt").GetString()!, CultureInfo.InvariantCulture), swiftDecoded.UpdatedAt);
        Assert.Equal(DateTimeOffset.Parse(expected.GetProperty("validTo").GetString()!, CultureInfo.InvariantCulture), swiftDecoded.ValidTo);
        Assert.Equal(expected.GetProperty("supersededBy").GetString(), swiftDecoded.SupersededBy);
        Assert.Equal(expected.GetProperty("bodyHash").GetString(), swiftDecoded.BodyHash);
        Assert.Equal(expected.GetProperty("projectID").GetString(), swiftDecoded.ProjectId);
        Assert.Equal(expected.GetProperty("engineScope").GetString(), swiftDecoded.EngineScope);
        Assert.Equal(expected.GetProperty("previousBodyHash").GetString(), swiftDecoded.PreviousBodyHash);
        Assert.Equal(expected.GetProperty("writerDevice").GetString(), swiftDecoded.WriterDevice);

        // 2. Re-encode using Windows MemoryCloudFactCodec.EncodeFact
        var memory = MemoryCloudFactCodec.DecodeAuthority(swiftDecoded, MemoryReviewStatus.Approved, swiftDecoded.ValidFrom);
        (string reEncodedDocId, CloudSyncFields reEncodedDoc) = MemoryCloudFactCodec.EncodeFact(
            memory: memory,
            body: swiftDecoded.Text,
            uid: uid,
            vaultKey: vaultKey,
            now: swiftDecoded.UpdatedAt,
            documentIdentity: swiftDecoded.MemoryId,
            tags: swiftDecoded.Tags,
            bodyHash: swiftDecoded.BodyHash,
            projectId: swiftDecoded.ProjectId,
            engineScope: swiftDecoded.EngineScope,
            previousBodyHash: swiftDecoded.PreviousBodyHash,
            writerDevice: swiftDecoded.WriterDevice);

        Assert.Equal(docId, reEncodedDocId);

        // 3. Open the re-encoded payload and assert field-for-field equality
        MemoryCloudFactPayload roundTripped = MemoryCloudFactCodec.OpenPayload(reEncodedDoc, uid, reEncodedDocId, vaultKey);
        Assert.Equal(swiftDecoded.SchemaVersion, roundTripped.SchemaVersion);
        Assert.Equal(swiftDecoded.MemoryId, roundTripped.MemoryId);
        Assert.Equal(swiftDecoded.Text, roundTripped.Text);
        Assert.Equal(swiftDecoded.Kind, roundTripped.Kind);
        Assert.Equal(swiftDecoded.Confidence, roundTripped.Confidence);
        Assert.Equal(swiftDecoded.ValidFrom, roundTripped.ValidFrom);
        Assert.Equal(swiftDecoded.UpdatedAt, roundTripped.UpdatedAt);
        Assert.Equal(swiftDecoded.ValidTo, roundTripped.ValidTo);
        Assert.Equal(swiftDecoded.SupersededBy, roundTripped.SupersededBy);
        Assert.Equal(swiftDecoded.Tags, roundTripped.Tags);
        Assert.Equal(swiftDecoded.BodyHash, roundTripped.BodyHash);
        Assert.Equal(swiftDecoded.ProjectId, roundTripped.ProjectId);
        Assert.Equal(swiftDecoded.EngineScope, roundTripped.EngineScope);
        Assert.Equal(swiftDecoded.PreviousBodyHash, roundTripped.PreviousBodyHash);
        Assert.Equal(swiftDecoded.WriterDevice, roundTripped.WriterDevice);
    }
}