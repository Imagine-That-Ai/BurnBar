using System;

namespace OpenBurnBar.CloudSync.AppCheck.Mint;

/// <summary>
/// Resolves the URL of the <c>mintWindowsAppCheckToken</c> Firebase callable.
/// </summary>
/// <remarks>
/// A v2 <c>onCall</c> function is reachable at the classic callable URL
/// <c>https://{region}-{projectId}.cloudfunctions.net/{name}</c>. The region
/// defaults to <c>us-central1</c> to match the server's single-region
/// <c>FUNCTIONS_REGION</c> default (<c>functions/src/runtimeOptions.ts</c>); the
/// function name is fixed to the deployed callable. An explicit override URL is
/// accepted for the emulator / dev-host / a future region flip, so a change stays
/// a one-line config edit and tests can point at a loopback host.
/// </remarks>
public sealed class AppCheckMintEndpoint
{
    /// <summary>The deployed callable's function name.</summary>
    public const string FunctionName = "mintWindowsAppCheckToken";

    /// <summary>The server's default deployment region (keep in sync with FUNCTIONS_REGION).</summary>
    public const string DefaultRegion = "us-central1";

    public Uri Url { get; }

    private AppCheckMintEndpoint(Uri url)
    {
        Url = url;
    }

    /// <summary>Build the canonical cloudfunctions.net callable URL for a project.</summary>
    public static AppCheckMintEndpoint ForProject(string projectId, string region = DefaultRegion)
    {
        if (string.IsNullOrWhiteSpace(projectId))
        {
            throw new ArgumentException("projectId is required.", nameof(projectId));
        }
        if (string.IsNullOrWhiteSpace(region))
        {
            throw new ArgumentException("region is required.", nameof(region));
        }
        var url = new Uri($"https://{region}-{projectId}.cloudfunctions.net/{FunctionName}", UriKind.Absolute);
        return new AppCheckMintEndpoint(url);
    }

    /// <summary>Use an explicit absolute URL (emulator / dev-host / test loopback / region flip).</summary>
    public static AppCheckMintEndpoint ForUrl(Uri url)
    {
        if (url is null)
        {
            throw new ArgumentNullException(nameof(url));
        }
        if (!url.IsAbsoluteUri)
        {
            throw new ArgumentException("Mint endpoint URL must be absolute.", nameof(url));
        }
        return new AppCheckMintEndpoint(url);
    }
}
