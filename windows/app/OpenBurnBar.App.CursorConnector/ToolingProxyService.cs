using System;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.CursorConnector;

/// <summary>Single in-process tooling facade consumed by authenticated companion clients.</summary>
public sealed class ToolingProxyService
{
    public ToolingProxyService(
        ConnectorPlaneService connectorPlane,
        WorkspaceBridgeBroker? workspaceBridge = null,
        ContextSelector? contextSelector = null)
    {
        ConnectorPlane = connectorPlane ?? throw new ArgumentNullException(nameof(connectorPlane));
        WorkspaceBridge = workspaceBridge ?? new WorkspaceBridgeBroker();
        ContextSelector = contextSelector ?? new ContextSelector();
    }

    public ConnectorPlaneService ConnectorPlane { get; }
    public WorkspaceBridgeBroker WorkspaceBridge { get; }
    public ContextSelector ContextSelector { get; }

    public Task<ConnectorPlaneSnapshot> ConnectorSnapshotAsync(CancellationToken token = default) =>
        ConnectorPlane.SnapshotAsync(token);
    public Task<ConnectorPlaneSnapshot> UpdateConnectorAsync(ConnectorConfigUpdateRequest request, CancellationToken token = default) =>
        ConnectorPlane.UpdateConfigAsync(request, token);
    public Task<ConnectorActionResponse> PerformConnectorActionAsync(ConnectorActionRequest request, CancellationToken token = default) =>
        ConnectorPlane.PerformActionAsync(request, token);
}
