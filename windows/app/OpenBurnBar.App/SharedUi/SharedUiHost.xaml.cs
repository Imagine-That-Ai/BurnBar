using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.Theme;
using OpenBurnBar.App.UsageRuntime;

namespace OpenBurnBar.App.SharedUi;

/// <summary>
/// Hosts the Linux desktop frontend (the vite <c>--mode windows</c> build vendored under
/// <c>Resources/SharedUi</c>) in a WebView2 and serves its Tauri-shaped command surface
/// from in-process Windows services — the same architecture as the Linux Tauri backend
/// (thin command dispatcher), with WebView2 <c>chrome.webview.postMessage</c> as the
/// transport instead of Tauri IPC. Protocol mirror of
/// <c>apps/linux-desktop/src/shim/tauriWebviewShim.ts</c>.
///
/// Command coverage v1: shell health/version/update/capabilities/onboarding, window and
/// URL verbs, diagnostics export, usage summary + provider catalog + session list (from the
/// usage runtime), and gateway chat streaming (SSE via <see cref="LocalHttpGatewayHost"/>).
/// Every other command answers "not implemented on Windows", which the frontend's
/// <c>isCapabilityAbsentError</c> maps to its graceful-degrade path — the same contract the
/// Linux backend uses for absent capabilities.
/// </summary>
public sealed partial class SharedUiHost : UserControl
{
    private const string VirtualHost = "app.openburnbar.invalid";

    private readonly ThemeService _theme;
    private readonly IUsageRuntime? _usageRuntime;
    private readonly LocalHttpGatewayHost? _gateway;
    private readonly string? _gatewayToken;
    private readonly Dictionary<string, CancellationTokenSource> _streams = new(StringComparer.Ordinal);
    private readonly object _streamsLock = new();
    private CoreWebView2? _core;
    private string _pendingRoute = "overview";
    private bool _started;
    private bool _disposed;

    public SharedUiHost(ThemeService theme, IUsageRuntime? usageRuntime, LocalHttpGatewayHost? gateway, string? gatewayToken)
    {
        _theme = theme;
        _usageRuntime = usageRuntime;
        _gateway = gateway;
        _gatewayToken = gatewayToken;
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private static string AppVersion =>
        typeof(SharedUiHost).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        await StartAsync();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _disposed = true;
        lock (_streamsLock)
        {
            foreach (CancellationTokenSource stream in _streams.Values)
            {
                stream.Cancel();
            }
            _streams.Clear();
        }
    }

    public async Task StartAsync()
    {
        if (_started || _disposed)
        {
            return;
        }
        _started = true;

        string resourceDir = Path.Combine(AppContext.BaseDirectory, "Resources", "SharedUi");
        if (!File.Exists(Path.Combine(resourceDir, "index.html")))
        {
            ShowFallback($"Shared UI assets missing at {resourceDir}");
            return;
        }

        try
        {
            await WebView.EnsureCoreWebView2Async();
            if (_disposed)
            {
                return;
            }

            _core = WebView.CoreWebView2;
            _core.Settings.AreDevToolsEnabled = false;
            _core.Settings.AreDefaultContextMenusEnabled = false;
            _core.Settings.IsStatusBarEnabled = false;
            _core.WebMessageReceived += OnWebMessageReceived;
            _core.SetVirtualHostNameToFolderMapping(
                VirtualHost, resourceDir, CoreWebView2HostResourceAccessKind.Allow);
            _core.Navigate($"https://{VirtualHost}/index.html#/{_pendingRoute}");
        }
        catch (Exception ex)
        {
            ShowFallback($"WebView2 init failed: {ex.GetType().Name}: {ex.Message}");
        }
    }

    private void ShowFallback(string message)
    {
        FallbackText.Text = $"Shared UI unavailable — {message}. Set OPENBURNBAR_XAML_SHELL=1 for the native shell.";
        FallbackNotice.Visibility = Visibility.Visible;
    }

    // MARK: - Transport

    private void OnWebMessageReceived(CoreWebView2 sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        JsonElement root;
        try
        {
            using JsonDocument doc = JsonDocument.Parse(e.WebMessageAsJson);
            root = doc.RootElement.Clone();
        }
        catch (JsonException)
        {
            return;
        }

        if (root.TryGetProperty("kind", out JsonElement kindEl) && kindEl.GetString() == "invoke")
        {
            _ = HandleInvokeAsync(root);
        }
        // kind == "listen": no push events on Windows yet (media plane absent); registration
        // is accepted silently so the frontend's listen() promise resolves.
    }

    private async Task HandleInvokeAsync(JsonElement message)
    {
        int id = message.GetProperty("id").GetInt32();
        string command = message.TryGetProperty("command", out JsonElement cmdEl)
            ? cmdEl.GetString() ?? string.Empty
            : string.Empty;
        JsonElement args = message.TryGetProperty("args", out JsonElement argsEl) ? argsEl : default;

        try
        {
            object? value = await DispatchAsync(command, args);
            await PushAsync(new { kind = "invoke-result", id, ok = true, value });
        }
        catch (Exception ex)
        {
            await PushAsync(new { kind = "invoke-result", id, ok = false, error = ex.Message });
        }
    }

    private async Task PushAsync(object payload)
    {
        if (_core is null || _disposed)
        {
            return;
        }
        string script = $"window.__obbShimDispatch({JsonSerializer.Serialize(payload)})";
        await _core.ExecuteScriptAsync(script);
    }

    public void Navigate(string routeKey)
    {
        _pendingRoute = MapShellRoute(routeKey);
        if (_core is not null && !_disposed)
        {
            _ = _core.ExecuteScriptAsync(
                $"window.location.hash = {JsonSerializer.Serialize($"#/{_pendingRoute}")}");
        }
    }

    private static string MapShellRoute(string routeKey) => routeKey switch
    {
        "dashboard" or "home" => "overview",
        "dataControlCenter" => "database",
        "missionControl" => "missions",
        "quota" => "providers",
        "sessionLogs" => "activity",
        "elderWand" => "chat",
        "overview" or "insights" or "database" or "providers" or "projects" or "missions"
            or "activity" or "chat" or "memory" or "settings" or "updates" or "support"
            or "onboarding" => routeKey,
        _ => "overview",
    };

    // MARK: - Command surface

    private Task<object?> DispatchAsync(string command, JsonElement args) => command switch
    {
        "daemon_health" => Task.FromResult<object?>(new
        {
            ok = true,
            protocolVersion = 1,
            daemonVersion = AppVersion,
            socketPath = "inproc-shared-ui",
            gatewayEnabled = _gateway is not null,
            gatewayHost = "127.0.0.1",
            gatewayPort = _gateway?.Port ?? 0,
        }),
        "app_version_info" => Task.FromResult<object?>(new
        {
            shellVersion = AppVersion,
            daemonVersion = AppVersion,
            packageChannel = "unknown",
        }),
        "update_status" => Task.FromResult<object?>(new { state = "current", currentVersion = AppVersion }),
        "runtime_capabilities" => Task.FromResult<object?>(BuildCapabilityManifest()),
        "onboarding_snapshot" or "onboarding_reset" or "onboarding_action" =>
            Task.FromResult<object?>(BuildOnboardingSnapshot()),
        "subscription_start" => Task.FromResult<object?>(BuildSubscriptionResponse(args, resume: false)),
        "subscription_resume" => Task.FromResult<object?>(BuildSubscriptionResponse(args, resume: true)),
        "subscription_stop" => Task.FromResult<object?>(BuildSubscriptionStopResponse(args)),
        "session_env" => Task.FromResult<object?>(new { sessionType = "local", desktop = "windows" }),
        "tray_degraded" => Task.FromResult<object?>(false),
        "open_dashboard" => Task.FromResult<object?>(true),
        "quit_app" => QuitApp(),
        "open_external_url" => OpenExternalUrl(args),
        "open_update_url" => OpenExternalUrlRaw("https://github.com/Imagine-That-Ai/BurnBar/releases"),
        "export_diagnostics" => ExportDiagnostics(),
        "gateway_probe" => Task.FromResult<object?>(_gateway is not null),
        "gateway_chat_stream" => StartChatStreamAsync(args),
        "gateway_chat_cancel" => CancelChatStream(args),
        "usage_summary" or "usage_insights" => Task.FromResult<object?>(BuildUsageEvents()),
        "provider_catalog" => Task.FromResult<object?>(BuildProviderCatalog()),
        "session_list" => Task.FromResult<object?>(BuildSessionList(args)),
        "session_search" => Task.FromResult<object?>(BuildSessionList(args)),
        _ => throw new NotSupportedException($"not implemented on Windows: '{command}'"),
    };

    private Task<object?> QuitApp()
    {
        Microsoft.UI.Xaml.Application.Current.Exit();
        return Task.FromResult<object?>(true);
    }

    private Task<object?> OpenExternalUrl(JsonElement args)
    {
        string url = args.TryGetProperty("url", out JsonElement urlEl) ? urlEl.GetString() ?? string.Empty : string.Empty;
        return OpenExternalUrlRaw(url);
    }

    private Task<object?> OpenExternalUrlRaw(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out Uri? uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            throw new ArgumentException($"refusing to open non-http(s) url: {url}");
        }

        // Through the reviewed child-process policy (explorer.exe <url>, scrubbed env) —
        // never a raw Process.Start (the Configuration policy tests enforce this).
        ChildProcessLaunchPolicy.StartDefaultBrowser(uri);
        return Task.FromResult<object?>(true);
    }

    private Task<object?> ExportDiagnostics()
    {
        var report = new
        {
            exportedAt = DateTimeOffset.UtcNow.ToString("o"),
            shellVersion = AppVersion,
            host = "windows-shared-ui",
            gatewayEnabled = _gateway is not null,
        };
        string path = Path.Combine(Path.GetTempPath(), $"openburnbar-diagnostics-{DateTimeOffset.UtcNow:yyyyMMdd-HHmmss}.json");
        File.WriteAllText(path, JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
        return Task.FromResult<object?>(new { path });
    }

    // MARK: - Capability manifest + onboarding (shape mirrors the frontend decoders)

    private static object BuildCapabilityManifest()
    {
        var available = new HashSet<string>(StringComparer.Ordinal)
        {
            "usage.read", "sessions.read", "chat.gateway", "native.tray",
            "updates.check", "support.export", "onboarding.repair",
        };
        (string Id, string Domain)[] catalog =
        {
            ("usage.read", "product"), ("database.read", "product"), ("providers.configure", "product"),
            ("projects.read", "product"), ("missions.manage", "product"), ("sessions.read", "product"),
            ("chat.gateway", "product"), ("memory.review", "product"), ("computer-use.browser", "security"),
            ("computer-use.system", "security"), ("media.mercury", "product"), ("smarthub.control", "product"),
            ("settings.read", "product"), ("account.read", "product"), ("updates.check", "delivery"),
            ("updates.install", "delivery"), ("support.export", "product"), ("onboarding.repair", "product"),
            ("pet.overlay", "product"), ("text-expansion.in-app", "product"), ("text-expansion.system", "platform"),
            ("secrets.secret-service", "platform"), ("secrets.kwallet", "platform"), ("portal.desktop", "platform"),
            ("native.tray", "platform"), ("native.notifications", "platform"), ("native.external-billing", "delivery"),
        };

        var capabilities = catalog.Select(entry => new
        {
            id = entry.Id,
            domain = entry.Domain,
            state = available.Contains(entry.Id) ? "available" : "unavailable",
            reason = available.Contains(entry.Id)
                ? "Served by the Windows shared-UI host."
                : "Not yet served by the Windows shared-UI host.",
            substitute = (string?)null,
            source = "windows-shared-ui-host",
        }).ToArray();

        string now = DateTimeOffset.UtcNow.ToString("o");
        return new
        {
            schemaVersion = 1,
            catalogVersion = "windows-shared-ui-1",
            shellVersion = AppVersion,
            daemonVersion = AppVersion,
            daemonProtocolVersion = 1,
            sessionType = "local",
            desktop = "windows",
            capabilities,
        };
    }

    private static object BuildOnboardingSnapshot()
    {
        (string Id, string Requirement, string State)[] rows =
        {
            ("daemon", "required", "verified"),
            ("secret_store", "required", "verified"),
            ("provider_paths", "required", "verified"),
            ("cloud_identity", "optional", "acknowledged"),
            ("portal_input", "optional", "acknowledged"),
            ("tray", "optional", "acknowledged"),
            ("updates", "optional", "acknowledged"),
            ("privacy", "required", "verified"),
        };
        var steps = rows.Select(r => new { id = r.Id, requirement = r.Requirement, state = r.State, attemptCount = 0 }).ToArray();
        return new
        {
            schemaVersion = 1,
            revision = 1,
            currentStepID = "privacy",
            steps,
            privacyChoices = new { telemetryEnabled = false, cloudSyncEnabled = false },
            completed = true,
            updatedAt = now,
        };
    }

    // MARK: - Usage-backed surfaces

    private object BuildUsageEvents()
    {
        IReadOnlyList<UsageEngineRecord> usages = _usageRuntime?.State.Snapshot.Usages
            ?? Array.Empty<UsageEngineRecord>();
        var events = usages
            .OrderByDescending(u => u.StartUnixMilliseconds)
            .Select(u => new
            {
                id = u.Id,
                providerId = u.ProviderId,
                provider = u.Provider,
                modelId = u.Model,
                model = u.Model,
                tokens = u.TotalTokens,
                totalTokens = u.TotalTokens,
                inputTokens = u.InputTokens,
                outputTokens = u.OutputTokens,
                cacheCreationTokens = u.CacheCreationTokens,
                cacheReadTokens = u.CacheReadTokens,
                costUsd = u.CostUsd,
                at = DateTimeOffset.FromUnixTimeMilliseconds(u.StartUnixMilliseconds).ToString("o"),
            })
            .ToArray();
        return new { usage = events };
    }

    private object BuildProviderCatalog()
    {
        IReadOnlyList<UsageEngineRecord> usages = _usageRuntime?.State.Snapshot.Usages
            ?? Array.Empty<UsageEngineRecord>();
        return usages
            .GroupBy(u => u.Provider)
            .OrderByDescending(g => g.Sum(u => u.CostNanoUsd))
            .Select(g => new
            {
                id = g.Key,
                label = g.Key,
                accountLabel = g.Select(u => u.ProviderAccountLabel).FirstOrDefault(l => !string.IsNullOrWhiteSpace(l)) ?? g.Key,
                quotaBuckets = Array.Empty<object>(),
            })
            .ToArray();
    }

    private object BuildSessionList(JsonElement args)
    {
        int limit = args.ValueKind == JsonValueKind.Object && args.TryGetProperty("limit", out JsonElement limitEl)
            ? Math.Clamp(limitEl.GetInt32(), 1, 500)
            : 50;
        IReadOnlyList<UsageEngineRecord> usages = _usageRuntime?.State.Snapshot.Usages
            ?? Array.Empty<UsageEngineRecord>();

        string query = GetStringFlexible(args, "query")?.Trim() ?? string.Empty;
        IEnumerable<UsageEngineRecord> filtered = string.IsNullOrEmpty(query)
            ? usages
            : usages.Where(u =>
                u.SessionId.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                u.ProjectName.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                u.Provider.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                u.Model.Contains(query, StringComparison.OrdinalIgnoreCase));

        var sessions = filtered
            .GroupBy(u => u.SessionId)
            .Select(g =>
            {
                UsageEngineRecord latest = g.OrderByDescending(u => u.StartUnixMilliseconds).First();
                return new
                {
                    id = g.Key,
                    provider = latest.Provider,
                    model = latest.Model,
                    startedAt = DateTimeOffset.FromUnixTimeMilliseconds(g.Min(u => u.StartUnixMilliseconds)).ToString("o"),
                    tokens = g.Sum(u => u.TotalTokens),
                    costUsd = g.Sum(u => u.CostNanoUsd) / 1e9,
                    title = latest.ProjectName,
                };
            })
            .OrderByDescending(s => s.startedAt)
            .Take(limit)
            .ToArray();

        return new { sessions, nextCursor = (string?)null };
    }

    private static object BuildSubscriptionResponse(JsonElement args, bool resume)
    {
        JsonElement request = args.ValueKind == JsonValueKind.Object &&
            args.TryGetProperty("request", out JsonElement requestElement)
                ? requestElement
                : args;
        string subscriptionId = GetStringFlexible(
                request, "subscription_id", "subscriptionId", "requested_subscription_id", "requestedSubscriptionId")
            ?? Guid.NewGuid().ToString("N");
        string topic = GetStringFlexible(request, "topic") ?? "data";
        long afterSequence = request.ValueKind == JsonValueKind.Object &&
            request.TryGetProperty("after_seq", out JsonElement sequenceElement) &&
            sequenceElement.TryGetInt64(out long sequence)
                ? sequence
                : 0;
        long nextSequence = resume ? checked(afterSequence + 1) : 1;
        return new
        {
            subscription_id = subscriptionId,
            topic,
            seq = nextSequence,
            cursor = nextSequence.ToString(System.Globalization.CultureInfo.InvariantCulture),
            first_snapshot = !resume,
            events = Array.Empty<object>(),
            degraded_fallback = true,
            degradation_reason = "Windows shared UI uses bounded polling over the in-process usage snapshot.",
            backpressure = "coalesce_latest_per_topic",
            disconnect_detected = false,
            recovered_after_restart = false,
            terminal_state_delivered = false,
        };
    }

    private static object BuildSubscriptionStopResponse(JsonElement args)
    {
        JsonElement request = args.ValueKind == JsonValueKind.Object &&
            args.TryGetProperty("request", out JsonElement requestElement)
                ? requestElement
                : args;
        return new
        {
            subscription_id = GetStringFlexible(request, "subscription_id", "subscriptionId") ?? "windows-shared-ui",
            stopped = true,
            last_seq = 0,
        };
    }

    // MARK: - Gateway chat streaming (mirrors apps/linux-desktop/src-tauri gateway_chat_stream)

    private async Task<object?> StartChatStreamAsync(JsonElement args)
    {
        if (_gateway is null)
        {
            throw new NotSupportedException("chat gateway is not running on this host");
        }

        JsonElement request = args.GetProperty("request");
        string requestId = GetStringFlexible(request, "requestId", "request_id") ?? Guid.NewGuid().ToString("N");
        int channelId = args.GetProperty("onEvent").GetProperty("__channel").GetInt32();
        string model = GetStringFlexible(request, "model") ?? string.Empty;
        string messages = request.TryGetProperty("messages", out JsonElement messagesEl)
            ? messagesEl.GetRawText()
            : "[]";

        var cancellation = new CancellationTokenSource();
        lock (_streamsLock)
        {
            _streams[requestId] = cancellation;
        }

        try
        {
            string body = "{\"model\":" + JsonSerializer.Serialize(model)
                + ",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":"
                + messages + "}";

            using var http = new HttpClient { BaseAddress = _gateway.BaseAddress, Timeout = Timeout.InfiniteTimeSpan };
            if (!string.IsNullOrEmpty(_gatewayToken))
            {
                http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", _gatewayToken);
            }
            http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));

            using var requestMessage = new HttpRequestMessage(HttpMethod.Post, "/v1/chat/completions")
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
            using HttpResponseMessage response = await http.SendAsync(
                requestMessage, HttpCompletionOption.ResponseHeadersRead, cancellation.Token);
            if (!response.IsSuccessStatusCode)
            {
                throw new InvalidOperationException($"gateway_http:{(int)response.StatusCode}");
            }

            await using Stream stream = await response.Content.ReadAsStreamAsync(cancellation.Token);
            using var reader = new StreamReader(stream);
            var buffer = new char[4096];
            int read;
            while ((read = await reader.ReadAsync(buffer.AsMemory(0, buffer.Length), cancellation.Token)) > 0)
            {
                cancellation.Token.ThrowIfCancellationRequested();
                // Raw text chunks, exactly like the Rust backend — the frontend parses SSE framing.
                await PushAsync(new { kind = "channel", channelId, chunk = new string(buffer, 0, read) });
            }

            return null;
        }
        finally
        {
            lock (_streamsLock)
            {
                _streams.Remove(requestId);
            }
        }
    }

    private Task<object?> CancelChatStream(JsonElement args)
    {
        string requestId = GetStringFlexible(args, "requestId", "request_id") ?? string.Empty;
        lock (_streamsLock)
        {
            if (_streams.TryGetValue(requestId, out CancellationTokenSource? stream))
            {
                stream.Cancel();
                _streams.Remove(requestId);
            }
        }
        return Task.FromResult<object?>(null);
    }

    private static string? GetStringFlexible(JsonElement element, params string[] names)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            return null;
        }
        foreach (string name in names)
        {
            if (element.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String)
            {
                return value.GetString();
            }
        }
        return null;
    }
}
