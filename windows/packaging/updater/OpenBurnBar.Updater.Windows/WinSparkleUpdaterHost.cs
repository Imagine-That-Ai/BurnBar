// The WinSparkle-backed IUpdaterHost. Configures WinSparkle with the appcast
// URL + the pinned Ed25519 key + app details, drives the native update UX, and
// re-verifies every downloaded artifact through the portable Core verifier
// before install (defense-in-depth: WinSparkle also verifies natively, but the
// Core is the authority the app trusts).

using System;
using System.Runtime.Versioning;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Updater.Core.Host;
using OpenBurnBar.Updater.Core.Verification;
using OpenBurnBar.Updater.Windows.Interop;

namespace OpenBurnBar.Updater.Windows;

/// <summary>Drives WinSparkle behind the portable <see cref="IUpdaterHost"/> seam.</summary>
[SupportedOSPlatform("windows")]
public sealed class WinSparkleUpdaterHost : IUpdaterHost, IDisposable
{
    private readonly string _companyName;
    private readonly string _appName;

    private UpdaterConfiguration? _configuration;
    private UpdateFeedVerifier? _verifier;
    private bool _initialized;

    public WinSparkleUpdaterHost(string companyName = "Imagine That", string appName = "OpenBurnBar")
    {
        _companyName = companyName;
        _appName = appName;
    }

    /// <inheritdoc />
    public void Configure(UpdaterConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        _configuration = configuration;
        _verifier = configuration.CreateVerifier();

        WinSparkleNative.SetAppcastUrl(configuration.AppcastUrl);
        // The R19 pin: WinSparkle refuses any enclosure whose edSignature does
        // not verify against this key. Same key the Core verifier holds.
        WinSparkleNative.SetEddsaPublicKey(configuration.PinnedKey.Base64);
        WinSparkleNative.SetAppDetails(_companyName, _appName, configuration.CurrentVersion.ToString());
        WinSparkleNative.SetAutomaticCheckForUpdates(1);

        if (!_initialized)
        {
            WinSparkleNative.Init();
            _initialized = true;
        }
    }

    /// <inheritdoc />
    public Task CheckForUpdatesWithUiAsync(CancellationToken cancellationToken = default)
    {
        EnsureConfigured();
        cancellationToken.ThrowIfCancellationRequested();
        WinSparkleNative.CheckUpdateWithUi();
        return Task.CompletedTask;
    }

    /// <inheritdoc />
    public Task CheckForUpdatesInBackgroundAsync(CancellationToken cancellationToken = default)
    {
        EnsureConfigured();
        cancellationToken.ThrowIfCancellationRequested();
        WinSparkleNative.CheckUpdateWithoutUi();
        return Task.CompletedTask;
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

    public void Dispose()
    {
        if (_initialized)
        {
            WinSparkleNative.Cleanup();
            _initialized = false;
        }
    }
}
