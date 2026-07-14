using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ModelRouteHealthFailureKind
{
    TransientCapacity,
    RateLimit,
    Authentication,
    QuotaExhaustion,
}

/// <summary>Non-secret temporary route-health block derived from an upstream response.</summary>
public sealed record ModelRouteHealthRecord(
    string RouteId,
    string Model,
    string Vendor,
    string AccountId,
    string FormatFamily,
    int StatusCode,
    ModelRouteHealthFailureKind FailureKind,
    DateTimeOffset FailedAt,
    DateTimeOffset BlockedUntil);

/// <summary>
/// Failure-driven model health matching the macOS cooldown policy. Provider
/// response bodies and credentials are inspected only in memory and are never
/// written to the health file.
/// </summary>
public sealed class ModelRouteHealthStore
{
    public const int MaximumRecords = 128;
    public const int MaximumFileBytes = 256 * 1024;
    private const int MaximumInspectedBodyBytes = 64 * 1024;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
        Converters = { new JsonStringEnumConverter() },
    };

    private readonly object _gate = new();
    private readonly string? _filePath;
    private readonly Func<DateTimeOffset> _clock;
    private Dictionary<string, ModelRouteHealthRecord>? _records;

    public ModelRouteHealthStore(
        string? filePath = null,
        Func<DateTimeOffset>? clock = null)
    {
        _filePath = string.IsNullOrWhiteSpace(filePath) ? null : Path.GetFullPath(filePath);
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public ModelRouteHealthRecord? ActiveFailure(ModelRoute route)
    {
        ArgumentNullException.ThrowIfNull(route);
        lock (_gate)
        {
            Dictionary<string, ModelRouteHealthRecord> records = LoadLocked();
            string key = Key(route);
            if (!records.TryGetValue(key, out ModelRouteHealthRecord? record))
            {
                return null;
            }
            if (record.BlockedUntil > _clock())
            {
                return record;
            }

            records.Remove(key);
            PersistLocked(records);
            return null;
        }
    }

    public IReadOnlyDictionary<string, ModelRouteHealthRecord> Snapshot()
    {
        lock (_gate)
        {
            Dictionary<string, ModelRouteHealthRecord> records = LoadLocked();
            DateTimeOffset now = _clock();
            bool changed = false;
            foreach (string key in records
                         .Where(pair => pair.Value.BlockedUntil <= now)
                         .Select(pair => pair.Key)
                         .ToArray())
            {
                records.Remove(key);
                changed = true;
            }
            if (changed)
            {
                PersistLocked(records);
            }
            return records.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
        }
    }

    public void RecordSuccess(ModelRoute route)
    {
        ArgumentNullException.ThrowIfNull(route);
        lock (_gate)
        {
            Dictionary<string, ModelRouteHealthRecord> records = LoadLocked();
            if (records.Remove(Key(route)))
            {
                PersistLocked(records);
            }
        }
    }

    public void RecordFailure(ModelRoute route, ModelCompletionResult result)
    {
        ArgumentNullException.ThrowIfNull(route);
        if (result.Succeeded)
        {
            RecordSuccess(route);
            return;
        }

        (ModelRouteHealthFailureKind Kind, TimeSpan Duration)? policy = BlockPolicy(route, result);
        if (policy is null)
        {
            return;
        }

        DateTimeOffset now = _clock();
        ModelRouteRoutingMetadata? metadata = route.Routing;
        var record = new ModelRouteHealthRecord(
            route.Id,
            route.Model,
            route.Vendor,
            metadata?.CredentialSlotId?.Trim() ?? "legacy",
            metadata?.FormatFamily?.Trim() ?? "openai-compatible",
            result.StatusCode,
            policy.Value.Kind,
            now,
            now.Add(policy.Value.Duration));
        lock (_gate)
        {
            Dictionary<string, ModelRouteHealthRecord> records = LoadLocked();
            records[Key(route)] = record;
            if (records.Count > MaximumRecords)
            {
                records = records.Values
                    .OrderByDescending(value => value.BlockedUntil)
                    .ThenBy(value => value.RouteId, StringComparer.Ordinal)
                    .Take(MaximumRecords)
                    .ToDictionary(value => Key(value), value => value, StringComparer.Ordinal);
                _records = records;
            }
            PersistLocked(records);
        }
    }

    private static (ModelRouteHealthFailureKind Kind, TimeSpan Duration)? BlockPolicy(
        ModelRoute route,
        ModelCompletionResult result)
    {
        int status = result.StatusCode;
        if (status is 408 or 500 or 502 or 503 or 504 or 529)
        {
            return (ModelRouteHealthFailureKind.TransientCapacity, TimeSpan.FromMinutes(1));
        }
        if (status == 429)
        {
            bool anthropicOAuth = string.Equals(route.Vendor, "anthropic", StringComparison.OrdinalIgnoreCase)
                && route.BearerToken?.Trim().StartsWith("sk-ant-oat", StringComparison.OrdinalIgnoreCase) == true;
            return (
                ModelRouteHealthFailureKind.RateLimit,
                anthropicOAuth ? TimeSpan.FromMinutes(15) : TimeSpan.FromMinutes(5));
        }
        if (status is 401 or 403)
        {
            bool currentClaudeLogin = string.Equals(route.Vendor, "anthropic", StringComparison.OrdinalIgnoreCase)
                && string.Equals(
                    route.Routing?.CredentialSlotId?.Trim(),
                    "current-claude-code-login",
                    StringComparison.OrdinalIgnoreCase);
            return currentClaudeLogin
                ? null
                : (ModelRouteHealthFailureKind.Authentication, TimeSpan.FromHours(1));
        }

        string body = Encoding.UTF8.GetString(result.Body, 0, Math.Min(result.Body.Length, MaximumInspectedBodyBytes));
        if (status == 402
            || body.Contains("quota", StringComparison.OrdinalIgnoreCase)
            || body.Contains("insufficient", StringComparison.OrdinalIgnoreCase)
            || body.Contains("exhaust", StringComparison.OrdinalIgnoreCase))
        {
            return (ModelRouteHealthFailureKind.QuotaExhaustion, TimeSpan.FromMinutes(30));
        }
        return null;
    }

    private Dictionary<string, ModelRouteHealthRecord> LoadLocked()
    {
        if (_records is not null)
        {
            return _records;
        }
        _records = new Dictionary<string, ModelRouteHealthRecord>(StringComparer.Ordinal);
        if (_filePath is null || !File.Exists(_filePath))
        {
            return _records;
        }

        try
        {
            var info = new FileInfo(_filePath);
            if (info.Length > MaximumFileBytes)
            {
                return _records;
            }
            ModelRouteHealthRecord[] decoded = JsonSerializer.Deserialize<ModelRouteHealthRecord[]>(
                File.ReadAllText(_filePath),
                JsonOptions) ?? Array.Empty<ModelRouteHealthRecord>();
            DateTimeOffset now = _clock();
            _records = decoded
                .Where(record => record is not null)
                .Where(IsValid)
                .Where(record => record.BlockedUntil > now)
                .OrderByDescending(record => record.BlockedUntil)
                .Take(MaximumRecords)
                .ToDictionary(record => Key(record), record => record, StringComparer.Ordinal);
        }
        catch (Exception error) when (
            error is IOException or UnauthorizedAccessException or JsonException or ArgumentException)
        {
            _records = new Dictionary<string, ModelRouteHealthRecord>(StringComparer.Ordinal);
        }
        return _records;
    }

    private void PersistLocked(IReadOnlyDictionary<string, ModelRouteHealthRecord> records)
    {
        if (_filePath is null)
        {
            return;
        }
        try
        {
            string directory = Path.GetDirectoryName(_filePath)!;
            Directory.CreateDirectory(directory);
            string temporary = _filePath + ".tmp-" + Guid.NewGuid().ToString("N");
            File.WriteAllText(
                temporary,
                JsonSerializer.Serialize(records.Values.OrderBy(value => value.RouteId).ToArray(), JsonOptions));
            File.Move(temporary, _filePath, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Health persistence is advisory; request execution and failover continue in memory.
        }
    }

    private static bool IsValid(ModelRouteHealthRecord record) =>
        !string.IsNullOrWhiteSpace(record.RouteId)
        && !string.IsNullOrWhiteSpace(record.Model)
        && !string.IsNullOrWhiteSpace(record.Vendor)
        && record.BlockedUntil > record.FailedAt
        && Enum.IsDefined(record.FailureKind);

    private static string Key(ModelRoute route) => string.Join(
        "#",
        route.Vendor.Trim().ToLowerInvariant(),
        route.Routing?.CredentialSlotId?.Trim().ToLowerInvariant() ?? "legacy",
        route.Routing?.FormatFamily?.Trim().ToLowerInvariant() ?? "openai-compatible",
        route.Model.Trim().ToLowerInvariant());

    private static string Key(ModelRouteHealthRecord record) => string.Join(
        "#",
        record.Vendor.Trim().ToLowerInvariant(),
        record.AccountId.Trim().ToLowerInvariant(),
        record.FormatFamily.Trim().ToLowerInvariant(),
        record.Model.Trim().ToLowerInvariant());
}
