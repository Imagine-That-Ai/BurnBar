using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.MissionControl;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.App.MissionControl;

/// <summary>
/// Composition-root helper: real Firestore host when cloud credentials are configured,
/// otherwise the dev <see cref="MissionDispatchDemoHost"/>.
/// </summary>
public static class MissionDispatchHostFactory
{
    /// <summary>
    /// Builds the mission dispatch host for the Mission Control page. Uses
    /// <see cref="FirestoreMissionDispatchHost"/> when <paramref name="credentials"/> returns a
    /// non-empty Firebase ID token and <paramref name="firebaseUid"/> is set; otherwise the demo host.
    /// </summary>
    public static IMissionDispatchHost Create(
        ICloudSyncGateway? gateway,
        ICloudSyncCredentialsProvider? credentials,
        string? firebaseUid)
    {
        if (gateway is null || credentials is null || string.IsNullOrWhiteSpace(firebaseUid))
        {
            return new MissionDispatchDemoHost();
        }

        try
        {
            CloudSyncCredentials creds = credentials.GetCredentialsAsync().GetAwaiter().GetResult();
            if (string.IsNullOrWhiteSpace(creds.IdToken))
            {
                return new MissionDispatchDemoHost();
            }
        }
        catch
        {
            return new MissionDispatchDemoHost();
        }

        return new FirestoreMissionDispatchHost(gateway, firebaseUid);
    }

    /// <summary>Async variant for callers that already resolved credentials on a background thread.</summary>
    public static async Task<IMissionDispatchHost> CreateAsync(
        ICloudSyncGateway? gateway,
        ICloudSyncCredentialsProvider? credentials,
        string? firebaseUid,
        CancellationToken cancellationToken = default)
    {
        if (gateway is null || credentials is null || string.IsNullOrWhiteSpace(firebaseUid))
        {
            return new MissionDispatchDemoHost();
        }

        try
        {
            CloudSyncCredentials creds = await credentials.GetCredentialsAsync(cancellationToken).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(creds.IdToken))
            {
                return new MissionDispatchDemoHost();
            }
        }
        catch
        {
            return new MissionDispatchDemoHost();
        }

        return new FirestoreMissionDispatchHost(gateway, firebaseUid);
    }
}