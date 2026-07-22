using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

public sealed record GatewayTokenUsage(
    int InputTokens,
    int OutputTokens,
    int CacheCreationTokens,
    int CacheReadTokens,
    int ReasoningTokens);

public sealed record GatewayRouteLogEntry(
    string Id,
    DateTimeOffset StartedAt,
    DateTimeOffset CompletedAt,
    long DurationMilliseconds,
    string RequestPath,
    string ClientModel,
    string RoutedModel,
    string RouteId,
    string Vendor,
    string? AccountId,
    string? CanonicalModelId,
    string FormatFamily,
    string? EndpointProfileId,
    bool Degraded,
    bool Succeeded,
    int StatusCode,
    bool Streamed,
    GatewayTokenUsage? Usage);

public sealed record GatewayTelemetrySnapshot(
    int RetainedRequests,
    int Successes,
    int Failures,
    int Degrades,
    long InputTokens,
    long OutputTokens,
    long CacheCreationTokens,
    long CacheReadTokens,
    long ReasoningTokens);

/// <summary>Bounded metadata-only JSONL store for gateway route decisions and usage.</summary>
public sealed class GatewayRouteTelemetryStore
{
    public const int DefaultRecentLimit = 50;
    public const int MaximumRecentLimit = 200;
    public const int RetainedRecordLimit = 5_000;
    public const int MaximumFileBytes = 32 * 1024 * 1024;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
    };

    private readonly object _gate = new();
    private readonly string? _filePath;
    private List<GatewayRouteLogEntry>? _entries;

    public GatewayRouteTelemetryStore(string? filePath = null)
    {
        _filePath = string.IsNullOrWhiteSpace(filePath) ? null : Path.GetFullPath(filePath);
    }

    public void Append(GatewayRouteLogEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        if (!IsValid(entry)) return;
        lock (_gate)
        {
            List<GatewayRouteLogEntry> entries = LoadLocked();
            entries.Add(entry);
            if (entries.Count > RetainedRecordLimit)
            {
                entries.RemoveRange(0, entries.Count - RetainedRecordLimit);
                RewriteLocked(entries);
            }
            else
            {
                AppendLineLocked(entry);
            }
        }
    }

    public IReadOnlyList<GatewayRouteLogEntry> Recent(int limit = DefaultRecentLimit)
    {
        int bounded = Math.Clamp(limit, 0, MaximumRecentLimit);
        lock (_gate)
        {
            return LoadLocked()
                .OrderByDescending(entry => entry.StartedAt)
                .Take(bounded)
                .ToArray();
        }
    }

    public GatewayTelemetrySnapshot Snapshot()
    {
        lock (_gate)
        {
            List<GatewayRouteLogEntry> entries = LoadLocked();
            return new GatewayTelemetrySnapshot(
                entries.Count,
                entries.Count(entry => entry.Succeeded),
                entries.Count(entry => !entry.Succeeded),
                entries.Count(entry => entry.Degraded),
                entries.Sum(entry => (long)(entry.Usage?.InputTokens ?? 0)),
                entries.Sum(entry => (long)(entry.Usage?.OutputTokens ?? 0)),
                entries.Sum(entry => (long)(entry.Usage?.CacheCreationTokens ?? 0)),
                entries.Sum(entry => (long)(entry.Usage?.CacheReadTokens ?? 0)),
                entries.Sum(entry => (long)(entry.Usage?.ReasoningTokens ?? 0)));
        }
    }

    private List<GatewayRouteLogEntry> LoadLocked()
    {
        if (_entries is not null)
        {
            return _entries;
        }
        _entries = new List<GatewayRouteLogEntry>();
        if (_filePath is null || !File.Exists(_filePath))
        {
            return _entries;
        }
        try
        {
            if (new FileInfo(_filePath).Length > MaximumFileBytes)
            {
                return _entries;
            }
            foreach (string line in File.ReadLines(_filePath))
            {
                try
                {
                    GatewayRouteLogEntry? entry = JsonSerializer.Deserialize<GatewayRouteLogEntry>(line, JsonOptions);
                    if (entry is not null && IsValid(entry))
                    {
                        _entries.Add(entry);
                    }
                }
                catch (JsonException)
                {
                    // One corrupt line does not hide the remaining bounded audit history.
                }
            }
            if (_entries.Count > RetainedRecordLimit)
            {
                _entries = _entries.TakeLast(RetainedRecordLimit).ToList();
                RewriteLocked(_entries);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            _entries = new List<GatewayRouteLogEntry>();
        }
        return _entries;
    }

    private void AppendLineLocked(GatewayRouteLogEntry entry)
    {
        if (_filePath is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_filePath)!);
            File.AppendAllText(_filePath, JsonSerializer.Serialize(entry, JsonOptions) + "\n", Encoding.UTF8);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Telemetry persistence cannot fail the provider request path.
        }
    }

    private void RewriteLocked(IReadOnlyCollection<GatewayRouteLogEntry> entries)
    {
        if (_filePath is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_filePath)!);
            string temporary = _filePath + ".tmp-" + Guid.NewGuid().ToString("N");
            string content = string.Join(
                "\n",
                entries.Select(entry => JsonSerializer.Serialize(entry, JsonOptions))) + "\n";
            File.WriteAllText(temporary, content, Encoding.UTF8);
            File.Move(temporary, _filePath, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Telemetry persistence cannot fail the provider request path.
        }
    }

    private static bool IsValid(GatewayRouteLogEntry entry) =>
        IsBounded(entry.Id, 128)
        && IsBounded(entry.RequestPath, 256)
        && IsBounded(entry.ClientModel, GatewayRouteConfiguration.MaximumModelLength)
        && IsBounded(entry.RoutedModel, GatewayRouteConfiguration.MaximumModelLength)
        && IsBounded(entry.RouteId, GatewayRouteConfiguration.MaximumIdLength)
        && IsBounded(entry.Vendor, GatewayRouteConfiguration.MaximumVendorLength)
        && IsOptionalBounded(entry.AccountId, ModelRouteRoutingMetadata.MaximumMetadataStringLength)
        && IsOptionalBounded(entry.CanonicalModelId, ModelRouteRoutingMetadata.MaximumMetadataStringLength)
        && IsBounded(entry.FormatFamily, ModelRouteRoutingMetadata.MaximumMetadataStringLength)
        && IsOptionalBounded(entry.EndpointProfileId, ModelRouteRoutingMetadata.MaximumMetadataStringLength)
        && entry.CompletedAt >= entry.StartedAt
        && entry.DurationMilliseconds >= 0
        && entry.StatusCode is >= 100 and <= 599
        && IsValid(entry.Usage);

    private static bool IsValid(GatewayTokenUsage? usage) => usage is null
        || (usage.InputTokens >= 0
            && usage.OutputTokens >= 0
            && usage.CacheCreationTokens >= 0
            && usage.CacheReadTokens >= 0
            && usage.ReasoningTokens >= 0);

    private static bool IsBounded(string value, int maximum) =>
        !string.IsNullOrWhiteSpace(value) && value.Trim().Length <= maximum;

    private static bool IsOptionalBounded(string? value, int maximum) =>
        value is null || value.Trim().Length <= maximum;
}

public static class GatewayUsageParser
{
    public static GatewayTokenUsage? Parse(ModelCompletionResult result)
    {
        if (result.Body.Length == 0) return null;
        return result.ContentType.StartsWith("text/event-stream", StringComparison.OrdinalIgnoreCase)
            ? ParseEventStream(result.Body)
            : ParseJson(result.Body);
    }

    private static GatewayTokenUsage? ParseEventStream(byte[] body)
    {
        GatewayTokenUsage? usage = null;
        string text = Encoding.UTF8.GetString(body);
        foreach (string rawLine in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            string line = rawLine.Trim();
            if (!line.StartsWith("data:", StringComparison.OrdinalIgnoreCase)) continue;
            string payload = line["data:".Length..].Trim();
            if (payload is "" or "[DONE]") continue;
            try
            {
                using JsonDocument document = JsonDocument.Parse(payload);
                usage = ParseRoot(document.RootElement) ?? usage;
            }
            catch (JsonException)
            {
                // A malformed event carries no trusted usage signal.
            }
        }
        return usage;
    }

    private static GatewayTokenUsage? ParseJson(byte[] body)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            return ParseRoot(document.RootElement);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static GatewayTokenUsage? ParseRoot(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object) return null;
        JsonElement usage;
        if (root.TryGetProperty("usage", out JsonElement directUsage)
            && directUsage.ValueKind == JsonValueKind.Object)
        {
            usage = directUsage;
        }
        else if (root.TryGetProperty("message", out JsonElement message)
            && message.ValueKind == JsonValueKind.Object
            && message.TryGetProperty("usage", out JsonElement messageUsage)
            && messageUsage.ValueKind == JsonValueKind.Object)
        {
            usage = messageUsage;
        }
        else
        {
            return null;
        }

        int? prompt = IntValue(usage, "prompt_tokens") ?? IntValue(usage, "input_tokens");
        int? completion = IntValue(usage, "completion_tokens") ?? IntValue(usage, "output_tokens");
        if (prompt is null && completion is null) return null;

        int cached = IntValue(usage, "cache_read_input_tokens") ?? 0;
        int created = IntValue(usage, "cache_creation_input_tokens") ?? 0;
        int reasoning = 0;
        if (usage.TryGetProperty("prompt_tokens_details", out JsonElement promptDetails)
            && promptDetails.ValueKind == JsonValueKind.Object)
        {
            cached = IntValue(promptDetails, "cached_tokens") ?? cached;
            created = IntValue(promptDetails, "cache_creation_tokens")
                ?? IntValue(promptDetails, "cache_creation_input_tokens")
                ?? created;
        }
        if (usage.TryGetProperty("completion_tokens_details", out JsonElement completionDetails)
            && completionDetails.ValueKind == JsonValueKind.Object)
        {
            reasoning = IntValue(completionDetails, "reasoning_tokens") ?? 0;
        }
        return new GatewayTokenUsage(
            Math.Max((prompt ?? 0) - cached, 0),
            completion ?? 0,
            created,
            cached,
            reasoning);
    }

    private static int? IntValue(JsonElement parent, string name)
    {
        if (!parent.TryGetProperty(name, out JsonElement value)) return null;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out int integer))
        {
            return Math.Max(integer, 0);
        }
        if (value.ValueKind == JsonValueKind.String
            && int.TryParse(value.GetString(), out integer))
        {
            return Math.Max(integer, 0);
        }
        return null;
    }
}
