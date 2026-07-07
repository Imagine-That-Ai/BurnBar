using System.Text;
using System.Text.Json;
using OpenBurnBar.App.Presentation.DataControlCenter;
using OpenBurnBar.CloudSync.Callable;
using OpenBurnBar.CloudSync.Gateway;
using Xunit;

namespace OpenBurnBar.App.CloudSync.Tests;

/// <summary>
/// Real tests for the 8 Data Control Center governance callables in <see cref="CloudSyncCallableHub"/>
/// (exportUserData / deleteDomainData / listRecovery / setupRecovery / confirmRecovery / revokeAllAccess /
/// getAuditLog / verifyAuditLog). Each callable is proven three ways against a recorded transport, with no
/// live network: (1) a scripted response JSON shaped like the deployed Firebase Functions output decodes
/// value-for-value into the typed result, (2) the outgoing request <c>{ "data": ... }</c> envelope carries
/// the exact field names the deployed handler consumes, and (3) a signed-out hub short-circuits with
/// <see cref="NotSignedInException"/> before any transport call. The live authenticated round-trip (real
/// Firebase tokens + the high-risk-owner-action envelope for export/revoke) stays WS-D-deferred.
/// </summary>
public sealed class CloudSyncCallableHubTests
{
    // ── Test doubles ─────────────────────────────────────────────────────────────────────────────

    /// <summary>
    /// A recording <see cref="ICloudSyncHttpTransport"/>: captures every request the callable client builds
    /// and returns a scripted <c>{ "result": &lt;payload&gt; }</c> success envelope keyed by callable name.
    /// </summary>
    private sealed class RecordingTransport : ICloudSyncHttpTransport
    {
        private readonly Func<string, string> _resultPayloadForName;

        public RecordingTransport(Func<string, string> resultPayloadForName) =>
            _resultPayloadForName = resultPayloadForName;

        public List<CloudSyncHttpRequest> Requests { get; } = new();

        public CloudSyncHttpRequest Last => Requests[^1];

        public Task<CloudSyncHttpResponse> SendAsync(CloudSyncHttpRequest request, CancellationToken cancellationToken = default)
        {
            Requests.Add(request);
            string name = request.Url[(request.Url.LastIndexOf('/') + 1)..];
            byte[] body = Encoding.UTF8.GetBytes($"{{\"result\":{_resultPayloadForName(name)}}}");
            return Task.FromResult(new CloudSyncHttpResponse(200, body, new Dictionary<string, string>(StringComparer.Ordinal)));
        }

        /// <summary>The decoded <c>data</c> object of the last request (the callable's own arguments).</summary>
        public JsonElement LastData()
        {
            using var doc = JsonDocument.Parse(Last.Body ?? Array.Empty<byte>());
            return doc.RootElement.GetProperty("data").Clone();
        }
    }

    private static (CloudSyncCallableHub Hub, RecordingTransport Transport) MakeHub(string resultPayload, bool signedIn = true)
    {
        var transport = new RecordingTransport(_ => resultPayload);
        var credentials = new StaticCredentialsProvider(new CloudSyncCredentials("id-token", "appcheck-token"));
        var client = new CallableClient(transport, credentials, new CallableEndpoint("us-central1", "openburnbar"));
        return (new CloudSyncCallableHub(client, () => signedIn), transport);
    }

    private static bool HasProperty(JsonElement obj, string name) => obj.TryGetProperty(name, out _);

    // ── 1. exportUserData ────────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task ExportAsync_ReserializesTheWholeResultObjectAsIndentedJson()
    {
        const string payload = """
        {"ok":true,"generatedAt":"2026-07-06T00:00:00Z","schemaVersion":2,
         "domains":[{"id":"session_logs","encryptionTier":"server_readable","inlineJson":{"session_logs":[{"a":1}]}}]}
        """;
        (CloudSyncCallableHub hub, _) = MakeHub(payload);

        string json = await hub.ExportAsync(null);

        Assert.Contains("\n", json); // indented (pretty-printed)
        using var doc = JsonDocument.Parse(json);
        JsonElement root = doc.RootElement;
        Assert.True(root.GetProperty("ok").GetBoolean());
        Assert.Equal(2, root.GetProperty("schemaVersion").GetInt32());
        Assert.Equal("session_logs", root.GetProperty("domains")[0].GetProperty("id").GetString());
        Assert.Equal("server_readable", root.GetProperty("domains")[0].GetProperty("encryptionTier").GetString());
    }

    [Fact]
    public async Task ExportAsync_NullOrEmptyDomains_SendsEmptyDataObject()
    {
        (CloudSyncCallableHub hub, RecordingTransport transport) = MakeHub("{\"ok\":true,\"domains\":[]}");

        await hub.ExportAsync(null);
        Assert.False(HasProperty(transport.LastData(), "domains"));

        await hub.ExportAsync(Array.Empty<string>());
        Assert.False(HasProperty(transport.LastData(), "domains"));
    }

    [Fact]
    public async Task ExportAsync_NonEmptyDomains_SendsDomainsArray()
    {
        (CloudSyncCallableHub hub, RecordingTransport transport) = MakeHub("{\"ok\":true,\"domains\":[]}");

        await hub.ExportAsync(new[] { "session_logs", "pensieve" });

        JsonElement domains = transport.LastData().GetProperty("domains");
        Assert.Equal(JsonValueKind.Array, domains.ValueKind);
        Assert.Equal("session_logs", domains[0].GetString());
        Assert.Equal("pensieve", domains[1].GetString());
    }

    [Fact]
    public async Task ExportAsync_HitsExportUserDataEndpoint()
    {
        (CloudSyncCallableHub hub, RecordingTransport transport) = MakeHub("{\"ok\":true}");
        await hub.ExportAsync(null);
        Assert.EndsWith("/exportUserData", transport.Last.Url);
    }

    // ── 2. deleteDomainData ──────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task DeleteDomainAsync_ParsesDeletedTally()
    {
        (CloudSyncCallableHub hub, _) = MakeHub(
            "{\"ok\":true,\"domainId\":\"session_logs\",\"deleted\":{\"firestoreDocs\":42,\"storageObjects\":7}}");

        DeleteResult result = await hub.DeleteDomainAsync("session_logs");

        Assert.Equal(new DeleteResult(42, 7), result);
    }

    [Fact]
    public async Task DeleteDomainAsync_SendsDomainIdAndConfirmGate()
    {
        (CloudSyncCallableHub hub, RecordingTransport transport) = MakeHub("{\"deleted\":{}}");

        await hub.DeleteDomainAsync("media");

        JsonElement data = transport.LastData();
        Assert.Equal("media", data.GetProperty("domainId").GetString());
        Assert.True(data.GetProperty("confirm").GetBoolean());
        Assert.EndsWith("/deleteDomainData", transport.Last.Url);
    }

    // ── 3. listRecovery ──────────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task ListRecoveryAsync_ParsesMethods()
    {
        const string payload = """
        {"ok":true,"methods":[
          {"recoveryId":"rec_abc","kind":"recovery_key","createdAt":"2026-07-01T00:00:00Z","confirmed":true},
          {"recoveryId":"rec_def","kind":"recovery_contact","confirmed":false}]}
        """;
        (CloudSyncCallableHub hub, _) = MakeHub(payload);

        IReadOnlyList<RecoveryMethod> methods = await hub.ListRecoveryAsync();

        Assert.Equal(2, methods.Count);
        Assert.Equal("rec_abc", methods[0].RecoveryId);
        Assert.Equal("recovery_key", methods[0].Kind);
        Assert.True(methods[0].Confirmed);
        Assert.NotNull(methods[0].CreatedAt);
        Assert.True(methods[1].IsRecoveryContact);
        Assert.False(methods[1].Confirmed);
    }

    [Fact]
    public async Task ListRecoveryAsync_SendsNoArguments()
    {
        (CloudSyncCallableHub hub, RecordingTransport transport) = MakeHub("{\"methods\":[]}");

        await hub.ListRecoveryAsync();

        Assert.Empty(transport.LastData().EnumerateObject());
        Assert.EndsWith("/listRecovery", transport.Last.Url);
    }

    // ── 4. setupRecovery ─────────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task SetupRecoveryAsync_ReturnsRecoveryId()
    {
        (CloudSyncCallableHub hub, _) = MakeHub("{\"ok\":true,\"recoveryId\":\"rec_new123\"}");

        string id = await hub.SetupRecoveryAsync(
            RecoveryKind.RecoveryKey,
            new Dictionary<string, object?> { ["wrappedVaultKey"] = "base64==", ["keyVersion"] = 1 });

        Assert.Equal("rec_new123", id);
    }

    [Fact]
    public async Task SetupRecoveryAsync_SendsNestedMethodAndPayload()
    {
        (CloudSyncCallableHub hub, RecordingTransport transport) = MakeHub("{\"recoveryId\":\"rec_x\"}");

        await hub.SetupRecoveryAsync(
            RecoveryKind.RecoveryContact,
            new Dictionary<string, object?> { ["threshold"] = 2, ["contacts"] = new[] { "c1" } });

        JsonElement data = transport.LastData();
        Assert.Equal("recovery_contact", data.GetProperty("method").GetString());
        JsonElement payload = data.GetProperty("payload");
        Assert.Equal(2, payload.GetProperty("threshold").GetInt32());
        Assert.Equal("c1", payload.GetProperty("contacts")[0].GetString());
        Assert.EndsWith("/setupRecovery", transport.Last.Url);
    }

    [Fact]
    public async Task SetupRecoveryAsync_MissingRecoveryId_ThrowsMalformed()
    {
        (CloudSyncCallableHub hub, _) = MakeHub("{\"ok\":true}");

        await Assert.ThrowsAsync<MalformedResponseException>(() =>
            hub.SetupRecoveryAsync(RecoveryKind.RecoveryKey, new Dictionary<string, object?>()));
    }

    // ── 5. confirmRecovery ───────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task ConfirmRecoveryAsync_ReturnsTrueOnOk()
    {
        (CloudSyncCallableHub hub, _) = MakeHub("{\"ok\":true}");

        Assert.True(await hub.ConfirmRecoveryAsync("rec_abc", "deadbeef"));
    }

    [Fact]
    public async Task ConfirmRecoveryAsync_WithHash_SendsRecoveryIdAndHash()
    {
        (CloudSyncCallableHub hub, RecordingTransport transport) = MakeHub("{\"ok\":true}");

        await hub.ConfirmRecoveryAsync("rec_abc", "deadbeef");

        JsonElement data = transport.LastData();
        Assert.Equal("rec_abc", data.GetProperty("recoveryId").GetString());
        Assert.Equal("deadbeef", data.GetProperty("verificationHash").GetString());
        Assert.EndsWith("/confirmRecovery", transport.Last.Url);
    }

    [Fact]
    public async Task ConfirmRecoveryAsync_WithoutHash_OmitsVerificationHash()
    {
        (CloudSyncCallableHub hub, RecordingTransport transport) = MakeHub("{\"ok\":true}");

        await hub.ConfirmRecoveryAsync("rec_contact");

        JsonElement data = transport.LastData();
        Assert.Equal("rec_contact", data.GetProperty("recoveryId").GetString());
        Assert.False(HasProperty(data, "verificationHash"));
    }

    // ── 6. revokeAllAccess ───────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task RevokeAllAsync_ParsesRevokedTally_IgnoringExtraWireFields()
    {
        const string payload = """
        {"ok":true,"partial":false,"failures":[],
         "revoked":{"mcpClients":2,"devices":1,"escrowDevices":1,"signalSessions":9,"providers":4}}
        """;
        (CloudSyncCallableHub hub, _) = MakeHub(payload);

        RevokeResult result = await hub.RevokeAllAsync(RevokeScope.All);

        // signalSessions / partial / failures are on the wire but not in the ported RevokeResult (parity with Swift).
        Assert.Equal(new RevokeResult(2, 1, 1, 4), result);
    }

    [Theory]
    [InlineData(RevokeScope.Sync, "sync")]
    [InlineData(RevokeScope.All, "all")]
    public async Task RevokeAllAsync_SendsScope(RevokeScope scope, string expected)
    {
        (CloudSyncCallableHub hub, RecordingTransport transport) = MakeHub("{\"revoked\":{}}");

        await hub.RevokeAllAsync(scope);

        Assert.Equal(expected, transport.LastData().GetProperty("scope").GetString());
        Assert.EndsWith("/revokeAllAccess", transport.Last.Url);
    }

    // ── 7. getAuditLog ───────────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task GetAuditLogAsync_ParsesEvents_AndCoercesNumericNextCursorToString()
    {
        const string payload = """
        {"ok":true,"events":[
          {"seq":1,"ts":"2026-07-03T10:00:00Z","actor":"you","action":"export","domain":"usage_spend","prevHash":"aa","hash":"bb"}],
         "nextCursor":2}
        """;
        (CloudSyncCallableHub hub, _) = MakeHub(payload);

        AuditPage page = await hub.GetAuditLogAsync(null);

        Assert.Single(page.Events);
        // Deployed getAuditLog returns nextCursor as a NUMBER; the port coerces it to "2" so pagination works
        // (the macOS Swift VM read it as? String and never advanced — a real reference bug we do not replicate).
        Assert.Equal("2", page.NextCursor);
        AuditEvent evt = page.Events[0];
        Assert.Equal(1, evt.Seq);
        Assert.Equal("you", evt.Actor);
        Assert.Equal("export", evt.Action);
        Assert.Equal("usage_spend", evt.Domain);
        Assert.Equal("aa", evt.PrevHash);
        Assert.Equal("bb", evt.Hash);
        Assert.NotNull(evt.Timestamp);
    }

    [Fact]
    public async Task GetAuditLogAsync_LastPage_OmitsNextCursor()
    {
        (CloudSyncCallableHub hub, _) = MakeHub("{\"ok\":true,\"events\":[]}");

        AuditPage page = await hub.GetAuditLogAsync(null);

        Assert.Empty(page.Events);
        Assert.Null(page.NextCursor);
    }

    [Fact]
    public async Task GetAuditLogAsync_FirstPage_SendsLimitOnly()
    {
        (CloudSyncCallableHub hub, RecordingTransport transport) = MakeHub("{\"events\":[]}");

        await hub.GetAuditLogAsync(null);

        JsonElement data = transport.LastData();
        Assert.Equal(100, data.GetProperty("limit").GetInt32());
        Assert.False(HasProperty(data, "cursor"));
        Assert.EndsWith("/getAuditLog", transport.Last.Url);
    }

    [Fact]
    public async Task GetAuditLogAsync_Paginate_SendsLimitAndCursor()
    {
        (CloudSyncCallableHub hub, RecordingTransport transport) = MakeHub("{\"events\":[]}");

        await hub.GetAuditLogAsync("2", limit: 50);

        JsonElement data = transport.LastData();
        Assert.Equal(50, data.GetProperty("limit").GetInt32());
        Assert.Equal("2", data.GetProperty("cursor").GetString());
    }

    // ── 8. verifyAuditLog ────────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task VerifyAuditLogAsync_Valid_ReturnsValidNoBreak()
    {
        (CloudSyncCallableHub hub, RecordingTransport transport) = MakeHub("{\"ok\":true,\"valid\":true,\"verifiedMaxSeq\":10}");

        AuditVerification verification = await hub.VerifyAuditLogAsync();

        Assert.Equal(new AuditVerification(true, null), verification);
        Assert.Empty(transport.LastData().EnumerateObject());
        Assert.EndsWith("/verifyAuditLog", transport.Last.Url);
    }

    [Fact]
    public async Task VerifyAuditLogAsync_Invalid_ReturnsBrokenAt()
    {
        (CloudSyncCallableHub hub, _) = MakeHub("{\"ok\":true,\"valid\":false,\"brokenAt\":5,\"reason\":\"link\"}");

        AuditVerification verification = await hub.VerifyAuditLogAsync();

        Assert.Equal(new AuditVerification(false, 5), verification);
    }

    // ── Signed-out short-circuit (every callable gates on auth) ────────────────────────────────────

    [Fact]
    public void IsSignedIn_ReflectsTheProvidedPredicate()
    {
        (CloudSyncCallableHub signedIn, _) = MakeHub("{}", signedIn: true);
        (CloudSyncCallableHub signedOut, _) = MakeHub("{}", signedIn: false);
        Assert.True(signedIn.IsSignedIn);
        Assert.False(signedOut.IsSignedIn);
    }

    [Fact]
    public async Task ExportAsync_SignedOut_Throws() =>
        await Assert.ThrowsAsync<NotSignedInException>(() => SignedOut().ExportAsync(null));

    [Fact]
    public async Task DeleteDomainAsync_SignedOut_Throws() =>
        await Assert.ThrowsAsync<NotSignedInException>(() => SignedOut().DeleteDomainAsync("x"));

    [Fact]
    public async Task ListRecoveryAsync_SignedOut_Throws() =>
        await Assert.ThrowsAsync<NotSignedInException>(() => SignedOut().ListRecoveryAsync());

    [Fact]
    public async Task SetupRecoveryAsync_SignedOut_Throws() =>
        await Assert.ThrowsAsync<NotSignedInException>(() =>
            SignedOut().SetupRecoveryAsync(RecoveryKind.RecoveryKey, new Dictionary<string, object?>()));

    [Fact]
    public async Task ConfirmRecoveryAsync_SignedOut_Throws() =>
        await Assert.ThrowsAsync<NotSignedInException>(() => SignedOut().ConfirmRecoveryAsync("rec_abc"));

    [Fact]
    public async Task RevokeAllAsync_SignedOut_Throws() =>
        await Assert.ThrowsAsync<NotSignedInException>(() => SignedOut().RevokeAllAsync(RevokeScope.All));

    [Fact]
    public async Task GetAuditLogAsync_SignedOut_Throws() =>
        await Assert.ThrowsAsync<NotSignedInException>(() => SignedOut().GetAuditLogAsync(null));

    [Fact]
    public async Task VerifyAuditLogAsync_SignedOut_Throws() =>
        await Assert.ThrowsAsync<NotSignedInException>(() => SignedOut().VerifyAuditLogAsync());

    private static CloudSyncCallableHub SignedOut() => MakeHub("{}", signedIn: false).Hub;
}
