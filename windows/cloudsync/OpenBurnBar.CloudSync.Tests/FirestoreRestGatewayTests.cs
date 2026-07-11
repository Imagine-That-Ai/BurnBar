using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using Xunit;

namespace OpenBurnBar.CloudSync.Tests;

/// <summary>
/// Proves the REST gateway builds the correct documents.get / .patch / :commit /
/// :runQuery / .delete request SHAPES and parses their responses, plus the
/// App-Check-required fail-closed refusal — all via a fake transport (the live
/// authenticated round-trip is dev-host/CI-deferred).
/// </summary>
public sealed class FirestoreRestGatewayTests
{
    private static readonly FirestoreDatabase Db = new("proj");

    private static CloudSyncFields Fields(params (string Key, CloudSyncValue Value)[] pairs) =>
        CloudSyncFields.From(pairs.Select(p => new KeyValuePair<string, CloudSyncValue>(p.Key, p.Value)));

    private static FirestoreRestGateway Gateway(
        RecordingTransport transport,
        string? appCheck = "appcheck-tok",
        bool requireAppCheck = true) =>
        new(transport, new StaticCredentialsProvider(new CloudSyncCredentials("id-token", appCheck)), Db, requireAppCheck);

    [Fact]
    public async Task Get_issues_a_get_with_bearer_auth_and_parses_fields()
    {
        var transport = new RecordingTransport(_ => RecordingTransport.Json(200,
            "{\"name\":\"projects/proj/databases/(default)/documents/users/u1/usage/e1\"," +
            "\"fields\":{\"provider\":{\"stringValue\":\"anthropic\"}}}"));
        FirestoreRestGateway gateway = Gateway(transport);

        CloudSyncFields? fields = await gateway.Collection("users/u1/usage").Document("e1").GetDataAsync();

        Assert.Equal(HttpVerb.Get, transport.LastRequest.Method);
        Assert.Equal("https://firestore.googleapis.com/v1/projects/proj/databases/(default)/documents/users/u1/usage/e1",
            transport.LastRequest.Url);
        Assert.Equal("Bearer id-token", transport.LastRequest.Headers["Authorization"]);
        Assert.Equal("appcheck-tok", transport.LastRequest.Headers["X-Firebase-AppCheck"]);
        Assert.NotNull(fields);
        Assert.Equal("anthropic", ((CloudSyncValue.StringValue)fields!["provider"]!).Value);
    }

    [Fact]
    public async Task Get_returns_null_on_404()
    {
        var transport = new RecordingTransport(_ => RecordingTransport.Json(404, "{\"error\":{\"code\":404}}"));
        FirestoreRestGateway gateway = Gateway(transport);

        Assert.Null(await gateway.Collection("c").Document("missing").GetDataAsync());
    }

    [Fact]
    public async Task Merge_set_issues_patch_with_update_mask_and_fields_body()
    {
        var transport = new RecordingTransport(_ => RecordingTransport.Json(200, "{}"));
        FirestoreRestGateway gateway = Gateway(transport);

        await gateway.Collection("c").Document("d")
            .SetDataAsync(Fields(
                ("b", new CloudSyncValue.IntegerValue(2)),
                ("a", new CloudSyncValue.StringValue("x"))), merge: true);

        Assert.Equal(HttpVerb.Patch, transport.LastRequest.Method);
        Assert.Contains("updateMask.fieldPaths=a", transport.LastRequest.Url);
        Assert.Contains("updateMask.fieldPaths=b", transport.LastRequest.Url);
        string body = transport.LastRequestBodyText();
        Assert.Equal("{\"fields\":{\"a\":{\"stringValue\":\"x\"},\"b\":{\"integerValue\":\"2\"}}}", body);
    }

    [Fact]
    public async Task Set_with_server_timestamp_routes_through_commit_with_transforms()
    {
        var transport = new RecordingTransport(_ => RecordingTransport.Json(200, "{\"writeResults\":[]}"));
        FirestoreRestGateway gateway = Gateway(transport);

        await gateway.Collection("c").Document("d").SetDataAsync(Fields(
            ("n", new CloudSyncValue.IntegerValue(1)),
            ("updatedAt", CloudSyncValue.ServerTimestamp.Instance)), merge: true);

        Assert.Equal(HttpVerb.Post, transport.LastRequest.Method);
        Assert.EndsWith(":commit", transport.LastRequest.Url);
        string body = transport.LastRequestBodyText();
        Assert.Contains("\"updateTransforms\"", body);
        Assert.Contains("\"setToServerValue\":\"REQUEST_TIME\"", body);
        Assert.Contains("\"fieldPath\":\"updatedAt\"", body);
        // The literal field rides update.fields; the transform field does not.
        Assert.Contains("\"fields\":{\"n\":{\"integerValue\":\"1\"}}", body);
    }

    [Fact]
    public async Task Batch_commit_posts_all_writes_to_commit()
    {
        var transport = new RecordingTransport(_ => RecordingTransport.Json(200, "{\"writeResults\":[]}"));
        FirestoreRestGateway gateway = Gateway(transport);

        ICloudSyncWriteBatch batch = gateway.Batch();
        batch.SetData(Fields(("n", new CloudSyncValue.IntegerValue(1))), gateway.Collection("c").Document("d1"), merge: false);
        batch.DeleteDocument(gateway.Collection("c").Document("d2"));
        await batch.CommitAsync();

        Assert.EndsWith(":commit", transport.LastRequest.Url);
        string body = transport.LastRequestBodyText();
        Assert.Contains("\"update\"", body);
        Assert.Contains("\"delete\":\"projects/proj/databases/(default)/documents/c/d2\"", body);
    }

    [Fact]
    public async Task RunQuery_posts_structured_query_and_parses_documents()
    {
        var transport = new RecordingTransport(_ => RecordingTransport.Json(200,
            "[{\"document\":{\"name\":\"projects/proj/databases/(default)/documents/scores/d1\"," +
            "\"fields\":{\"v\":{\"integerValue\":\"1\"}}}}," +
            "{\"readTime\":\"2026-07-03T10:00:00Z\"}," +
            "{\"document\":{\"name\":\"projects/proj/databases/(default)/documents/scores/d2\"," +
            "\"fields\":{\"v\":{\"integerValue\":\"2\"}}}}]"));
        FirestoreRestGateway gateway = Gateway(transport);

        ICloudSyncQuerySnapshot snapshot = await gateway.Collection("scores")
            .WhereGreaterThan("v", new CloudSyncValue.IntegerValue(0))
            .OrderBy("v", descending: true)
            .Limit(10)
            .GetDocumentsAsync();

        Assert.EndsWith(":runQuery", transport.LastRequest.Url);
        string body = transport.LastRequestBodyText();
        Assert.Contains("\"collectionId\":\"scores\"", body);
        Assert.Contains("\"op\":\"GREATER_THAN\"", body);
        Assert.Contains("\"direction\":\"DESCENDING\"", body);
        Assert.Contains("\"limit\":10", body);

        // The readTime-only row is skipped; two documents parse through.
        Assert.Equal(2, snapshot.Documents.Count);
        Assert.Equal(new[] { "d1", "d2" }, snapshot.Documents.Select(d => d.DocumentId).ToArray());
    }

    [Fact]
    public async Task Delete_issues_http_delete_and_tolerates_404()
    {
        var transport = new RecordingTransport(_ => RecordingTransport.Json(404, "{}"));
        FirestoreRestGateway gateway = Gateway(transport);

        await gateway.Collection("c").Document("d").DeleteDocumentAsync(); // no throw

        Assert.Equal(HttpVerb.Delete, transport.LastRequest.Method);
    }

    [Fact]
    public async Task Non_success_status_maps_to_a_gateway_exception()
    {
        var transport = new RecordingTransport(_ => RecordingTransport.Json(403, "{\"error\":{\"status\":\"PERMISSION_DENIED\"}}"));
        FirestoreRestGateway gateway = Gateway(transport);

        CloudSyncGatewayException ex = await Assert.ThrowsAsync<CloudSyncGatewayException>(() =>
            gateway.Collection("c").Document("d").GetDataAsync());
        Assert.Equal(CloudSyncGatewayErrorKind.PermissionDenied, ex.Kind);
    }

    [Fact]
    public async Task App_check_required_but_missing_fails_closed_without_sending()
    {
        var transport = new RecordingTransport(_ => RecordingTransport.Json(200, "{}"));
        FirestoreRestGateway gateway = Gateway(transport, appCheck: null, requireAppCheck: true);

        CloudSyncGatewayException ex = await Assert.ThrowsAsync<CloudSyncGatewayException>(() =>
            gateway.Collection("c").Document("d").GetDataAsync());
        Assert.Equal(CloudSyncGatewayErrorKind.PermissionDenied, ex.Kind);
        Assert.Empty(transport.Requests); // never transmitted
    }

    [Fact]
    public async Task App_check_optional_omits_the_header_when_absent()
    {
        var transport = new RecordingTransport(_ => RecordingTransport.Json(200,
            "{\"name\":\"projects/proj/databases/(default)/documents/c/d\",\"fields\":{}}"));
        FirestoreRestGateway gateway = Gateway(transport, appCheck: null, requireAppCheck: false);

        await gateway.Collection("c").Document("d").GetDataAsync();

        Assert.False(transport.LastRequest.Headers.ContainsKey("X-Firebase-AppCheck"));
        Assert.Equal("Bearer id-token", transport.LastRequest.Headers["Authorization"]);
    }
}
