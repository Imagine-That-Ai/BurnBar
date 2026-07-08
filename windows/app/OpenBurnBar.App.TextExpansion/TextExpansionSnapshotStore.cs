using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenBurnBar.App.TextExpansion;

/// <summary>ISO-8601 internet-date-time (UTC, second precision) codec matching Swift <c>JSONEncoder.dateEncodingStrategy = .iso8601</c>.</summary>
internal static class TextExpansionIso8601
{
    /// <summary>Emit the Foundation <c>.iso8601</c> shape: <c>yyyy-MM-ddTHH:mm:ssZ</c> (no fractional seconds).</summary>
    public static string Format(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    /// <summary>Lenient parse: accepts the <c>.iso8601</c> shape and fractional-second variants; always returns UTC.</summary>
    public static DateTimeOffset Parse(string text) =>
        DateTimeOffset.Parse(text, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind | DateTimeStyles.AssumeUniversal)
            .ToUniversalTime();
}

/// <summary>
/// Portable JSON snapshot read/write for the shared snippet set. Faithful peer of
/// Swift <c>TextExpansionSnapshotStore</c> (OpenBurnBarCore/.../TextExpansion/
/// TextExpansionSnapshotStore.swift). The JSON is byte-shape compatible with the
/// Swift <c>Codable</c> encoding (exact key names, <c>static</c>/<c>llm_rewrite</c>
/// mode strings, ISO-8601 dates) so a snapshot written on macOS decodes here and
/// vice-versa.
/// </summary>
public static class TextExpansionSnapshotStore
{
    public const string SnapshotFileName = "text-expansion-snippets.json";

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    /// <summary>Encode a snapshot to Swift-compatible JSON text.</summary>
    public static string Encode(TextExpansionSnapshot snapshot)
    {
        var dto = new SnapshotDto
        {
            SchemaVersion = snapshot.SchemaVersion,
            ExportedAt = TextExpansionIso8601.Format(snapshot.ExportedAt),
            Snippets = snapshot.Snippets.Select(ToDto).ToList(),
        };
        return JsonSerializer.Serialize(dto, Options);
    }

    /// <summary>Decode Swift-compatible JSON text into a snapshot.</summary>
    public static TextExpansionSnapshot Decode(string json)
    {
        var dto = JsonSerializer.Deserialize<SnapshotDto>(json, Options)
            ?? throw new JsonException("TextExpansion snapshot JSON decoded to null.");
        return new TextExpansionSnapshot(
            snippets: (dto.Snippets ?? new List<SnippetDto>()).Select(FromDto).ToList(),
            schemaVersion: dto.SchemaVersion,
            exportedAt: dto.ExportedAt is null ? DateTimeOffset.UtcNow : TextExpansionIso8601.Parse(dto.ExportedAt));
    }

    private static SnippetDto ToDto(TextExpansionSnippet s) => new()
    {
        Id = s.Id,
        Title = s.Title,
        Trigger = s.Trigger,
        Body = s.Body,
        Mode = s.Mode.ToRawValue(),
        IsEnabled = s.IsEnabled,
        Scope = new ScopeDto
        {
            Surfaces = s.Scope.Surfaces.Select(x => x.ToRawValue()).ToList(),
            BundleIdentifiers = s.Scope.BundleIdentifiers.ToList(),
            ThreadIds = s.Scope.ThreadIds.ToList(),
        },
        Revision = s.Revision,
        CreatedAt = TextExpansionIso8601.Format(s.CreatedAt),
        UpdatedAt = TextExpansionIso8601.Format(s.UpdatedAt),
        DeletedAt = s.DeletedAt is { } d ? TextExpansionIso8601.Format(d) : null,
        SyncedAt = s.SyncedAt is { } sy ? TextExpansionIso8601.Format(sy) : null,
        SourceDeviceId = s.SourceDeviceId,
    };

    private static TextExpansionSnippet FromDto(SnippetDto d)
    {
        var surfaces = (d.Scope?.Surfaces ?? new List<string>())
            .Select(TextExpansionRawValues.ParseSurface)
            .Where(x => x is not null)
            .Select(x => x!.Value)
            .ToList();
        var scope = new TextExpansionScope(
            surfaces: surfaces.Count > 0 ? surfaces : TextExpansionRawValues.AllSurfaces,
            bundleIdentifiers: d.Scope?.BundleIdentifiers ?? new List<string>(),
            threadIds: d.Scope?.ThreadIds ?? new List<string>());

        return new TextExpansionSnippet(
            title: d.Title ?? string.Empty,
            trigger: d.Trigger ?? string.Empty,
            body: d.Body ?? string.Empty,
            id: d.Id ?? Guid.NewGuid().ToString(),
            mode: TextExpansionRawValues.ParseMode(d.Mode),
            isEnabled: d.IsEnabled,
            scope: scope,
            revision: d.Revision,
            createdAt: d.CreatedAt is null ? DateTimeOffset.UtcNow : TextExpansionIso8601.Parse(d.CreatedAt),
            updatedAt: d.UpdatedAt is null ? DateTimeOffset.UtcNow : TextExpansionIso8601.Parse(d.UpdatedAt),
            deletedAt: d.DeletedAt is null ? null : TextExpansionIso8601.Parse(d.DeletedAt),
            syncedAt: d.SyncedAt is null ? null : TextExpansionIso8601.Parse(d.SyncedAt),
            sourceDeviceId: d.SourceDeviceId);
    }

    private sealed class SnapshotDto
    {
        [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; set; } = 1;

        [JsonPropertyName("exportedAt")] public string? ExportedAt { get; set; }

        [JsonPropertyName("snippets")] public List<SnippetDto>? Snippets { get; set; }
    }

    private sealed class SnippetDto
    {
        [JsonPropertyName("id")] public string? Id { get; set; }

        [JsonPropertyName("title")] public string? Title { get; set; }

        [JsonPropertyName("trigger")] public string? Trigger { get; set; }

        [JsonPropertyName("body")] public string? Body { get; set; }

        [JsonPropertyName("mode")] public string? Mode { get; set; }

        [JsonPropertyName("isEnabled")] public bool IsEnabled { get; set; } = true;

        [JsonPropertyName("scope")] public ScopeDto? Scope { get; set; }

        [JsonPropertyName("revision")] public int Revision { get; set; } = 1;

        [JsonPropertyName("createdAt")] public string? CreatedAt { get; set; }

        [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }

        [JsonPropertyName("deletedAt")] public string? DeletedAt { get; set; }

        [JsonPropertyName("syncedAt")] public string? SyncedAt { get; set; }

        [JsonPropertyName("sourceDeviceID")] public string? SourceDeviceId { get; set; }
    }

    private sealed class ScopeDto
    {
        [JsonPropertyName("surfaces")] public List<string>? Surfaces { get; set; }

        [JsonPropertyName("bundleIdentifiers")] public List<string>? BundleIdentifiers { get; set; }

        [JsonPropertyName("threadIDs")] public List<string>? ThreadIds { get; set; }
    }
}
