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
        string operation = RequiredString(request, "op");
        return operation switch
        {
            "connector.get" => await tooling.ConnectorSnapshotAsync(cancellationToken).ConfigureAwait(false),
            "connector.update" => await tooling.UpdateConnectorAsync(
                Required<ConnectorConfigUpdateRequest>(request, "request"), cancellationToken).ConfigureAwait(false),
            "connector.action" => await tooling.PerformConnectorActionAsync(
                Required<ConnectorActionRequest>(request, "request"), cancellationToken).ConfigureAwait(false),
            "workspace.bridge.enqueue" => tooling.WorkspaceBridge.Enqueue(
                Required<WorkspaceToolInvocation>(request, "request")),
            "workspace.bridge.claim" => tooling.WorkspaceBridge.Claim(
                OptionalString(request, "runId"), RequiredString(request, "clientId")),
            "workspace.bridge.result" => tooling.WorkspaceBridge.Complete(
                Required<WorkspaceToolResultSubmission>(request, "request")),
            "workspace.bridge.clear" => tooling.WorkspaceBridge.Clear(
                RequiredString(request, "runId"), RequiredString(request, "callId")),
            "workspace.bridge.cancel" => tooling.WorkspaceBridge.Cancel(RequiredString(request, "runId")),
            "context.next" => tooling.ContextSelector.NextAction(
                Required<AgentIntent>(request, "intent"), Required<ContextSelectionState>(request, "state")),
            "context.snapshot" => tooling.ContextSelector.MakeSnapshot(
                Required<AgentIntent>(request, "intent"),
                Required<ContextSelectionState>(request, "state"),
                OptionalString(request, "lastReadFilePath"),
                Optional<IReadOnlyList<string>>(request, "searchResultPaths") ?? Array.Empty<string>()),
            _ => throw new ArgumentException("Unsupported tooling operation.", nameof(request)),
        };
    }

    private static T Required<T>(JsonElement root, string property)
    {
        if (!root.TryGetProperty(property, out JsonElement value))
            throw new ArgumentException($"{property} is required.");
        return value.Deserialize<T>(ConnectorJsonOptions)
            ?? throw new ArgumentException($"{property} is invalid.");
    }

    private static T? Optional<T>(JsonElement root, string property)
    {
        if (!root.TryGetProperty(property, out JsonElement value) || value.ValueKind == JsonValueKind.Null) return default;
        return value.Deserialize<T>(ConnectorJsonOptions);
    }

    private static string RequiredString(JsonElement root, string property) =>
        OptionalString(root, property) is { Length: > 0 } value
            ? value : throw new ArgumentException($"{property} is required.");

    private static string? OptionalString(JsonElement root, string property) =>
        root.TryGetProperty(property, out JsonElement value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()?.Trim() : null;
}
