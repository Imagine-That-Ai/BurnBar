using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Quota;

namespace OpenBurnBar.App.Quota.Acquisition.Windows;

// Static composition root for the acquisition layer — the same fail-soft shape
// as windows/app/OpenBurnBar.App.CloudSync/WinAppCloudSyncHost.cs: the WinUI app
// calls ConfigureDefault() once at launch; pages read the nullable Coordinator
// and degrade gracefully when it is absent.

/// <summary>Process-wide acquisition host the WinUI app configures at launch.</summary>
public static class WindowsQuotaAcquisitionHost
{
    /// <summary>Set to <c>1</c> to keep the host dormant (dev-host escape hatch).</summary>
    public const string DisableEnvVar = "OPENBURNBAR_DISABLE_QUOTA_ACQUISITION";

    /// <summary>Anthropic credential override; falls back to <c>ANTHROPIC_API_KEY</c>.</summary>
    public const string AnthropicCredentialEnvVar = "OPENBURNBAR_ANTHROPIC_CREDENTIAL";

    private static readonly object Gate = new();
    private static QuotaAcquisitionCoordinator? _coordinator;
    private static HttpClient? _httpClient;

    /// <summary>The live coordinator, or <c>null</c> when unconfigured/disabled.</summary>
    public static QuotaAcquisitionCoordinator? Coordinator
    {
        get
        {
            lock (Gate)
            {
                return _coordinator;
            }
        }
    }

    /// <summary>
    /// Build the default source set (statusline file + watcher, Cursor state.vscdb,
    /// Codex auth.json, Anthropic probe when a credential env var is present).
    /// Fail-soft and idempotent.
    /// </summary>
    public static void ConfigureDefault()
    {
        if (Environment.GetEnvironmentVariable(DisableEnvVar) == "1")
        {
            return;
        }

        lock (Gate)
        {
            if (_coordinator is not null)
            {
                return;
            }

            try
            {
                _httpClient = new HttpClient { Timeout = QuotaAcquisitionPolicy.HttpTimeout };
                var transport = new HttpClientQuotaTransport(_httpClient);

                string snapshotPath = WindowsQuotaAcquisitionPaths.ClaudeStatuslineSnapshotPath();
                var sources = new List<IQuotaPayloadSource>
                {
                    new ClaudeStatuslinePayloadSource(snapshotPath),
                    new CursorUsageQuotaSource(transport, ReadCursorCredentials),
                    new CodexUsageQuotaSource(transport, WindowsQuotaAcquisitionPaths.CodexHomeDirectory()),
                };

                string? anthropicCredential =
                    FirstNonEmpty(
                        Environment.GetEnvironmentVariable(AnthropicCredentialEnvVar),
                        Environment.GetEnvironmentVariable("ANTHROPIC_API_KEY"));
                if (anthropicCredential is not null)
                {
                    var store = new AnthropicRateLimitHeaderStore();
                    var probe = new AnthropicCredentialProbe(transport, anthropicCredential);
                    sources.Add(new AnthropicRateLimitQuotaSource(store, probe));
                }

                var coordinator = new QuotaAcquisitionCoordinator(sources);
                coordinator.AttachWatcher(
                    new FileSystemQuotaFileWatcher(snapshotPath),
                    ClaudeStatuslinePayloadSource.DefaultSourceId);
                _coordinator = coordinator;
            }
            catch (Exception)
            {
                // Fail-soft (WinAppCloudSyncHost discipline): a broken host must
                // never take the app down — the quota page falls back to B4/sample.
                _coordinator = null;
                _httpClient?.Dispose();
                _httpClient = null;
            }
        }
    }

    /// <summary>Refresh all sources; empty on any host-level failure.</summary>
    public static async Task<IReadOnlyList<ProviderQuotaSnapshot>> TryRefreshAsync()
    {
        QuotaAcquisitionCoordinator? coordinator = Coordinator;
        if (coordinator is null)
        {
            return Array.Empty<ProviderQuotaSnapshot>();
        }

        try
        {
            return await coordinator.RefreshAsync().ConfigureAwait(false);
        }
        catch (Exception)
        {
            return Array.Empty<ProviderQuotaSnapshot>();
        }
    }

    /// <summary>Tear down (tests).</summary>
    public static void ResetForTests()
    {
        lock (Gate)
        {
            _coordinator?.Dispose();
            _coordinator = null;
            _httpClient?.Dispose();
            _httpClient = null;
        }
    }

    private static CursorStateCredentials? ReadCursorCredentials()
    {
        foreach (string candidate in WindowsQuotaAcquisitionPaths.CursorStateDbCandidates())
        {
            if (File.Exists(candidate) && CursorStateDbReader.TryRead(candidate) is { } credentials)
            {
                return credentials;
            }
        }

        return null;
    }

    private static string? FirstNonEmpty(params string?[] values)
    {
        foreach (string? value in values)
        {
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }

        return null;
    }
}
