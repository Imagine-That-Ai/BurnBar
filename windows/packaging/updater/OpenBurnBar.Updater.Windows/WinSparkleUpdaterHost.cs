// Descriptor-aware Windows updater host. WinSparkle cannot validate BurnBar's
// custom descriptor signature, so it is never allowed to fetch or install.
// The managed host verifies signed metadata before trusting the enclosure URL,
// then verifies the bytes before handing the MSIX to Windows App Installer.

using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Runtime.Versioning;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Updater.Core.Host;
using OpenBurnBar.Updater.Core.Verification;

namespace OpenBurnBar.Updater.Windows;

/// <summary>Drives WinSparkle behind the portable <see cref="IUpdaterHost"/> seam.</summary>
[SupportedOSPlatform("windows")]
public sealed class WinSparkleUpdaterHost : IUpdaterHost, IDisposable
{
    private const int MaxFeedBytes = 1 * 1024 * 1024;
    private const int MaxArtifactBytes = 512 * 1024 * 1024;
    private readonly HttpClient _httpClient;
    private readonly bool _ownsHttpClient;

    private UpdaterConfiguration? _configuration;
    private UpdateFeedVerifier? _verifier;

    public WinSparkleUpdaterHost(
        string companyName = "Imagine That",
        string appName = "OpenBurnBar",
        HttpClient? httpClient = null)
    {
        _ = companyName;
        _ = appName;
        if (httpClient is null)
        {
            _httpClient = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false });
            _ownsHttpClient = true;
        }
        else
        {
            _httpClient = httpClient;
        }
    }

    /// <inheritdoc />
    public void Configure(UpdaterConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        _configuration = configuration;
        _verifier = configuration.CreateVerifier();

        RequireHttpsUri(configuration.AppcastUrl, "appcast");
    }

    /// <inheritdoc />
    public Task CheckForUpdatesWithUiAsync(CancellationToken cancellationToken = default)
    {
        return CheckAsync(launchInstaller: true, cancellationToken);
    }

    /// <inheritdoc />
    public Task CheckForUpdatesInBackgroundAsync(CancellationToken cancellationToken = default)
    {
        return CheckAsync(launchInstaller: false, cancellationToken);
    }

    /// <inheritdoc />
    public UpdateDecision VerifyDownloadedArtifact(string feedText, byte[] artifactBytes)
    {
        ArgumentNullException.ThrowIfNull(artifactBytes);
        var configuration = _configuration
            ?? throw new InvalidOperationException("Configure must be called before verifying an artifact.");
        var verifier = _verifier
            ?? throw new InvalidOperationException("Configure must be called before verifying an artifact.");

        return verifier.Decide(feedText, configuration.Format, configuration.CurrentVersion, artifactBytes);
    }

    private void EnsureConfigured()
    {
        if (_configuration is null || _verifier is null)
        {
            throw new InvalidOperationException("Configure must be called before checking for updates.");
        }
    }

    private async Task CheckAsync(bool launchInstaller, CancellationToken cancellationToken)
    {
        EnsureConfigured();
        var configuration = _configuration!;
        var verifier = _verifier!;
        var feedUri = RequireHttpsUri(configuration.AppcastUrl, "appcast");
        byte[] feedBytes = await DownloadBoundedAsync(feedUri, MaxFeedBytes, null, cancellationToken)
            .ConfigureAwait(false);
        string feedText = Encoding.UTF8.GetString(feedBytes);
        var evaluation = verifier.EvaluateFeed(feedText, configuration.Format, configuration.CurrentVersion);
        if (evaluation.Status != FeedEvaluationStatus.CandidateAvailable)
        {
            if (evaluation.Status == FeedEvaluationStatus.Rejected)
            {
                throw new InvalidOperationException($"Update feed rejected: {evaluation.Reason}.");
            }
            return;
        }

        var manifest = evaluation.Manifest!;
        var descriptor = verifier.VerifyDescriptor(manifest);
        if (!descriptor.Verified)
        {
            throw new InvalidOperationException($"Update descriptor rejected: {descriptor.Reason}.");
        }

        // Background checks may report availability elsewhere, but must never
        // invoke the native installer without a user-initiated check.
        if (!launchInstaller)
        {
            return;
        }

        if (manifest.Length is null or <= 0 or > MaxArtifactBytes)
        {
            throw new InvalidOperationException("Update descriptor has an unsafe artifact length.");
        }
        var artifactUri = RequireHttpsUri(manifest.Url, "artifact");
        byte[] artifactBytes = await DownloadBoundedAsync(
                artifactUri,
                MaxArtifactBytes,
                manifest.Length.Value,
                cancellationToken)
            .ConfigureAwait(false);
        var decision = verifier.Decide(feedText, configuration.Format, configuration.CurrentVersion, artifactBytes);
        if (!decision.ShouldInstall)
        {
            throw new InvalidOperationException($"Update artifact rejected: {decision.Reason}.");
        }

        string directory = Path.Combine(Path.GetTempPath(), "OpenBurnBar", "VerifiedUpdates");
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, $"OpenBurnBar-{manifest.Version}-{Guid.NewGuid():N}.msix");
        await File.WriteAllBytesAsync(path, artifactBytes, cancellationToken).ConfigureAwait(false);
        using Process? process = Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        if (process is null)
        {
            File.Delete(path);
            throw new InvalidOperationException("Windows App Installer could not be started.");
        }
    }

    private async Task<byte[]> DownloadBoundedAsync(
        Uri uri,
        int maximumBytes,
        long? exactLength,
        CancellationToken cancellationToken)
    {
        using var response = await _httpClient
            .GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
            .ConfigureAwait(false);
        if (response.StatusCode is >= HttpStatusCode.MultipleChoices and < HttpStatusCode.BadRequest)
        {
            throw new InvalidOperationException("Update redirects are not allowed.");
        }
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"Update download failed with HTTP {(int)response.StatusCode}.");
        }
        if (response.RequestMessage?.RequestUri != uri)
        {
            throw new InvalidOperationException("Update transport changed the signed URL.");
        }
        long? contentLength = response.Content.Headers.ContentLength;
        if (contentLength > maximumBytes || (exactLength is { } expected && contentLength is { } actual && actual != expected))
        {
            throw new InvalidOperationException("Update response length does not match the signed descriptor.");
        }

        await using Stream source = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        int initialCapacity = contentLength is > 0 && contentLength <= maximumBytes
            ? (int)contentLength.Value
            : 0;
        using var destination = new MemoryStream(initialCapacity);
        var buffer = new byte[64 * 1024];
        while (true)
        {
            int read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0) break;
            if (destination.Length + read > maximumBytes)
            {
                throw new InvalidOperationException("Update response exceeded the maximum safe size.");
            }
            destination.Write(buffer, 0, read);
        }
        if (exactLength is { } required && destination.Length != required)
        {
            throw new InvalidOperationException("Update response length does not match the signed descriptor.");
        }
        return destination.ToArray();
    }

    private static Uri RequireHttpsUri(string value, string name)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out Uri? uri) ||
            !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            !string.IsNullOrEmpty(uri.UserInfo))
        {
            throw new InvalidOperationException($"The {name} URL must be an absolute HTTPS URL without user info.");
        }
        return uri;
    }

    public void Dispose()
    {
        if (_ownsHttpClient)
        {
            _httpClient.Dispose();
        }
    }
}
