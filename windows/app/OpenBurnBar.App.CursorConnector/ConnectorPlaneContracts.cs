using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenBurnBar.App.CursorConnector;

[JsonConverter(typeof(JsonStringEnumConverter<ConnectorKind>))]
public enum ConnectorKind { Github, Slack, Linear, Posthog, Sentry, Gmail }

[JsonConverter(typeof(JsonStringEnumConverter<ConnectorAuthKind>))]
public enum ConnectorAuthKind { BearerToken, ApiKey, OAuthAccessToken }

[JsonConverter(typeof(JsonStringEnumConverter<ConnectorHealthStatus>))]
public enum ConnectorHealthStatus { Disabled, MissingSecret, Configured, Healthy, Degraded }

[JsonConverter(typeof(JsonStringEnumConverter<ConnectorActionKind>))]
public enum ConnectorActionKind { TestConnection, SampleRequest }

public sealed record ConnectorConfigMutation(
    ConnectorKind Kind,
    bool IsEnabled,
    string BaseUrl,
    ConnectorAuthKind AuthKind,
    IReadOnlyDictionary<string, JsonElement>? Metadata = null);

public sealed record ConnectorConfigSnapshot(
    ConnectorKind Kind,
    string DisplayName,
    bool IsEnabled,
    string BaseUrl,
    ConnectorAuthKind AuthKind,
    bool SecretConfigured,
    string? SecretHint,
    ConnectorHealthStatus Status,
    DateTimeOffset? LastCheckedAt,
    string? StatusDetail,
    IReadOnlyList<ConnectorActionKind> SupportedActions,
    IReadOnlyDictionary<string, JsonElement> Metadata);

public sealed record ConnectorPlaneSnapshot(
    DateTimeOffset UpdatedAt,
    IReadOnlyList<ConnectorConfigSnapshot> Connectors);

public sealed record ConnectorConfigUpdateRequest(
    ConnectorConfigMutation Config,
    string? Secret = null,
    bool ReplaceSecret = false);

public sealed record ConnectorActionRequest(ConnectorKind Kind, ConnectorActionKind Action);

public sealed record ConnectorActionResponse(
    ConnectorKind Kind,
    ConnectorActionKind Action,
    bool Ok,
    string Summary,
    string? Detail,
    JsonElement? Payload,
    DateTimeOffset RecordedAt);

internal sealed record StoredConnectorConfig(
    ConnectorKind Kind,
    bool IsEnabled,
    string BaseUrl,
    ConnectorAuthKind AuthKind,
    Dictionary<string, JsonElement> Metadata);

internal sealed record StoredConnectorValidation(
    ConnectorHealthStatus Status,
    DateTimeOffset CheckedAt,
    string? Detail);

internal sealed record StoredConnectorPlane(
    DateTimeOffset UpdatedAt,
    Dictionary<ConnectorKind, StoredConnectorConfig> Configs,
    Dictionary<ConnectorKind, StoredConnectorValidation> Validations);
