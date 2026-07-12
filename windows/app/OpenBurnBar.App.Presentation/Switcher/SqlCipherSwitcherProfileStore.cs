using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Data.Sqlite;
using OpenBurnBar.Storage;

namespace OpenBurnBar.App.Presentation.Switcher;

/// <summary>SQLCipher-backed <see cref="ISwitcherProfileStore"/> over <c>switcher_profiles</c>.</summary>
public sealed class SqlCipherSwitcherProfileStore : ISwitcherProfileStore, IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly SqliteConnection _connection;
    private readonly Func<DateTimeOffset> _now;

    public SqlCipherSwitcherProfileStore(string databasePath, string passphrase, Func<DateTimeOffset>? now = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(databasePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(passphrase);
        _connection = SqlCipherConnection.Open(databasePath, passphrase);
        _now = now ?? (() => DateTimeOffset.UtcNow);
    }

    public void Dispose() => _connection.Dispose();

    public IReadOnlyList<SwitcherProfileRecord> FetchAllProfiles()
    {
        var rows = SwitcherProfileWriteSeam.FetchAllProfiles(_connection);
        return rows.Select(MapProfile).ToList();
    }

    public SwitcherActiveProfileState FetchActiveProfileState()
    {
        var state = SwitcherProfileWriteSeam.FetchGlobalActiveState(_connection);
        return new SwitcherActiveProfileState(state.ActiveProfileId, state.UpdatedAt);
    }

    public void SetActiveProfile(string? profileId) =>
        SwitcherProfileWriteSeam.SetGlobalActiveProfile(_connection, profileId, _now());

    public IReadOnlyDictionary<string, string> FetchAllActiveDrainTargets() =>
        SwitcherProfileWriteSeam.FetchDrainTargets(_connection);

    public string? FetchActiveProfileId(string providerKey)
    {
        var map = FetchAllActiveDrainTargets();
        return map.TryGetValue(providerKey, out var id) ? id : null;
    }

    public void SetActiveProfile(string? profileId, string providerKey) =>
        SwitcherProfileWriteSeam.SetDrainTarget(_connection, providerKey, profileId, _now());

    public SwitcherProfileRecord Create(SwitcherProfileRecord record)
    {
        var now = _now();
        var rows = SwitcherProfileWriteSeam.FetchAllProfiles(_connection);
        int nextSort = rows.Count == 0 ? 0 : rows.Max(r => r.SortKey) + 1;
        var stored = record with
        {
            SortKey = nextSort,
            CreatedAt = now,
            UpdatedAt = now,
        };
        SwitcherProfileWriteSeam.UpsertProfile(_connection, MapProfileRow(stored));
        return stored;
    }

    public SwitcherProfileRecord Update(SwitcherProfileRecord record)
    {
        var rows = SwitcherProfileWriteSeam.FetchAllProfiles(_connection);
        var existing = rows.FirstOrDefault(r => r.Id == record.Id)
            ?? throw new InvalidOperationException($"Profile not found: {record.Id}");
        var stored = record with
        {
            SortKey = existing.SortKey,
            CreatedAt = existing.CreatedAt,
            UpdatedAt = _now(),
        };
        SwitcherProfileWriteSeam.UpsertProfile(_connection, MapProfileRow(stored));
        return stored;
    }

    public void DeleteProfile(string id) => SwitcherProfileWriteSeam.DeleteProfile(_connection, id);

    public void ReorderProfiles(IReadOnlyList<string> idsInOrder) =>
        SwitcherProfileWriteSeam.ReorderProfiles(_connection, idsInOrder, _now());

    public bool ExistsProfileWithNormalizedName(string name, string? excludingId)
    {
        string normalized = SwitcherProfileRecord.NormalizeName(name);
        return FetchAllProfiles().Any(p =>
            p.Id != excludingId &&
            SwitcherProfileRecord.NormalizeName(p.DisplayName) == normalized);
    }

    private static SwitcherProfileRecord MapProfile(SwitcherProfileRow row)
    {
        var targetKind = row.TargetKind.Equals("browser", StringComparison.OrdinalIgnoreCase)
            ? SwitcherProfileTargetKind.Browser
            : SwitcherProfileTargetKind.Cli;
        SwitcherBrowserProfileType? browserType = ParseBrowserType(row.BrowserType);
        SwitcherCLIProfileType? cliType = ParseCliType(row.CliType);

        SwitcherBrowserProfileMetadata? browserMetadata = Deserialize<SwitcherBrowserProfileMetadata>(row.BrowserMetadataJson);
        SwitcherCLIProfileMetadata? cliMetadata = Deserialize<SwitcherCLIProfileMetadata>(row.CliMetadataJson);

        return new SwitcherProfileRecord(
            Id: row.Id,
            TargetKind: targetKind,
            SortKey: row.SortKey,
            BrowserType: browserType,
            BrowserMetadata: browserMetadata,
            CliType: cliType,
            CliMetadata: cliMetadata,
            CreatedAt: row.CreatedAt,
            UpdatedAt: row.UpdatedAt);
    }

    private static SwitcherBrowserProfileType? ParseBrowserType(string? raw) => raw switch
    {
        "chrome" => SwitcherBrowserProfileType.Chrome,
        "safari" => SwitcherBrowserProfileType.Safari,
        _ => null,
    };

    private static SwitcherCLIProfileType? ParseCliType(string? raw)
    {
        if (string.IsNullOrEmpty(raw))
        {
            return null;
        }

        foreach (SwitcherCLIProfileType candidate in Enum.GetValues<SwitcherCLIProfileType>())
        {
            if (string.Equals(SwitcherEnumMetadata.RawValue(candidate), raw, StringComparison.OrdinalIgnoreCase))
            {
                return candidate;
            }
        }

        return null;
    }

    private static SwitcherProfileRow MapProfileRow(SwitcherProfileRecord record) => new(
        Id: record.Id,
        TargetKind: SwitcherEnumMetadata.RawValue(record.TargetKind),
        BrowserType: record.BrowserType is null ? null : SwitcherEnumMetadata.RawValue(record.BrowserType.Value),
        BrowserMetadataJson: Serialize(record.BrowserMetadata),
        CliType: record.CliType is null ? null : SwitcherEnumMetadata.RawValue(record.CliType.Value),
        CliMetadataJson: Serialize(record.CliMetadata),
        SortKey: record.SortKey,
        CreatedAt: record.CreatedAt,
        UpdatedAt: record.UpdatedAt);

    private static string? Serialize<T>(T? value) =>
        value is null ? null : JsonSerializer.Serialize(value, JsonOptions);

    private static T? Deserialize<T>(string? json) where T : class =>
        string.IsNullOrWhiteSpace(json) ? null : JsonSerializer.Deserialize<T>(json, JsonOptions);
}