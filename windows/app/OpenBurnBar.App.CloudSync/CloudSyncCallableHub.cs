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

    public Task<string> ExportAsync(IReadOnlyList<string>? domains, CancellationToken cancellationToken = default) =>
        throw new NotImplementedException("exportUserData callable wiring is deferred beyond getDataDomainUsage in WS-B4.");

    public Task<DeleteResult> DeleteDomainAsync(string domainId, CancellationToken cancellationToken = default) =>
        throw new NotImplementedException("deleteDomainData callable wiring is deferred beyond getDataDomainUsage in WS-B4.");

    public Task<IReadOnlyList<RecoveryMethod>> ListRecoveryAsync(CancellationToken cancellationToken = default) =>
        throw new NotImplementedException("listRecovery callable wiring is deferred beyond getDataDomainUsage in WS-B4.");

    public Task<string> SetupRecoveryAsync(
        RecoveryKind method,
        IReadOnlyDictionary<string, object?> payload,
        CancellationToken cancellationToken = default) =>
        throw new NotImplementedException("setupRecovery callable wiring is deferred beyond getDataDomainUsage in WS-B4.");

    public Task<bool> ConfirmRecoveryAsync(
        string recoveryId,
        string? verificationHash = null,
        CancellationToken cancellationToken = default) =>
        throw new NotImplementedException("confirmRecovery callable wiring is deferred beyond getDataDomainUsage in WS-B4.");

    public Task<RevokeResult> RevokeAllAsync(RevokeScope scope, CancellationToken cancellationToken = default) =>
        throw new NotImplementedException("revokeAllAccess callable wiring is deferred beyond getDataDomainUsage in WS-B4.");

    public Task<AuditPage> GetAuditLogAsync(string? cursor, int limit = 100, CancellationToken cancellationToken = default) =>
        throw new NotImplementedException("getAuditLog callable wiring is deferred beyond getDataDomainUsage in WS-B4.");

    public Task<AuditVerification> VerifyAuditLogAsync(CancellationToken cancellationToken = default) =>
        throw new NotImplementedException("verifyAuditLog callable wiring is deferred beyond getDataDomainUsage in WS-B4.");

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