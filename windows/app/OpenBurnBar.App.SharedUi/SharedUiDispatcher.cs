using System;
using System.Collections.Generic;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.SharedUi;

/// <summary>
/// The SharedUi command dispatcher — the C# peer of the Linux Tauri backend's
/// command surface (apps/linux-desktop/src-tauri/src/lib.rs). It consumes
/// parsed shim messages, routes the ~80 `LinuxShellBridge` commands to the
/// backing planes, and emits shim replies. Commands with no Windows backing
/// answer "not implemented on Windows: &lt;command&gt;", which the frontend's
/// isCapabilityAbsentError maps to graceful degrade (media/membership) or an
/// honest surface error — never fabricated data.
///
/// Transport-agnostic: the WinUI app feeds WebView2 WebMessageReceived text in
/// and delivers emitted JsonObjects via ExecuteScriptAsync; tests do both
/// in-memory. Threading: handlers may run on any thread; the transport owns
/// UI-thread marshaling for emission.
/// </summary>
public sealed class SharedUiDispatcher
{
    /// <summary>The capability-absent wire error. The exact substring "not implemented on Windows" is a contract.</summary>
    public const string NotImplemented = "not implemented on Windows";

    /// <summary>Delivers one outbound message to the renderer.</summary>
    public delegate Task EmitAsync(JsonObject message, CancellationToken ct);

    private readonly SharedUiDispatcherOptions _options;
    private readonly SharedUiOnboardingMachine _onboarding;
    private readonly SharedUiSubscriptionHub _subscriptions = new();
    private readonly Dictionary<string, Func<JsonObject, EmitAsync, CancellationToken, Task<JsonNode?>>> _handlers;

    public SharedUiDispatcher(SharedUiDispatcherOptions options)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
        _onboarding = new SharedUiOnboardingMachine(
            options.OnboardingStore,
            () => options.CapabilityStatus?.Invoke() ?? new SharedUiCapabilityStatus());
        _handlers = BuildHandlers();
    }

    /// <summary>
    /// Handle one raw WebMessageReceived payload. Malformed messages are
    /// dropped (the host must never throw on renderer input).
    /// </summary>
    public async Task HandleMessageAsync(string webMessageJson, EmitAsync emit, CancellationToken ct = default)
    {
        if (SharedUiBridgeMessage.TryParse(webMessageJson) is not { } message)
        {
            return;
        }

        switch (message)
        {
            case SharedUiInboundMessage.Listen:
                // The shim resolves listen() immediately and tolerates a host
                // that never pushes events (the media store polls regardless).
                return;
            case SharedUiInboundMessage.Invoke invoke:
                await HandleInvokeAsync(invoke, emit, ct).ConfigureAwait(false);
                return;
        }
    }

    private async Task HandleInvokeAsync(
        SharedUiInboundMessage.Invoke invoke, EmitAsync emit, CancellationToken ct)
    {
        JsonObject reply;
        try
        {
            if (!_handlers.TryGetValue(invoke.Command, out var handler))
            {
                throw new SharedUiCommandException($"{NotImplemented}: {invoke.Command}");
            }

            var value = await handler(invoke.Args, emit, ct).ConfigureAwait(false);
            reply = SharedUiBridgeMessage.InvokeResult(invoke.Id, value);
        }
        catch (SharedUiCommandException ex)
        {
            reply = SharedUiBridgeMessage.InvokeError(invoke.Id, ex.Message);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            reply = SharedUiBridgeMessage.InvokeError(invoke.Id, "cancelled");
        }
        catch (Exception ex)
        {
            reply = SharedUiBridgeMessage.InvokeError(invoke.Id, ex.Message);
        }

        await emit(reply, ct).ConfigureAwait(false);
    }

    private static string? ReadString(JsonObject args, string key) =>
        args[key] is JsonValue v && v.TryGetValue(out string? s) ? s : null;

    private static string RequireString(JsonObject args, string key) =>
        ReadString(args, key) is { Length: > 0 } s
            ? s
            : throw new SharedUiCommandException($"{key} must be a non-empty string.");

    private static int ReadBoundedInt(JsonObject args, string key, int fallback, int min, int max)
    {
        if (args[key] is not JsonValue v)
        {
            return fallback;
        }

        var value = v.TryGetValue(out int i) ? i : v.TryGetValue(out long l) ? (int)l : fallback;
        return Math.Clamp(value, min, max);
    }

    private ISharedUiDataPlane Data =>
        _options.Data ?? throw new SharedUiCommandException(NotImplemented + ": data plane");

    private ISharedUiGatewayPlane Gateway =>
        _options.Gateway ?? throw new SharedUiCommandException("gateway_disabled");

    private ISharedUiSystemPlane System =>
        _options.System ?? throw new SharedUiCommandException(NotImplemented + ": system plane");

    private Dictionary<string, Func<JsonObject, EmitAsync, CancellationToken, Task<JsonNode?>>> BuildHandlers() =>
        new(StringComparer.Ordinal)
        {
            // ── P0: boot-critical, host-local ────────────────────────────
            ["runtime_capabilities"] = (args, emit, ct) => Task.FromResult<JsonNode?>(
                SharedUiRuntimeCapabilities.BuildManifest(
                    _options.ShellVersion,
                    _options.CapabilityStatus?.Invoke() ?? new SharedUiCapabilityStatus())),
            ["daemon_health"] = (args, emit, ct) => Task.FromResult<JsonNode?>(BuildDaemonHealth()),
            ["tray_degraded"] = (args, emit, ct) => Task.FromResult<JsonNode?>(
                _options.System?.TrayDegraded ?? true),
            ["onboarding_snapshot"] = (args, emit, ct) => Task.FromResult<JsonNode?>(_onboarding.Snapshot()),
            ["onboarding_action"] = (args, emit, ct) => Task.FromResult<JsonNode?>(_onboarding.ApplyAction(args)),
            ["onboarding_reset"] = (args, emit, ct) => Task.FromResult<JsonNode?>(_onboarding.Reset()),
            ["subscription_start"] = (args, emit, ct) => Task.FromResult<JsonNode?>(_subscriptions.Start(args)),
            ["subscription_resume"] = (args, emit, ct) => Task.FromResult<JsonNode?>(_subscriptions.Resume(args)),
            ["subscription_stop"] = (args, emit, ct) => Task.FromResult<JsonNode?>(_subscriptions.Stop(args)),
            ["record_perf_sample"] = (args, emit, ct) => Task.FromResult<JsonNode?>(null),
            ["measure_perf_operation"] = (args, emit, ct) => Task.FromResult<JsonNode?>(new JsonObject
            {
                ["name"] = ReadString(args, "name") ?? "unknown",
                ["ms"] = 0.0,
                ["source"] = "windows-shared-ui",
                ["ok"] = true,
                ["detail"] = "In-process shell; no daemon round trip to measure.",
            }),
            ["open_dashboard"] = (args, emit, ct) =>
            {
                _options.System?.OpenDashboard();
                return Task.FromResult<JsonNode?>(null);
            },
            ["quit_app"] = (args, emit, ct) =>
            {
                _options.System?.Quit();
                return Task.FromResult<JsonNode?>(null);
            },
            ["session_env"] = (args, emit, ct) => Task.FromResult<JsonNode?>(new JsonObject
            {
                ["xdg_session_type"] = null,
                ["xdg_current_desktop"] = null,
            }),
            // Boot probes awaited by loadShellBridge()/main.tsx right after
            // onboarding_snapshot. Windows has no deep-link or notification-action
            // source for this shell yet, so the honest answers are null / empty —
            // NOT a not-implemented error, which the boot catch would read as
            // "onboarding authority unavailable" and ignore a completed snapshot.
            ["initial_deep_link_route"] = (args, emit, ct) => Task.FromResult<JsonNode?>(null),
            ["forwarded_deep_link_route"] = (args, emit, ct) => Task.FromResult<JsonNode?>(null),
            ["initial_notification_actions"] = (args, emit, ct) => Task.FromResult<JsonNode?>(new JsonArray()),

            // ── P1: data reads, backed by the in-process stores ──────────
            ["usage_summary"] = async (args, emit, ct) => await Data.GetRecentUsageAsync(50, ct).ConfigureAwait(false),
            ["usage_insights"] = async (args, emit, ct) => await Data.GetRecentUsageAsync(200, ct).ConfigureAwait(false),
            ["usage_calendar"] = async (args, emit, ct) => await Data.GetRecentUsageAsync(2000, ct).ConfigureAwait(false),
            ["session_list"] = async (args, emit, ct) => await Data.ListSessionsAsync(500, ct).ConfigureAwait(false),
            ["session_search"] = async (args, emit, ct) =>
                await Data.SearchSessionsAsync(RequireString(args, "query"), ct).ConfigureAwait(false),
            ["provider_catalog"] = async (args, emit, ct) => await Data.GetProviderCatalogAsync(ct).ConfigureAwait(false),
            ["config_snapshot"] = async (args, emit, ct) => await Data.GetConfigSnapshotAsync(ct).ConfigureAwait(false),
            ["config_update"] = async (args, emit, ct) =>
                await Data.ApplyConfigUpdateAsync(
                    args["snapshot"] as JsonObject
                    ?? throw new SharedUiCommandException("snapshot must be an object."),
                    ct).ConfigureAwait(false),
            ["db_status"] = async (args, emit, ct) => await Data.GetDatabaseStatusAsync(ct).ConfigureAwait(false),
            ["account_status"] = async (args, emit, ct) => await Data.GetAccountStatusAsync(ct).ConfigureAwait(false),
            ["app_version_info"] = async (args, emit, ct) => await Data.GetAppVersionInfoAsync(ct).ConfigureAwait(false),
            ["update_status"] = async (args, emit, ct) => await Data.GetUpdateStatusAsync(ct).ConfigureAwait(false),
            ["export_diagnostics"] = (args, emit, ct) => Task.FromResult<JsonNode?>(new JsonObject
            {
                ["path"] = System.ExportDiagnostics(),
            }),
            ["proxy_route_log_recent"] = async (args, emit, ct) =>
                await Data.GetProxyRouteLogAsync(ReadBoundedInt(args, "limit", 100, 1, 1000), ct).ConfigureAwait(false),
            ["proxy_route_log_clear"] = async (args, emit, ct) => await Data.ClearProxyRouteLogAsync(ct).ConfigureAwait(false),
            ["database_workspace_status"] = async (args, emit, ct) =>
                await Data.GetDatabaseWorkspaceStatusAsync(ReadString(args, "projectPath"), ct).ConfigureAwait(false),

            // ── P1: the local chat gateway ───────────────────────────────
            ["gateway_probe"] = async (args, emit, ct) =>
                _options.Gateway is not null && await _options.Gateway.ProbeAsync(ct).ConfigureAwait(false),
            ["gateway_chat_cancel"] = (args, emit, ct) =>
            {
                _options.Gateway?.CancelChat(RequireString(args, "requestId"));
                return Task.FromResult<JsonNode?>(null);
            },
            ["gateway_chat_stream"] = HandleGatewayChatStreamAsync,

            // ── P3: OS integration with allowlists ───────────────────────
            ["open_external_url"] = (args, emit, ct) =>
            {
                System.OpenExternalUrl(SharedUiUrlPolicy.ValidateExternalUrl(RequireString(args, "url")));
                return Task.FromResult<JsonNode?>(null);
            },
            ["open_update_url"] = (args, emit, ct) =>
            {
                System.OpenUpdateUrl(SharedUiUrlPolicy.ValidateUpdateUrl(RequireString(args, "url")));
                return Task.FromResult<JsonNode?>(null);
            },
        };

    private async Task<JsonNode?> HandleGatewayChatStreamAsync(
        JsonObject args, EmitAsync emit, CancellationToken ct)
    {
        var (requestId, _, _) = SharedUiGatewayChatValidator.ValidateRequest(args);
        if (!SharedUiBridgeMessage.TryReadChannelId(args, "onEvent", out var channelId))
        {
            throw new SharedUiCommandException("gateway_invalid_channel");
        }

        var request = args["request"] as JsonObject ?? new JsonObject();
        await Gateway.StreamChatAsync(
                request,
                (chunk, chunkCt) => emit(SharedUiBridgeMessage.ChannelChunk(channelId, chunk), chunkCt),
                ct)
            .ConfigureAwait(false);
        _ = requestId; // cancel correlation lives in the gateway plane.
        return null;
    }

    /// <summary>
    /// daemon_health never rejects (the frontend's status pill reads the error
    /// string for copy). Windows composes the health of the in-process backend:
    /// ok = storage ready; the gateway fields reflect the loopback model proxy.
    /// </summary>
    private JsonObject BuildDaemonHealth()
    {
        var status = _options.CapabilityStatus?.Invoke() ?? new SharedUiCapabilityStatus();
        return new JsonObject
        {
            ["ok"] = status.StorageReady,
            ["protocolVersion"] = null,
            ["daemonVersion"] = "windows-inproc",
            ["socketPath"] = null,
            ["gatewayEnabled"] = status.GatewayRunning,
            ["gatewayHost"] = status.GatewayRunning ? "127.0.0.1" : null,
            ["gatewayPort"] = status.GatewayRunning ? status.GatewayPort : null,
            ["error"] = status.StorageReady
                ? null
                : "The local store is in typed recovery; in-process backend unavailable.",
        };
    }
}
