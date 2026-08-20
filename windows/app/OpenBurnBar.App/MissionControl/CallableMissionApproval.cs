using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.Callable;

namespace OpenBurnBar.App.MissionControl;

/// <summary>
/// Production <see cref="IMissionApprovalCallable"/> over the existing
/// Firebase callable client. Client merges of <c>approvalStatus</c> are denied.
/// </summary>
public sealed class CallableMissionApproval : IMissionApprovalCallable
{
    private readonly CallableClient _client;
    private readonly string _deviceId;

    public CallableMissionApproval(CallableClient client, string deviceId)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        if (string.IsNullOrWhiteSpace(deviceId))
        {
            throw new ArgumentException("deviceId is required.", nameof(deviceId));
        }
        _deviceId = deviceId;
    }

    public async Task RespondAsync(string requestId, bool approve, CancellationToken cancellationToken = default)
    {
        await _client.InvokeAsync<object, JsonElement>(
            "respondMissionApproval",
            new { requestId, approve, deviceId = _deviceId },
            cancellationToken).ConfigureAwait(false);
    }
}
