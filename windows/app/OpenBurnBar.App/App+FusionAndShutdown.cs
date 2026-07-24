using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.Presentation.ElderWand;
using OpenBurnBar.App.Presentation.Projects;
using OpenBurnBar.App.Shell;
using OpenBurnBar.App.UsageRuntime;
using OpenBurnBar.ComputerUse.Core.Gate;

namespace OpenBurnBar.App;

public partial class App
{
    private void EnsureFusionRuntime()
    {
        if (_fusion is not null) return;
        string localData = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenBurnBar");
        string journalPath = Environment.GetEnvironmentVariable("OPENBURNBAR_FUSION_JOURNAL_PATH")
            ?? Path.Combine(localData, "elder-wand-runs.jsonl");
        _fusion = new ElderWandFusionOrchestrator(
            ExecuteFusionToolAsync,
            new JsonLinesFusionRunJournal(journalPath),
            ElderWandWebTools.CreateProduction());
    }

    private async Task<ModelCompletionResult?> HandleGatewayFusionAsync(
        byte[] body,
        CancellationToken cancellationToken)
    {
        EnsureFusionRuntime();
        using JsonDocument document = JsonDocument.Parse(body);
        JsonElement root = document.RootElement;
        JsonElement? plugin = ActiveFusionPlugin(root);
        if (plugin is null || _fusion is null) return null;

        IReadOnlyList<string> analysisModels = ReadFusionModels(
            plugin.Value,
            "analysisModels",
            "analysis_models");
        string? judgeModel = ReadOptionalString(plugin.Value, "model");
        string? originatingModel = ReadOptionalString(root, "model");
        IReadOnlyList<FusionMessage> conversation = ReadFusionConversation(root);
        string prompt = conversation.LastOrDefault(static message => message.Role == "user")?.Content
            ?? string.Empty;
        int maxToolCalls = ElderWandPreset.DefaultMaxToolCalls;
        if (plugin.Value.TryGetProperty("max_tool_calls", out JsonElement budget)
            && budget.TryGetInt32(out int configuredBudget))
        {
            maxToolCalls = ElderWandPreset.MaxToolCallsRange.Clamp(configuredBudget);
        }
        bool wantsStream = root.TryGetProperty("stream", out JsonElement stream)
            && stream.ValueKind == JsonValueKind.True;
        FusionRunResult result = await _fusion.RunAsync(new FusionRunRequest(
            prompt,
            maxToolCalls,
            AnalysisModels: analysisModels,
            JudgeModel: judgeModel,
            OriginatingModel: originatingModel,
            WantsStream: wantsStream,
            Conversation: conversation), cancellationToken).ConfigureAwait(false);
        if (!result.Succeeded)
        {
            byte[] error = JsonSerializer.SerializeToUtf8Bytes(new
            {
                error = new { type = "fusion_error", message = result.Error },
            });
            return new ModelCompletionResult(result.StatusCode, error, "application/json", false);
        }
        byte[] responseBody = result.RawBody ?? JsonSerializer.SerializeToUtf8Bytes(new
        {
            id = result.RunId,
            @object = "chat.completion",
            model = originatingModel,
            choices = new[]
            {
                new { index = 0, message = new { role = "assistant", content = result.Output }, finish_reason = "stop" },
            },
        });
        return new ModelCompletionResult(result.StatusCode, responseBody, result.ContentType, true);
    }

    private static JsonElement? ActiveFusionPlugin(JsonElement root)
    {
        if (!root.TryGetProperty("plugins", out JsonElement plugins)
            || plugins.ValueKind != JsonValueKind.Array) return null;
        foreach (JsonElement plugin in plugins.EnumerateArray())
        {
            if (plugin.ValueKind == JsonValueKind.Object
                && string.Equals(ReadOptionalString(plugin, "id"), "fusion", StringComparison.OrdinalIgnoreCase)
                && (!plugin.TryGetProperty("enabled", out JsonElement enabled)
                    || enabled.ValueKind != JsonValueKind.False))
            {
                return plugin.Clone();
            }
        }
        return null;
    }

    private static IReadOnlyList<FusionMessage> ReadFusionConversation(JsonElement root)
    {
        if (!root.TryGetProperty("messages", out JsonElement messages)
            || messages.ValueKind != JsonValueKind.Array)
        {
            return Array.Empty<FusionMessage>();
        }
        var result = new List<FusionMessage>();
        foreach (JsonElement message in messages.EnumerateArray())
        {
            string? role = ReadOptionalString(message, "role");
            if (role is not ("system" or "user" or "assistant")) continue;
            if (!message.TryGetProperty("content", out JsonElement content)) continue;
            string text = string.Empty;
            if (content.ValueKind == JsonValueKind.String)
            {
                text = content.GetString() ?? string.Empty;
            }
            else if (content.ValueKind == JsonValueKind.Array)
            {
                text = string.Join("\n", content.EnumerateArray()
                    .Where(static part => part.ValueKind == JsonValueKind.Object)
                    .Select(static part => ReadOptionalString(part, "text"))
                    .Where(static text => text is not null));
            }
            if (text.Length > 0) result.Add(new FusionMessage(role, text));
        }
        return result;
    }

    private async Task<object?> HandleFusionRunAsync(JsonElement request, CancellationToken cancellationToken)
    {
        if (_fusion is null)
        {
            throw new InvalidOperationException("fusion_unavailable");
        }

        if (!request.TryGetProperty("seedPrompt", out JsonElement promptElement)
            || promptElement.ValueKind != JsonValueKind.String
            || string.IsNullOrWhiteSpace(promptElement.GetString()))
        {
            throw new ArgumentException("seedPrompt is required.", nameof(request));
        }

        string seedPrompt = promptElement.GetString()!;
        if (seedPrompt.Length > 64 * 1024)
        {
            throw new ArgumentException("seedPrompt exceeds the safety limit.", nameof(request));
        }

        int maxSteps = ElderWandPreset.DefaultMaxToolCalls;
        JsonElement maxStepsElement;
        bool hasMaxSteps = request.TryGetProperty("maxToolCalls", out maxStepsElement)
            || request.TryGetProperty("maxSteps", out maxStepsElement);
        if (hasMaxSteps
            && (!maxStepsElement.TryGetInt32(out maxSteps)
                || !ElderWandPreset.MaxToolCallsRange.Contains(maxSteps)))
        {
            throw new ArgumentException("maxToolCalls must be between 1 and 16.", nameof(request));
        }

        IReadOnlyList<string> analysisModels = ReadFusionModels(request, "analysisModels", "analysis_models");
        string? judgeModel = ReadOptionalString(request, "judgeModel")
            ?? ReadOptionalString(request, "judge_model");
        string? originatingModel = ReadOptionalString(request, "originatingModel")
            ?? ReadOptionalString(request, "model");
        if (analysisModels.Count == 0)
        {
            ElderWandPreset? preset = LoadDefaultElderWandPreset();
            if (preset is not null)
            {
                analysisModels = preset.AnalysisModelIds;
                judgeModel ??= preset.JudgeModelId;
                if (!hasMaxSteps) maxSteps = preset.MaxToolCalls;
            }
        }
        if (analysisModels.Count == 0)
        {
            throw new InvalidOperationException("fusion_configuration_unavailable");
        }

        string? runId = request.TryGetProperty("runId", out JsonElement runIdElement)
            && runIdElement.ValueKind == JsonValueKind.String
            ? runIdElement.GetString()
            : null;
        runId = string.IsNullOrWhiteSpace(runId)
            ? "fusion-" + Guid.NewGuid().ToString("N")
            : runId.Trim();
        FusionRunResult result = await _fusion
            .RunAsync(
                new FusionRunRequest(
                    seedPrompt,
                    maxSteps,
                    runId,
                    analysisModels,
                    judgeModel,
                    originatingModel),
                cancellationToken)
            .ConfigureAwait(false);
        return new
        {
            runId = result.RunId,
            succeeded = result.Succeeded,
            steps = result.Steps.Count,
            error = result.Error,
            output = result.Output,
        };
    }

    private static IReadOnlyList<string> ReadFusionModels(
        JsonElement request,
        string camelName,
        string snakeName)
    {
        if ((!request.TryGetProperty(camelName, out JsonElement value)
                && !request.TryGetProperty(snakeName, out value))
            || value.ValueKind != JsonValueKind.Array)
        {
            return Array.Empty<string>();
        }
        return value.EnumerateArray()
            .Where(static element => element.ValueKind == JsonValueKind.String)
            .Select(static element => element.GetString()?.Trim() ?? string.Empty)
            .Where(static model => model.Length > 0)
            .Distinct(StringComparer.Ordinal)
            .Take(ElderWandPreset.AnalysisPanelRange.Upper)
            .ToArray();
    }

    private static string? ReadOptionalString(JsonElement request, string name) =>
        request.TryGetProperty(name, out JsonElement value)
        && value.ValueKind == JsonValueKind.String
        && !string.IsNullOrWhiteSpace(value.GetString())
            ? value.GetString()!.Trim()
            : null;

    private static ElderWandPreset? LoadDefaultElderWandPreset()
    {
        IElderWandPresetPersistence persistence = Storage.WindowsStorageDevHost.CreateElderWandPersistence();
        try
        {
            return new ElderWandSettingsModel(persistence).ActivePreset;
        }
        finally
        {
            (persistence as IDisposable)?.Dispose();
        }
    }

    private async Task<FusionToolResult> ExecuteFusionToolAsync(
        FusionToolCall call,
        CancellationToken cancellationToken)
    {
        GatewayComposition? composition = _gatewayComposition;
        if (composition is null)
        {
            return FusionToolResult.Fail("gateway_unavailable");
        }

        string? requestedModel = string.IsNullOrWhiteSpace(call.Model)
            ? Environment.GetEnvironmentVariable("OPENBURNBAR_FUSION_MODEL")
            : call.Model;
        ModelRouteDecision decision = string.IsNullOrWhiteSpace(requestedModel)
            ? composition.Router.Select()
            : composition.Router.SelectForModel(requestedModel, allowDegrade: false);
        if (decision.FailedClosed || decision.Route.Endpoint is null)
        {
            composition.Router.RecordOutcome(decision.Route, succeeded: false, decision.Degraded);
            return FusionToolResult.Fail("fusion_route_unavailable");
        }

        byte[] body = BuildFusionCompletionBody(call, decision.Route.Model);
        ModelCompletionResult response = await composition.Executor
            .ExecuteAsync(decision.Route, body, cancellationToken)
            .ConfigureAwait(false);
        composition.Router.RecordOutcome(decision.Route, response.Succeeded, decision.Degraded);
        RecordFusionTelemetry(composition.Router, call, decision, response);
        if (!response.Succeeded)
        {
            return FusionToolResult.Fail($"fusion_provider_http_{response.StatusCode}", response.StatusCode);
        }

        string output = ExtractFusionOutput(response.Body);
        IReadOnlyList<FusionRequestedToolCall> toolCalls = ExtractFusionToolCalls(response.Body);
        if (string.IsNullOrWhiteSpace(output) && toolCalls.Count == 0)
        {
            return FusionToolResult.Fail("fusion_provider_empty_output");
        }
        GatewayTokenUsage? usage = GatewayUsageParser.Parse(response);
        return new FusionToolResult(
            true,
            call.Kind == "synthesis",
            output,
            null,
            toolCalls,
            usage is null
                ? null
                : new FusionUsage(
                    usage.InputTokens,
                    usage.OutputTokens,
                    usage.CacheCreationTokens,
                    usage.CacheReadTokens,
                    usage.ReasoningTokens),
            response.Body,
            response.ContentType,
            response.StatusCode);
    }

    private static void RecordFusionTelemetry(
        ModelProxyRouter router,
        FusionToolCall call,
        ModelRouteDecision decision,
        ModelCompletionResult result)
    {
        ModelRoute route = decision.Route;
        ModelRouteRoutingMetadata metadata = route.Routing ?? new ModelRouteRoutingMetadata();
        GatewayTokenUsage? usage = result.Succeeded ? GatewayUsageParser.Parse(result) : null;
        DateTimeOffset now = DateTimeOffset.UtcNow;
        string runIdentity = Convert.ToHexString(SHA256.HashData(
            Encoding.UTF8.GetBytes(call.RunId ?? "fusion"))).ToLowerInvariant()[..16];
        router.TelemetryStore.Append(new GatewayRouteLogEntry(
            $"fusion:{runIdentity}:{call.Kind}:{call.Step}:{Guid.NewGuid():N}",
            now,
            now,
            0,
            "/v1/chat/completions#fusion/" + call.Kind,
            call.Model ?? route.Model,
            route.Model,
            route.Id,
            route.Vendor,
            metadata.CredentialSlotId,
            metadata.CanonicalModelId,
            metadata.FormatFamily ?? route.Vendor,
            metadata.EndpointProfileId,
            decision.Degraded,
            result.Succeeded,
            result.StatusCode,
            call.Stream,
            usage));
    }

    private static byte[] BuildFusionCompletionBody(FusionToolCall call, string model)
    {
        var messages = new JsonArray();
        if (!string.IsNullOrWhiteSpace(call.SystemPrompt))
        {
            messages.Add(new JsonObject { ["role"] = "system", ["content"] = call.SystemPrompt });
        }
        foreach (FusionMessage message in call.Messages ?? new[] { new FusionMessage("user", call.Payload) })
        {
            var wire = new JsonObject { ["role"] = message.Role, ["content"] = message.Content };
            if (!string.IsNullOrWhiteSpace(message.ToolCallId)) wire["tool_call_id"] = message.ToolCallId;
            if (message.ToolCalls is { Count: > 0 })
            {
                wire["tool_calls"] = new JsonArray(message.ToolCalls.Select(requested =>
                    (JsonNode)new JsonObject
                    {
                        ["id"] = requested.Id,
                        ["type"] = "function",
                        ["function"] = new JsonObject
                        {
                            ["name"] = requested.Name,
                            ["arguments"] = requested.ArgumentsJson,
                        },
                    }).ToArray());
            }
            messages.Add(wire);
        }

        var body = new JsonObject
        {
            ["model"] = model,
            ["messages"] = messages,
            ["stream"] = call.Stream,
            ["temperature"] = 0.2,
            ["max_tokens"] = 4096,
        };
        if (call.IncludeTools && call.Tools is { Count: > 0 })
        {
            body["tools"] = new JsonArray(call.Tools.Select(schema => JsonNode.Parse(schema.GetRawText())!).ToArray());
            body["tool_choice"] = "auto";
        }
        else if (call.Kind is "panel" or "judge")
        {
            body["tool_choice"] = "none";
        }
        return JsonSerializer.SerializeToUtf8Bytes(body);
    }

    private static IReadOnlyList<FusionRequestedToolCall> ExtractFusionToolCalls(byte[] body)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            if (!document.RootElement.TryGetProperty("choices", out JsonElement choices)
                || choices.ValueKind != JsonValueKind.Array
                || choices.GetArrayLength() == 0
                || !choices[0].TryGetProperty("message", out JsonElement message)
                || !message.TryGetProperty("tool_calls", out JsonElement calls)
                || calls.ValueKind != JsonValueKind.Array)
            {
                return Array.Empty<FusionRequestedToolCall>();
            }
            return calls.EnumerateArray().Select(call =>
            {
                string id = ReadOptionalString(call, "id") ?? "tool-" + Guid.NewGuid().ToString("N");
                if (!call.TryGetProperty("function", out JsonElement function)) return null;
                string? name = ReadOptionalString(function, "name");
                if (name is null) return null;
                string arguments = function.TryGetProperty("arguments", out JsonElement args)
                    ? args.ValueKind == JsonValueKind.String ? args.GetString() ?? "{}" : args.GetRawText()
                    : "{}";
                return new FusionRequestedToolCall(id, name, arguments);
            }).Where(static call => call is not null).Cast<FusionRequestedToolCall>().ToArray();
        }
        catch (JsonException)
        {
            return Array.Empty<FusionRequestedToolCall>();
        }
    }

    private static string ExtractFusionOutput(byte[] body)
    {
        if (body.Length == 0)
        {
            return string.Empty;
        }

        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            if (document.RootElement.TryGetProperty("choices", out JsonElement choices)
                && choices.ValueKind == JsonValueKind.Array
                && choices.GetArrayLength() > 0)
            {
                JsonElement first = choices[0];
                if (first.TryGetProperty("message", out JsonElement message)
                    && message.TryGetProperty("content", out JsonElement content)
                    && content.ValueKind == JsonValueKind.String)
                {
                    return content.GetString() ?? string.Empty;
                }

                if (first.TryGetProperty("text", out JsonElement text)
                    && text.ValueKind == JsonValueKind.String)
                {
                    return text.GetString() ?? string.Empty;
                }
            }
            return string.Empty;
        }
        catch (JsonException)
        {
            // Some OpenAI-compatible local engines return plain text. Preserve
            // that output while still applying the hard byte cap below.
        }

        string raw = Encoding.UTF8.GetString(body);
        return raw.Length <= 256 * 1024 ? raw : raw[..(256 * 1024)];
    }

    private static async Task StartUsageRuntimeAsync(IUsageRuntime runtime)
    {
        try
        {
            await runtime.StartAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("usage-runtime.start", ex);
        }
    }

    private async void ExitApp()
    {
        if (_isExiting)
        {
            return;
        }
        _isExiting = true;

        if (_privilegedInputRunExecutor?.HasActiveSessions == true)
        {
            try
            {
                await ActivateComputerUsePanicAsync("app_exit", ComputerUsePanicSource.Revoked);
            }
            catch (Exception error)
            {
                AppDiagnostics.LogException("computer-use.panic-on-exit", error);
            }
        }

        _computerUseSafetyMonitor.Dispose();
        await StopWindowsRuntimeSafetyConfigAsync();

        if (_hotkeyRegistered)
        {
            _hotkey.Dispose();
            _hotkeyRegistered = false;
        }

        _tray?.Dispose();
        _tray = null;
        if (_usageRuntime is not null)
        {
            await _usageRuntime.DisposeAsync();
            _usageRuntime = null;
        }
        if (_pensieveKnowledgeWatcher is not null)
        {
            await _pensieveKnowledgeWatcher.DisposeAsync();
            _pensieveKnowledgeWatcher = null;
        }
        await StopLocalRuntimeAsync();
        _flyout?.Close();
        _sharedUiWindow?.Close();
        _sharedUiWindow = null;
        _mainWindow?.Close();
        Exit();
    }

    private async Task StopLocalRuntimeAsync()
    {
        if (_telegramPolling is not null)
        {
            await _telegramPolling.DisposeAsync();
            _telegramPolling = null;
        }
        _telegramClient?.Dispose();
        _telegramClient = null;
        if (_companionCli is not null)
        {
            await _companionCli.DisposeAsync();
            _companionCli = null;
        }
        if (_headlessAgentRuns is not null)
        {
            await _headlessAgentRuns.DisposeAsync();
            _headlessAgentRuns = null;
        }
        _privilegedInputRunExecutor = null;
        if (_gateway is not null)
        {
            await _gateway.DisposeAsync();
            _gateway = null;
        }
        _headlessRuns = null;
        _fusion = null;
        await _projectCodeMemoryGate.WaitAsync().ConfigureAwait(false);
        try
        {
            ProjectCodeMemoryService? projectCodeMemory = Volatile.Read(ref _projectCodeMemory);
            Volatile.Write(ref _projectCodeMemory, null);
            projectCodeMemory?.Dispose();
        }
        finally
        {
            _projectCodeMemoryGate.Release();
        }
        _gatewayComposition?.Dispose();
        _gatewayComposition = null;
        _localAccessToken = null;
    }

    private AppStatePersistence State =>
        _state ?? throw new InvalidOperationException("App state was requested before launch initialization completed.");
}
