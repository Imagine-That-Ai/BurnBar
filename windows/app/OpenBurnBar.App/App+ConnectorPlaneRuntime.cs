using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.CursorConnector;

namespace OpenBurnBar.App;

public partial class App
{
    private static readonly JsonSerializerOptions ConnectorJsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    private async Task<object?> HandleToolingAsync(JsonElement request, CancellationToken cancellationToken)
    {
        ToolingProxyService tooling = _toolingProxy
            ?? throw new InvalidOperationException("tooling_proxy_unavailable");
        string operation = ToolingRequiredString(request, "op");
        return operation switch
        {
            "connector.get" => await tooling.ConnectorSnapshotAsync(cancellationToken).ConfigureAwait(false),
            "connector.update" => await tooling.UpdateConnectorAsync(
                ToolingRequired<ConnectorConfigUpdateRequest>(request, "request"), cancellationToken).ConfigureAwait(false),
            "connector.action" => await tooling.PerformConnectorActionAsync(
                ToolingRequired<ConnectorActionRequest>(request, "request"), cancellationToken).ConfigureAwait(false),
            "workspace.bridge.enqueue" => tooling.WorkspaceBridge.Enqueue(
                ToolingRequired<WorkspaceToolInvocation>(request, "request")),
            "workspace.bridge.claim" => tooling.WorkspaceBridge.Claim(
                ToolingOptionalString(request, "runId"), ToolingRequiredString(request, "clientId")),
            "workspace.bridge.result" => tooling.WorkspaceBridge.Complete(
                ToolingRequired<WorkspaceToolResultSubmission>(request, "request")),
            "workspace.bridge.clear" => tooling.WorkspaceBridge.Clear(
                ToolingRequiredString(request, "runId"), ToolingRequiredString(request, "callId")),
            "workspace.bridge.cancel" => tooling.WorkspaceBridge.Cancel(ToolingRequiredString(request, "runId")),
            "context.next" => tooling.ContextSelector.NextAction(
                ToolingRequired<AgentIntent>(request, "intent"), ToolingRequired<ContextSelectionState>(request, "state")),
            "context.snapshot" => tooling.ContextSelector.MakeSnapshot(
                ToolingRequired<AgentIntent>(request, "intent"),
                ToolingRequired<ContextSelectionState>(request, "state"),
                ToolingOptionalString(request, "lastReadFilePath"),
                ToolingOptional<IReadOnlyList<string>>(request, "searchResultPaths") ?? Array.Empty<string>()),
            _ => throw new ArgumentException("Unsupported tooling operation.", nameof(request)),
        };
    }

    private static T ToolingRequired<T>(JsonElement root, string property)
    {
        if (!root.TryGetProperty(property, out JsonElement value))
            throw new ArgumentException($"{property} is required.");
        return value.Deserialize<T>(ConnectorJsonOptions)
            ?? throw new ArgumentException($"{property} is invalid.");
    }

    private static T? ToolingOptional<T>(JsonElement root, string property)
    {
        if (!root.TryGetProperty(property, out JsonElement value) || value.ValueKind == JsonValueKind.Null) return default;
        return value.Deserialize<T>(ConnectorJsonOptions);
    }

    private static string ToolingRequiredString(JsonElement root, string property) =>
        ToolingOptionalString(root, property) is { Length: > 0 } value
            ? value : throw new ArgumentException($"{property} is required.");

    private static string? ToolingOptionalString(JsonElement root, string property) =>
        root.TryGetProperty(property, out JsonElement value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()?.Trim() : null;
}
