using System.Text.Json;
using OpenBurnBar.App.Presentation.DataControlCenter;
using OpenBurnBar.App.Presentation.Memories;
using OpenBurnBar.CloudSync.Callable;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// <see cref="IDataControlCallableHub"/> backed by <see cref="CallableClient"/> (getDataDomainUsage and governance callables).
/// </summary>
public sealed class CloudSyncCallableHub : IDataControlCallableHub
{
    private static readonly JsonSerializerOptions ExportSerializeOptions = new() { WriteIndented = true };

    private readonly CallableClient _client;
    private readonly Func<bool> _isSignedIn;

    public CloudSyncCallableHub(CallableClient client, Func<bool> isSignedIn)
    {
        _client = client;
        _isSignedIn = isSignedIn;
    }

    public bool IsSignedIn => _isSignedIn();

    public async Task<DataDomainUsageSnapshot> GetUsageAsync(CancellationToken cancellationToken = default)
    {
        EnsureSignedIn();
        JsonElement result = await _client
            .InvokeAsync<object, JsonElement>("getDataDomainUsage", new { }, cancellationToken)
            .ConfigureAwait(false);
        IReadOnlyDictionary<string, object?> dict = JsonElementToDict(result);
        return DataDomainUsageParser.Parse(dict);
    }

    /// <summary>
    /// exportUserData → the pretty-printed export JSON. Mirrors the Swift VM, which re-serializes the
    /// <b>entire</b> result object for the save panel: <c>{}</c> (all domains) or <c>{ domains: [...] }</c>
    /// in, the full <c>{ ok, generatedAt, schemaVersion, domains: [...] }</c> object back out as indented
    /// JSON. The high-risk-owner-action envelope (nonce / trustedDeviceId / actionProof) the macOS caller
    /// layers on this owner action is minted by the Windows Signal-identity + TPM path, which is WS-D-deferred.
    /// </summary>
    public async Task<string> ExportAsync(IReadOnlyList<string>? domains, CancellationToken cancellationToken = default)
    {
        EnsureSignedIn();
        object request = domains is { Count: > 0 } ? new { domains } : new { };
        JsonElement result = await _client
            .InvokeAsync<object, JsonElement>("exportUserData", request, cancellationToken)
            .ConfigureAwait(false);
        return JsonSerializer.Serialize(result, ExportSerializeOptions);
    }

    /// <summary>
    /// deleteDomainData → the per-domain deletion tally. Sends <c>{ domainId, confirm: true }</c>
    /// (the <c>confirm</c> gate the deployed handler requires) and reads <c>deleted.{firestoreDocs,storageObjects}</c>.
    /// </summary>
    public async Task<DeleteResult> DeleteDomainAsync(string domainId, CancellationToken cancellationToken = default)
    {
        EnsureSignedIn();
        JsonElement result = await _client
            .InvokeAsync<object, JsonElement>("deleteDomainData", new { domainId, confirm = true }, cancellationToken)
            .ConfigureAwait(false);
        return GovernanceDecoding.ParseDeleteResult(JsonElementToDict(result));
    }

    /// <summary>listRecovery → the registered recovery methods (no arguments); reads <c>methods: [...]</c>.</summary>
    public async Task<IReadOnlyList<RecoveryMethod>> ListRecoveryAsync(CancellationToken cancellationToken = default)
    {
        EnsureSignedIn();
        JsonElement result = await _client
            .InvokeAsync<object, JsonElement>("listRecovery", new { }, cancellationToken)
            .ConfigureAwait(false);
        return GovernanceDecoding.ParseRecoveryMethods(JsonElementToDict(result));
    }

    /// <summary>
    /// setupRecovery → the new method's recovery id. Sends the <b>nested</b> <c>{ method, payload }</c>
    /// envelope the deployed handler parses (payload shaped per kind: recovery_key vs recovery_contact),
    /// and reads <c>recoveryId</c> back. A missing id is a <see cref="MalformedResponseException"/>.
    /// </summary>
    public async Task<string> SetupRecoveryAsync(
        RecoveryKind method,
        IReadOnlyDictionary<string, object?> payload,
        CancellationToken cancellationToken = default)
    {
        EnsureSignedIn();
        var request = new { method = method.RawValue(), payload };
        JsonElement result = await _client
            .InvokeAsync<object, JsonElement>("setupRecovery", request, cancellationToken)
            .ConfigureAwait(false);
        return GovernanceDecoding.ParseRecoveryId(JsonElementToDict(result))
            ?? throw new MalformedResponseException();
    }

    /// <summary>
    /// confirmRecovery → whether the confirmation was accepted. Sends <c>{ recoveryId }</c> plus
    /// <c>verificationHash</c> when present (omitted for recovery_contact). The deployed handler returns
    /// <c>{ ok: true }</c>; like the Swift VM, any non-throwing response is success.
    /// </summary>
    public async Task<bool> ConfirmRecoveryAsync(
        string recoveryId,
        string? verificationHash = null,
        CancellationToken cancellationToken = default)
    {
        EnsureSignedIn();
        object request = verificationHash is null ? new { recoveryId } : new { recoveryId, verificationHash };
        JsonElement result = await _client
            .InvokeAsync<object, JsonElement>("confirmRecovery", request, cancellationToken)
            .ConfigureAwait(false);
        return CallableValue.Bool(JsonElementToDict(result).GetValueOrDefault("ok"), fallback: true);
    }

    /// <summary>
    /// revokeAllAccess → the panic teardown tally. Sends <c>{ scope }</c> and reads
    /// <c>revoked.{mcpClients,devices,escrowDevices,providers}</c>. As with exportUserData, the high-risk
    /// envelope (nonce / trustedDeviceId / actionProof) is WS-D-deferred on Windows.
    /// </summary>
    public async Task<RevokeResult> RevokeAllAsync(RevokeScope scope, CancellationToken cancellationToken = default)
    {
        EnsureSignedIn();
        JsonElement result = await _client
            .InvokeAsync<object, JsonElement>("revokeAllAccess", new { scope = scope.RawValue() }, cancellationToken)
            .ConfigureAwait(false);
        return GovernanceDecoding.ParseRevokeResult(JsonElementToDict(result));
    }

    /// <summary>
    /// getAuditLog → a page of tamper-evident events + the continuation cursor. Always sends <c>limit</c>;
    /// adds <c>cursor</c> only when paginating. The deployed handler returns a <b>numeric</b> nextCursor
    /// (coerced to the <see cref="AuditPage.NextCursor"/> string by <see cref="GovernanceDecoding.ParseAuditPage"/>).
    /// </summary>
    public async Task<AuditPage> GetAuditLogAsync(string? cursor, int limit = 100, CancellationToken cancellationToken = default)
    {
        EnsureSignedIn();
        object request = cursor is null ? new { limit } : new { limit, cursor };
        JsonElement result = await _client
            .InvokeAsync<object, JsonElement>("getAuditLog", request, cancellationToken)
            .ConfigureAwait(false);
        return GovernanceDecoding.ParseAuditPage(JsonElementToDict(result));
    }

    /// <summary>verifyAuditLog → whether the hash chain is intact (and where it broke). Reads <c>{ valid, brokenAt? }</c>.</summary>
    public async Task<AuditVerification> VerifyAuditLogAsync(CancellationToken cancellationToken = default)
    {
        EnsureSignedIn();
        JsonElement result = await _client
            .InvokeAsync<object, JsonElement>("verifyAuditLog", new { }, cancellationToken)
            .ConfigureAwait(false);
        return GovernanceDecoding.ParseAuditVerification(JsonElementToDict(result));
    }

    private void EnsureSignedIn()
    {
        if (!IsSignedIn)
        {
            throw new NotSignedInException();
        }
    }

    private static IReadOnlyDictionary<string, object?> JsonElementToDict(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            return new Dictionary<string, object?>(StringComparer.Ordinal);
        }

        var dict = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (JsonProperty prop in element.EnumerateObject())
        {
            dict[prop.Name] = JsonElementToObject(prop.Value);
        }

        return dict;
    }

    private static object? JsonElementToObject(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Null => null,
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.String => element.GetString(),
        JsonValueKind.Number => element.TryGetInt64(out long l) ? l : element.GetDouble(),
        JsonValueKind.Array => element.EnumerateArray().Select(JsonElementToObject).ToList(),
        JsonValueKind.Object => JsonElementToDict(element),
        _ => null,
    };
}