using System;

namespace OpenBurnBar.CloudSync.AppCheck.Mint;

/// <summary>Resolves the server-issued Windows App Check challenge callable URL.</summary>
public sealed class AppCheckChallengeEndpoint
{
    public const string FunctionName = "issueWindowsAppCheckChallenge";

    public Uri Url { get; }

    private AppCheckChallengeEndpoint(Uri url) => Url = url;

    public static AppCheckChallengeEndpoint ForProject(
        string projectId,
        string region = AppCheckMintEndpoint.DefaultRegion)
    {
        if (string.IsNullOrWhiteSpace(projectId))
        {
            throw new ArgumentException("projectId is required.", nameof(projectId));
        }
        if (string.IsNullOrWhiteSpace(region))
        {
            throw new ArgumentException("region is required.", nameof(region));
        }
        return new AppCheckChallengeEndpoint(
            new Uri($"https://{region}-{projectId}.cloudfunctions.net/{FunctionName}", UriKind.Absolute));
    }

    public static AppCheckChallengeEndpoint ForUrl(Uri url)
    {
        if (url is null) throw new ArgumentNullException(nameof(url));
        if (!url.IsAbsoluteUri)
        {
            throw new ArgumentException("Challenge endpoint URL must be absolute.", nameof(url));
        }
        return new AppCheckChallengeEndpoint(url);
    }
}
