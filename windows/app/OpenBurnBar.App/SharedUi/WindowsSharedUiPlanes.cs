using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.Presentation.Quota;
using OpenBurnBar.App.Presentation.SessionLogs;
using OpenBurnBar.App.Quota.Acquisition.Windows;
using OpenBurnBar.App.Settings.Winui;
using OpenBurnBar.App.Storage;
using OpenBurnBar.App.UsageRuntime;
using OpenBurnBar.Storage;
using Path = System.IO.Path;

namespace OpenBurnBar.App.SharedUi;

// MARK: - Windows backing planes
//
// The REAL implementations of the SharedUi dispatcher seams, composed over the
// app's in-process services (WPD-0006 single-process backend): the byte-compat
// SQLCipher store (usage + session-log FTS), the quota acquisition host, the
// ElderWand gateway route projection, the loopback model proxy, the OAuth
// credentials provider, the WinSparkle updater, and process actions. Every
// method emits RAW, daemon-shaped JSON pinned to the frontend mappers in
// apps/linux-desktop/src/tauriBridge.ts — the same shapes the Linux daemon
// returns for the equivalent RPCs.

/// <summary>Read-side data plane over the in-process stores.</summary>
internal sealed class WindowsSharedUiDataPlane : ISharedUiDataPlane
{
    public Task<JsonObject> GetRecentUsageAsync(int limit, CancellationToken ct)
    {
        var usage = new JsonArray();
        WithStorage(connection =>
        {
            foreach (var record in TokenUsageReadSeam.ListRecent(connection, limit))
            {
                usage.Add(new JsonObject
                {
                    ["id"] = record.Id,
                    ["providerId"] = record.Provider,
                    ["modelId"] = record.Model,
                    ["inputTokens"] = record.InputTokens,
                    ["outputTokens"] = record.OutputTokens,
                    ["cacheCreationTokens"] = record.CacheCreationTokens,
                    ["cacheReadTokens"] = record.CacheReadTokens,
                    ["reasoningTokens"] = record.ReasoningTokens,
                    ["tokens"] = record.TotalTokens,
                    ["costUsd"] = record.Cost,
                    ["recordedAt"] = ToIso(record.CreatedAt),
                    ["startTime"] = ToIso(record.StartTime),
                    ["sessionId"] = record.SessionId,
                    ["projectName"] = record.ProjectName,
                });
            }
        });
        return Task.FromResult(new JsonObject { ["usage"] = usage });
    }

    public async Task<JsonObject> ListSessionsAsync(int limit, CancellationToken ct)
    {
        var source = WindowsStorageDevHost.CreateSessionLogReadSource();
        var records = await source.ListAsync(limit, ct).ConfigureAwait(false);
        return await ProjectSessionsAsync(records, ct).ConfigureAwait(false);
    }

    public async Task<JsonObject> SearchSessionsAsync(string query, CancellationToken ct)
    {
        var source = WindowsStorageDevHost.CreateSessionLogReadSource();
        // FTS ids in rank order, projected over the loaded set — the Local-path
        // retrievalMatchedIDs behavior (ISessionLogReadSource doc).
        var matchedIds = await source.SearchMatchingIdsAsync(query, 200, ct).ConfigureAwait(false);
        var records = await source.ListAsync(500, ct).ConfigureAwait(false);
        var rank = new Dictionary<string, int>(StringComparer.Ordinal);
        for (int i = 0; i < matchedIds.Count; i += 1)
        {
            rank.TryAdd(matchedIds[i], i);
        }

        var ordered = records
            .Where(record => rank.ContainsKey(record.Id))
            .OrderBy(record => rank[record.Id])
            .ToArray();
        return await ProjectSessionsAsync(ordered, ct).ConfigureAwait(false);
    }

    private Task<JsonObject> ProjectSessionsAsync(IReadOnlyList<SessionLogRecord> records, CancellationToken ct)
    {
        // Join real per-session usage so rows never display fabricated zeros;
        // sessions without any usage rows keep an honest null (the frontend
        // renders 0 — the same as a genuinely zero-token session).
        var totalsBySession = new Dictionary<string, (long TotalTokens, double CostUsd)>(StringComparer.Ordinal);
        WithStorage(connection =>
        {
            var ids = records.Select(record => record.SessionId).Where(id => !string.IsNullOrEmpty(id)).ToArray();
            totalsBySession = new Dictionary<string, (long, double)>(
                TokenUsageReadSeam.LoadSessionTotals(connection, ids), StringComparer.Ordinal);
        });

        var sessions = new JsonArray();
        foreach (var record in records)
        {
            var hasTotals = totalsBySession.TryGetValue(record.SessionId, out var totals);
            sessions.Add(new JsonObject
            {
                ["id"] = record.Id,
                ["provider"] = record.Provider,
                ["model"] = string.Empty,
                ["startedAt"] = (record.StartTime ?? record.IndexedAt).ToString("O"),
                ["tokens"] = hasTotals ? totals.TotalTokens : 0,
                ["costUsd"] = hasTotals ? totals.CostUsd : 0.0,
                ["title"] = !string.IsNullOrWhiteSpace(record.SummaryTitle)
                    ? record.SummaryTitle
                    : !string.IsNullOrWhiteSpace(record.InferredTaskTitle)
                        ? record.InferredTaskTitle
                        : !string.IsNullOrWhiteSpace(record.ProjectName)
                            ? record.ProjectName
                            : "Untitled session",
            });
        }

        return Task.FromResult(new JsonObject
        {
            ["sessions"] = sessions,
            ["nextCursor"] = null,
        });
    }

    public Task<JsonObject> GetProviderCatalogAsync(CancellationToken ct)
    {
        var quotaByProvider = QuotaSnapshotsByProvider();
        var providers = new JsonArray();
        foreach (var group in App.Current.ElderWandProviderGroups())
        {
            var buckets = new JsonArray();
            if (quotaByProvider.TryGetValue(NormalizeProviderKey(group.ProviderName), out var snapshot))
            {
                foreach (var bucket in snapshot.Buckets)
                {
                    double usedPct = bucket.UsedPercent
                                     ?? (bucket.UsedValue is double used && bucket.LimitValue is double limit && limit > 0
                                         ? used / limit * 100.0
                                         : 0.0);
                    usedPct = Math.Clamp(usedPct, 0, 100);
                    buckets.Add(new JsonObject
                    {
                        ["id"] = bucket.Key,
                        ["label"] = bucket.Label,
                        ["usedPct"] = usedPct,
                        ["resetsAt"] = bucket.ResetsAt?.ToString("O"),
                        ["state"] = usedPct >= 100 ? "exhausted" : "ok",
                    });
                }
            }

            providers.Add(new JsonObject
            {
                ["id"] = NormalizeProviderKey(group.ProviderName),
                ["label"] = group.ProviderName,
                ["accountLabel"] = "Default",
                ["quotaBuckets"] = buckets,
            });
        }

        return Task.FromResult(new JsonObject { ["providers"] = providers });
    }

    public Task<JsonObject> GetConfigSnapshotAsync(CancellationToken ct)
    {
        var onboarding = new WindowsSharedUiOnboardingStateStore(WindowsSettingsComposition.SharedPersistence);
        var (telemetry, cloudSync, _) = onboarding.Load();
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var supportDir = Path.Combine(
            string.IsNullOrWhiteSpace(localAppData) ? Path.Combine(Path.GetTempPath(), "OpenBurnBar") : localAppData,
            "OpenBurnBar");

        var providerLogPaths = new JsonArray();
        try
        {
            foreach (var dir in WindowsUsagePaths.ForCurrentUser(includeConversationBodies: false).WatchDirectories)
            {
                if (Directory.Exists(dir))
                {
                    providerLogPaths.Add(dir);
                }
            }
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("shared-ui.provider-log-paths", ex);
        }

        var providers = new JsonArray();
        foreach (var group in App.Current.ElderWandProviderGroups())
        {
            providers.Add(new JsonObject
            {
                ["providerID"] = NormalizeProviderKey(group.ProviderName),
                ["isEnabled"] = true,
                ["baseURL"] = string.Empty,
                ["preferredModelIDs"] = new JsonArray(),
                ["disabledAdvertisedModelIDs"] = new JsonArray(),
                ["credentialSlots"] = new JsonArray(),
                ["modelVariants"] = new JsonArray(),
                ["modelAliases"] = new JsonArray(),
                ["modelDisplayOverrides"] = new JsonArray(),
                ["customModels"] = new JsonArray(),
            });
        }

        return Task.FromResult(new JsonObject
        {
            ["supportDir"] = supportDir,
            ["socketPath"] = string.Empty,
            ["configDir"] = supportDir,
            ["providerLogPaths"] = providerLogPaths,
            ["secretServiceStatus"] = "dpapi-protected-store",
            ["telemetryEnabled"] = telemetry,
            ["privacyOptIn"] = LoadPrivacyOptIn(),
            ["cloudSyncEnabled"] = cloudSync,
            ["providers"] = providers,
            ["routerMode"] = "providerFamilyFailover",
        });
    }

    public Task<JsonObject> ApplyConfigUpdateAsync(JsonObject snapshot, CancellationToken ct)
    {
        // The Settings surface edits the three privacy booleans through this
        // command; provider sub-objects are owned by the dedicated provider_*
        // commands (explicit not-implemented errors) and round-trip unchanged.
        var onboarding = new WindowsSharedUiOnboardingStateStore(WindowsSettingsComposition.SharedPersistence);
        var (telemetry, cloudSync, revision) = onboarding.Load();

        bool ReadBoolOr(JsonObject obj, string key, bool fallback) =>
            obj[key] is JsonValue v && v.TryGetValue(out bool b) ? b : fallback;

        // telemetryEnabled and privacyOptIn are DISTINCT booleans on the wire;
        // privacy opt-in lives in its own settings slot so a telemetry-only
        // edit never clobbers it (and vice versa) and the snapshot readback
        // always matches what was saved.
        telemetry = ReadBoolOr(snapshot, "telemetryEnabled", telemetry);
        var privacyOptIn = ReadBoolOr(snapshot, "privacyOptIn", LoadPrivacyOptIn());
        cloudSync = ReadBoolOr(snapshot, "cloudSyncEnabled", cloudSync);
        onboarding.Save(telemetry, cloudSync, revision + 1);
        SavePrivacyOptIn(privacyOptIn);
        return GetConfigSnapshotAsync(ct);
    }

    public Task<JsonObject> GetDatabaseStatusAsync(CancellationToken ct)
    {
        var status = WindowsStorageDevHost.Status;
        long sizeBytes = 0;
        long migrationCount = 0;
        var cipherOk = false;
        var (path, _) = WindowsStorageDevHost.ResolveCredentials();
        if (path is not null && File.Exists(path))
        {
            sizeBytes = new FileInfo(path).Length;
        }

        if (status.IsReady)
        {
            WithStorage(connection =>
            {
                migrationCount = SqlCipherConnection.ReadMigrationCount(connection);
                cipherOk = true;
            });
        }

        return Task.FromResult(new JsonObject
        {
            ["sqlcipherOk"] = cipherOk,
            ["migrationVersion"] = migrationCount,
            ["sizeBytes"] = sizeBytes,
            ["walMode"] = true,
        });
    }

    public Task<JsonObject> GetAccountStatusAsync(CancellationToken ct)
    {
        // mapAccountStatus (tauriBridgeSystemDecoders.ts) reads signedIn /
        // identityLabel / syncState from the TOP-LEVEL object (or a top-level
        // `status` object) — nesting them would decode as signed out.
        var oauth = WinAppCloudSyncHost.Root?.Credentials as DesktopOAuthCredentialsProvider;
        var signedIn = oauth?.IsSignedIn == true;
        return Task.FromResult(new JsonObject
        {
            ["state"] = signedIn ? "active" : "signed_out",
            ["signedIn"] = signedIn,
            ["identityLabel"] = signedIn ? oauth!.SignedInUid : null,
            ["syncState"] = signedIn ? "active" : "local-only",
            ["cloudSyncEnabled"] = signedIn,
        });
    }

    public Task<JsonObject> GetUpdateStatusAsync(CancellationToken ct)
    {
        var status = WindowsUpdateService.GetStatus(WindowsSettingsComposition.SharedPersistence);
        string? channel = status.Channel.Contains("stable", StringComparison.OrdinalIgnoreCase) ? "stable"
            : status.Channel.Contains("nightly", StringComparison.OrdinalIgnoreCase) ? "nightly"
            : status.Channel.Contains("pre", StringComparison.OrdinalIgnoreCase) ? "prerelease"
            : null;
        return Task.FromResult(new JsonObject
        {
            ["state"] = status.HostConfigured ? "current" : "unavailable",
            ["currentVersion"] = status.Version,
            ["channel"] = channel,
            ["notes"] = string.IsNullOrWhiteSpace(status.Message) ? null : status.Message,
            ["reason"] = status.HostConfigured
                ? "WinSparkle owns update discovery on Windows; check runs from the native settings."
                : "No update feed is configured for this build.",
            // NEVER emit `artifact`: the frontend validates artifact metadata
            // against the Linux package enums and would throw the whole command.
        });
    }

    public Task<JsonObject> GetAppVersionInfoAsync(CancellationToken ct)
    {
        var version = typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion;
        if (string.IsNullOrWhiteSpace(version))
        {
            version = Process.GetCurrentProcess().MainModule?.FileVersionInfo?.ProductVersion;
        }

        if (string.IsNullOrWhiteSpace(version))
        {
            version = "0.1.0";
        }

        return Task.FromResult(new JsonObject
        {
            ["shellVersion"] = version,
            ["daemonVersion"] = "windows-inproc",
            ["packageChannel"] = "unknown",
        });
    }

    public Task<JsonObject> GetProxyRouteLogAsync(int limit, CancellationToken ct)
    {
        var store = new GatewayRouteTelemetryStore(Path.Combine(
            WindowsSettingsComposition.SharedPersistence.DirectoryPath,
            "gateway-route-events.jsonl"));
        var entries = new JsonArray();
        foreach (var entry in store.Recent(limit))
        {
            entries.Add(new JsonObject
            {
                ["id"] = entry.Id,
                ["occurredAt"] = entry.StartedAt.ToString("O"),
                ["endpoint"] = entry.RequestPath,
                ["clientModelSlug"] = entry.ClientModel,
                ["routingModelSlug"] = entry.RoutedModel,
                ["upstreamModelSlug"] = entry.CanonicalModelId,
                ["providerName"] = entry.Vendor,
                ["accountLabel"] = entry.AccountId,
                ["finalStatus"] = entry.Succeeded ? "succeeded" : "failed",
                ["rewriteKind"] = string.Equals(entry.RoutedModel, entry.ClientModel, StringComparison.Ordinal) ? "none" : "rewrite",
                ["exactModelInvariant"] = "not_applicable",
                ["streamed"] = entry.Streamed,
                ["httpStatus"] = entry.StatusCode,
                ["failureMessage"] = null,
            });
        }

        return Task.FromResult(new JsonObject { ["entries"] = entries });
    }

    public Task<JsonObject> ClearProxyRouteLogAsync(CancellationToken ct)
    {
        // The telemetry store is append-only with retention; clearing means
        // truncating the JSONL file it loads from (fail-closed on IO errors).
        var path = Path.Combine(
            WindowsSettingsComposition.SharedPersistence.DirectoryPath,
            "gateway-route-events.jsonl");
        if (File.Exists(path))
        {
            File.WriteAllText(path, string.Empty);
        }

        return Task.FromResult(new JsonObject { ["cleared"] = true });
    }

    public Task<JsonObject> GetDatabaseWorkspaceStatusAsync(string? projectPath, CancellationToken ct)
    {
        // The never-reject 4-report bundle; daemon.code.* RPCs have no Windows
        // in-process equivalent in this shell yet — every report says so.
        const string error = SharedUiDispatcher.NotImplemented + ": daemon.code workspace RPCs (in-process shell)";
        JsonObject Report() => new() { ["ok"] = false, ["error"] = error };
        return Task.FromResult(new JsonObject
        {
            ["indexStatus"] = Report(),
            ["explore"] = Report(),
            ["diagnostics"] = Report(),
            ["opsDiagnostics"] = Report(),
        });
    }

    // ── helpers ──────────────────────────────────────────────────────────

    private const string PrivacyOptInKey = "sharedUiPrivacyOptIn";

    private sealed record PersistedPrivacyOptIn(bool Value)
    {
        public static PersistedPrivacyOptIn Default { get; } = new(false);
    }

    private static bool LoadPrivacyOptIn() =>
        WindowsSettingsComposition.SharedPersistence
            .Read(PrivacyOptInKey, PersistedPrivacyOptIn.Default).Value;

    private static void SavePrivacyOptIn(bool value) =>
        WindowsSettingsComposition.SharedPersistence
            .Write(PrivacyOptInKey, new PersistedPrivacyOptIn(value));

    private static void WithStorage(Action<Microsoft.Data.Sqlite.SqliteConnection> work)
    {
        var (path, passphrase) = WindowsStorageDevHost.ResolveCredentials();
        if (path is null || passphrase is null)
        {
            throw new SharedUiCommandException(
                SharedUiDispatcher.NotImplemented + ": local store credentials unavailable (typed recovery)");
        }

        using var store = OpenBurnBarStorage.OpenReadOnly(path, passphrase);
        work(store.Connection);
    }

    private static string ToIso(string grdbTimestamp) =>
        DateTimeOffset.TryParse(
            grdbTimestamp,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
            out var parsed)
            ? parsed.ToString("O")
            : grdbTimestamp;

    private static string NormalizeProviderKey(string providerName)
    {
        var builder = new StringBuilder(providerName.Length);
        foreach (var c in providerName)
        {
            if (char.IsLetterOrDigit(c))
            {
                builder.Append(char.ToLowerInvariant(c));
            }
        }

        return builder.ToString();
    }

    private static IReadOnlyDictionary<string, ProviderQuotaSnapshot> QuotaSnapshotsByProvider()
    {
        var snapshots = WindowsQuotaAcquisitionHost.Coordinator?.LatestSnapshots;
        if (snapshots is null)
        {
            return new Dictionary<string, ProviderQuotaSnapshot>(StringComparer.Ordinal);
        }

        var map = new Dictionary<string, ProviderQuotaSnapshot>(StringComparer.Ordinal);
        foreach (var snapshot in snapshots)
        {
            map[NormalizeProviderKey(snapshot.Provider)] = snapshot;
        }

        return map;
    }
}

/// <summary>The loopback model-proxy chat gateway (LocalHttpGatewayHost).</summary>
internal sealed class WindowsSharedUiGatewayPlane : ISharedUiGatewayPlane
{
    private const int MaxBoundedErrorDetail = 4096;

    private static readonly HttpClient Http = new(new HttpClientHandler { AllowAutoRedirect = false })
    {
        Timeout = TimeSpan.FromSeconds(120),
    };

    private readonly ConcurrentDictionary<string, CancellationTokenSource> _inFlight = new(StringComparer.Ordinal);

    public async Task<bool> ProbeAsync(CancellationToken ct)
    {
        if (App.Current.LocalGatewayBaseAddress is not { } baseAddress)
        {
            return false;
        }

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(baseAddress, "/health"));
            ApplyAuth(request);
            using var response = await Http.SendAsync(request, ct).ConfigureAwait(false);
            return response.IsSuccessStatusCode;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public void CancelChat(string requestId)
    {
        if (_inFlight.TryRemove(requestId, out var cts))
        {
            try
            {
                cts.Cancel();
            }
            catch (ObjectDisposedException)
            {
                // The stream completed between the remove and the cancel — fine.
            }
        }
    }

    public async Task StreamChatAsync(
        JsonObject request,
        Func<string, CancellationToken, Task> onChunk,
        CancellationToken ct)
    {
        // The dispatcher validated the request shape; re-read the pinned fields.
        var requestId = request["requestId"]!.GetValue<string>();
        var model = request["model"]!.GetValue<string>().Trim();
        var messages = (JsonArray)request["messages"]!.DeepClone();

        if (App.Current.LocalGatewayBaseAddress is not { } baseAddress)
        {
            throw new SharedUiCommandException("gateway_disabled");
        }

        var token = App.Current.LocalGatewayAccessToken;
        if (string.IsNullOrWhiteSpace(token))
        {
            throw new SharedUiCommandException("gateway_token_unavailable");
        }

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        if (!_inFlight.TryAdd(requestId, cts))
        {
            throw new SharedUiCommandException("gateway_invalid_request_id");
        }

        try
        {
            var body = new JsonObject
            {
                ["model"] = model,
                ["stream"] = true,
                ["stream_options"] = new JsonObject { ["include_usage"] = true },
                ["messages"] = messages,
            };

            using var httpRequest = new HttpRequestMessage(
                HttpMethod.Post, new Uri(baseAddress, "/v1/chat/completions"))
            {
                Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
            };
            httpRequest.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
            httpRequest.Headers.Accept.ParseAdd("text/event-stream");

            HttpResponseMessage response;
            try
            {
                response = await Http.SendAsync(httpRequest, HttpCompletionOption.ResponseHeadersRead, cts.Token)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                throw new SharedUiCommandException("gateway_aborted");
            }
            catch (HttpRequestException ex)
            {
                throw new SharedUiCommandException($"gateway_unreachable:{ex.Message}");
            }

            using (response)
            {
                if (!response.IsSuccessStatusCode)
                {
                    var detail = await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
                    if (detail.Length > MaxBoundedErrorDetail)
                    {
                        detail = detail[..MaxBoundedErrorDetail];
                    }

                    throw new SharedUiCommandException($"gateway_http:{(int)response.StatusCode}:{detail}");
                }

                var contentType = response.Content.Headers.ContentType?.MediaType ?? string.Empty;
                if (!string.Equals(contentType, "text/event-stream", StringComparison.OrdinalIgnoreCase))
                {
                    throw new SharedUiCommandException("gateway_invalid_content_type");
                }

                await PumpStreamAsync(response, onChunk, cts.Token).ConfigureAwait(false);
            }
        }
        finally
        {
            _inFlight.TryRemove(requestId, out _);
        }
    }

    private static async Task PumpStreamAsync(
        HttpResponseMessage response,
        Func<string, CancellationToken, Task> onChunk,
        CancellationToken ct)
    {
        await using var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        var buffer = new byte[16 * 1024];
        var pending = Array.Empty<byte>();
        long total = 0;
        var decoder = Encoding.UTF8.GetDecoder();
        decoder.Fallback = DecoderFallback.ExceptionFallback;

        while (true)
        {
            int read;
            try
            {
                read = await stream.ReadAsync(buffer, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                throw new SharedUiCommandException("gateway_aborted");
            }
            catch (Exception ex)
            {
                throw new SharedUiCommandException($"gateway_stream_interrupted:{ex.Message}");
            }

            if (read == 0)
            {
                break;
            }

            total += read;
            if (total > SharedUiGatewayChatValidator.MaxResponseBytes)
            {
                throw new SharedUiCommandException("gateway_response_too_large");
            }

            var combined = new byte[pending.Length + read];
            pending.CopyTo(combined, 0);
            Array.Copy(buffer, 0, combined, pending.Length, read);

            // UTF-8 boundary safety, mirroring the Rust pending_utf8 loop: the
            // decoder consumes complete sequences only (flush:false); a truly
            // invalid sequence throws → gateway_invalid_utf8.
            var chars = new char[combined.Length];
            int bytesUsed;
            int charsUsed;
            try
            {
                decoder.Convert(combined, 0, combined.Length, chars, 0, chars.Length, false,
                    out bytesUsed, out charsUsed, out _);
            }
            catch (DecoderFallbackException)
            {
                throw new SharedUiCommandException("gateway_invalid_utf8");
            }

            if (charsUsed > 0)
            {
                await onChunk(new string(chars, 0, charsUsed), ct).ConfigureAwait(false);
            }

            pending = combined[bytesUsed..];
        }

        if (pending.Length > 0)
        {
            throw new SharedUiCommandException("gateway_invalid_utf8");
        }
    }

    private void ApplyAuth(HttpRequestMessage request)
    {
        var token = App.Current.LocalGatewayAccessToken;
        if (!string.IsNullOrWhiteSpace(token))
        {
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
        }
    }
}

/// <summary>Process/OS actions.</summary>
internal sealed class WindowsSharedUiSystemPlane : ISharedUiSystemPlane
{
    public bool TrayDegraded =>
        Environment.GetEnvironmentVariable("OPENBURNBAR_FORCE_TRAY_DEGRADED") == "1"
        || !WindowsStorageDevHost.Status.IsReady;

    public void OpenDashboard() => App.Current.ShowSharedUiWindow();

    public void Quit() => App.Current.RequestExit();

    public void OpenExternalUrl(string validatedUrl) =>
        ChildProcessLaunchPolicy.StartDefaultBrowser(new Uri(validatedUrl));

    public void OpenUpdateUrl(string validatedUrl) =>
        ChildProcessLaunchPolicy.StartDefaultBrowser(new Uri(validatedUrl));

    public string ExportDiagnostics() => AppDiagnostics.CreateSupportBundle().BundlePath;
}

/// <summary>SharedUi composition root (repo convention: static *Composition).</summary>
internal static class SharedUiComposition
{
    /// <summary>Build the dispatcher with the live Windows planes.</summary>
    public static SharedUiDispatcher CreateDispatcher() =>
        new(new SharedUiDispatcherOptions
        {
            ShellVersion = ResolveShellVersion(),
            Data = new WindowsSharedUiDataPlane(),
            Gateway = new WindowsSharedUiGatewayPlane(),
            System = new WindowsSharedUiSystemPlane(),
            OnboardingStore = new WindowsSharedUiOnboardingStateStore(WindowsSettingsComposition.SharedPersistence),
            CapabilityStatus = BuildCapabilityStatus,
        });

    /// <summary>Live capability probes for the runtime manifest + daemon_health.</summary>
    public static SharedUiCapabilityStatus BuildCapabilityStatus()
    {
        var storageReady = WindowsStorageDevHost.Status.IsReady;
        var gatewayRunning = App.Current.LocalGatewayBaseAddress is not null;
        var oauth = WinAppCloudSyncHost.Root?.Credentials as DesktopOAuthCredentialsProvider;
        return new SharedUiCapabilityStatus
        {
            StorageReady = storageReady,
            SessionLogsReady = storageReady,
            GatewayRunning = gatewayRunning,
            GatewayPort = gatewayRunning ? App.Current.LocalGatewayPort : null,
            CloudSignedIn = oauth?.IsSignedIn == true,
            TrayReady = App.Current.TrayReady,
            NotificationsReady = true,
            UpdatesConfigured = WindowsUpdateService.GetStatus(WindowsSettingsComposition.SharedPersistence).HostConfigured,
        };
    }

    private static string ResolveShellVersion()
    {
        var version = typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion;
        return string.IsNullOrWhiteSpace(version) ? "0.1.0" : version;
    }
}
