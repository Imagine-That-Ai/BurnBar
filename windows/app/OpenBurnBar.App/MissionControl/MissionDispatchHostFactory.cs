using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.MissionControl;
using OpenBurnBar.CloudSync.Callable;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.App.MissionControl;

/// <summary>
/// Composition-root helper: real Firestore host when cloud credentials are configured, a labeled
/// demo host in sample mode, otherwise an honest empty host.
/// </summary>
public static class MissionDispatchHostFactory
{
    /// <summary>
    /// Builds the mission dispatch host for the Mission Control page. Uses
    /// <see cref="FirestoreMissionDispatchHost"/> when <paramref name="credentials"/> returns a
    /// non-empty Firebase ID token and <paramref name="firebaseUid"/> is set; otherwise an empty host.
    /// </summary>
    public static IMissionDispatchHost Create(
        ICloudSyncGateway? gateway,
        ICloudSyncCredentialsProvider? credentials,
        string? firebaseUid,
        CallableClient? callable = null,
        string? deviceId = null,
        IMissionApprovalCallable? approvalCallable = null)
    {
        IMissionApprovalCallable? injected = approvalCallable
            ?? (callable is null || string.IsNullOrWhiteSpace(firebaseUid)
                ? null
                : new CallableMissionApproval(callable, deviceId ?? firebaseUid));
        if (gateway is null || credentials is null || string.IsNullOrWhiteSpace(firebaseUid))
        {
            return Fallback();
        }

        try
        {
            CloudSyncCredentials creds = credentials.GetCredentialsAsync().GetAwaiter().GetResult();
            if (string.IsNullOrWhiteSpace(creds.IdToken))
            {
                return Fallback();
            }
        }
        catch
        {
            return Fallback();
        }

        return new FirestoreMissionDispatchHost(
            gateway,
            firebaseUid,
            approvalCallable: injected);
    }

    /// <summary>Async variant for callers that already resolved credentials on a background thread.</summary>
    public static async Task<IMissionDispatchHost> CreateAsync(
        ICloudSyncGateway? gateway,
        ICloudSyncCredentialsProvider? credentials,
        string? firebaseUid,
        CallableClient? callable = null,
        string? deviceId = null,
        IMissionApprovalCallable? approvalCallable = null,
        CancellationToken cancellationToken = default)
    {
        IMissionApprovalCallable? injected = approvalCallable
            ?? (callable is null || string.IsNullOrWhiteSpace(firebaseUid)
                ? null
                : new CallableMissionApproval(callable, deviceId ?? firebaseUid));
        if (gateway is null || credentials is null || string.IsNullOrWhiteSpace(firebaseUid))
        {
            return Fallback();
        }

        try
        {
            CloudSyncCredentials creds = await credentials.GetCredentialsAsync(cancellationToken).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(creds.IdToken))
            {
                return Fallback();
            }
        }
        catch
        {
            return Fallback();
        }

        return new FirestoreMissionDispatchHost(
            gateway,
            firebaseUid,
            approvalCallable: injected);
    }

    private static IMissionDispatchHost Fallback() =>
        RuntimeDataMode.SampleModeEnabled
            ? new MissionDispatchDemoHost()
            : new EmptyMissionDispatchHost();
}