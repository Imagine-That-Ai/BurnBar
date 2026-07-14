using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.Presentation.ElderWand;
using OpenBurnBar.App.Presentation.Projects;
using OpenBurnBar.App.UsageRuntime;

namespace OpenBurnBar.App;

public partial class App
{
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

        int maxSteps = 8;
        if (request.TryGetProperty("maxSteps", out JsonElement maxStepsElement)
            && (!maxStepsElement.TryGetInt32(out maxSteps) || maxSteps is < 1 or > 16))
        {
            throw new ArgumentException("maxSteps must be between 1 and 16.", nameof(request));
        }

        string? runId = request.TryGetProperty("runId", out JsonElement runIdElement)
            && runIdElement.ValueKind == JsonValueKind.String
            ? runIdElement.GetString()
            : null;
        runId = string.IsNullOrWhiteSpace(runId)
            ? "fusion-" + Guid.NewGuid().ToString("N")
            : runId.Trim();
        FusionRunResult result = await _fusion
            .RunAsync(new FusionRunRequest(seedPrompt, maxSteps, runId), cancellationToken)
            .ConfigureAwait(false);
        return new
        {
            runId,
            succeeded = result.Succeeded,
            steps = result.Steps.Count,
            error = result.Error,
        };
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

        string? configuredModel = Environment.GetEnvironmentVariable("OPENBURNBAR_FUSION_MODEL");
        ModelRouteDecision decision = string.IsNullOrWhiteSpace(configuredModel)
            ? composition.Router.Select()
            : composition.Router.SelectForModel(configuredModel, allowDegrade: true);
        if (decision.FailedClosed || decision.Route.Endpoint is null)
        {
            composition.Router.RecordOutcome(decision.Route, succeeded: false, decision.Degraded);
            return FusionToolResult.Fail("fusion_route_unavailable");
        }

        byte[] body = JsonSerializer.SerializeToUtf8Bytes(new
        {
            model = decision.Route.Model,
            messages = new[]
            {
                new { role = "system", content = "You are the OpenBurnBar Elder Wand fusion judge. Return JSON with terminal (boolean) and output (string) when you can finish; otherwise return concise analysis text." },
                new { role = "user", content = call.Payload },
            },
            temperature = 0.2,
            max_tokens = 2048,
        });
        ModelCompletionResult response = await composition.Executor
            .ExecuteAsync(decision.Route, body, cancellationToken)
            .ConfigureAwait(false);
        composition.Router.RecordOutcome(decision.Route, response.Succeeded, decision.Degraded);
        if (!response.Succeeded)
        {
            return FusionToolResult.Fail($"fusion_provider_http_{response.StatusCode}");
        }

        string output = ExtractFusionOutput(response.Body);
        if (string.IsNullOrWhiteSpace(output))
        {
            return FusionToolResult.Fail("fusion_provider_empty_output");
        }

        if (TryReadTerminalEnvelope(output, out bool terminal, out string envelopeOutput))
        {
            return new FusionToolResult(true, terminal, envelopeOutput, null);
        }

        return FusionToolResult.Continue(output);
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
        }
        catch (JsonException)
        {
            // Some OpenAI-compatible local engines return plain text. Preserve
            // that output while still applying the hard byte cap below.
        }

        string raw = Encoding.UTF8.GetString(body);
        return raw.Length <= 256 * 1024 ? raw : raw[..(256 * 1024)];
    }

    private static bool TryReadTerminalEnvelope(string output, out bool terminal, out string envelopeOutput)
    {
        terminal = false;
        envelopeOutput = output;
        try
        {
            using JsonDocument document = JsonDocument.Parse(output);
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("terminal", out JsonElement terminalElement))
            {
                return false;
            }

            if (terminalElement.ValueKind is not JsonValueKind.True and not JsonValueKind.False)
            {
                return false;
            }

            if (!root.TryGetProperty("output", out JsonElement outputElement)
                || outputElement.ValueKind != JsonValueKind.String)
            {
                return false;
            }

            terminal = terminalElement.GetBoolean();
            envelopeOutput = outputElement.GetString() ?? string.Empty;
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
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
        await StopLocalRuntimeAsync();
        _flyout?.Close();
        _mainWindow?.Close();
        Exit();
    }

    private async Task StopLocalRuntimeAsync()
    {
        if (_gateway is not null)
        {
            await _gateway.DisposeAsync();
            _gateway = null;
        }
        if (_companionCli is not null)
        {
            await _companionCli.DisposeAsync();
            _companionCli = null;
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
