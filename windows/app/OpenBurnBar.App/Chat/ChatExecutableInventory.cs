using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Chat;

public enum ChatExecutableInventoryStatusKind
{
    SetupRequired,
    Ready,
    ExecutableUnavailable,
    ExecutableReplaced,
    InventoryUnavailable,
    InventoryCorrupt,
}

public sealed record ChatExecutableInventoryStatus(
    ChatExecutableInventoryStatusKind Kind,
    string Title,
    string Message);

public sealed record ChatExecutableInventorySnapshot(
    IReadOnlyList<ApprovedChatExecutable> Executables,
    ChatExecutableInventoryStatus Status,
    DateTimeOffset? UpdatedAt = null)
{
    public bool HasEntries => Executables.Count > 0;
    public bool CanLaunch => Status.Kind == ChatExecutableInventoryStatusKind.Ready;
    public ApprovedChatExecutable? PrimaryExecutable => Executables.Count == 0 ? null : Executables[0];

    public static ChatExecutableInventorySnapshot SetupRequired() =>
        new(
            Array.Empty<ApprovedChatExecutable>(),
            new ChatExecutableInventoryStatus(
                ChatExecutableInventoryStatusKind.SetupRequired,
                "Chat CLI setup required.",
                "Approve a CLI executable before starting a chat turn."));
}

public interface IChatExecutableInventory
{
    ChatExecutableInventorySnapshot LoadSnapshot();
    ApprovedChatExecutableCatalog LoadCatalog();
    ApprovedChatExecutable ApproveExecutable(string path, string? id = null);
    ApprovedChatExecutable RotateExecutable(string id, string path);
    bool RemoveExecutable(string id);
}

public sealed class ProtectedChatExecutableInventoryStore : IChatExecutableInventory
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    private readonly IAppSecretStore _secretStore;
    private readonly string _secretName;

    public ProtectedChatExecutableInventoryStore(IAppSecretStore secretStore, string? secretName = null)
    {
        _secretStore = secretStore ?? throw new ArgumentNullException(nameof(secretStore));
        _secretName = string.IsNullOrWhiteSpace(secretName)
            ? AppSecretNames.ChatApprovedExecutables
            : secretName;
    }

    public static ProtectedChatExecutableInventoryStore CreateDefault() =>
        new(ProtectedFileSecretStore.CreateDefault());

    public ChatExecutableInventorySnapshot LoadSnapshot()
    {
        try
        {
            string? json = _secretStore.Read(_secretName);
            if (string.IsNullOrWhiteSpace(json))
            {
                return ChatExecutableInventorySnapshot.SetupRequired();
            }

            ChatExecutableInventoryEnvelope? envelope =
                JsonSerializer.Deserialize<ChatExecutableInventoryEnvelope>(json, JsonOptions);
            if (envelope is null || envelope.Version != 1 || envelope.Executables is null)
            {
                return CorruptSnapshot("The protected chat executable inventory could not be decoded.");
            }

            ApprovedChatExecutable[] executables = envelope.Executables
                .Where(IsWellFormed)
                .ToArray();
            if (executables.Length == 0)
            {
                return ChatExecutableInventorySnapshot.SetupRequired();
            }

            return SnapshotFor(executables, envelope.UpdatedAt);
        }
        catch (SecretStoreException ex)
        {
            return ex.Failure is SecretStoreFailureKind.ProtectedStorageUnavailable
                    or SecretStoreFailureKind.ReadDenied
                ? UnavailableSnapshot(ex.Message)
                : CorruptSnapshot(ex.Message);
        }
        catch (Exception ex) when (ex is JsonException or FormatException or IOException or UnauthorizedAccessException)
        {
            return CorruptSnapshot(ex.Message);
        }
    }

    public ApprovedChatExecutableCatalog LoadCatalog()
    {
        ChatExecutableInventorySnapshot snapshot = LoadSnapshot();
        if (snapshot.Status.Kind is ChatExecutableInventoryStatusKind.InventoryUnavailable
            or ChatExecutableInventoryStatusKind.InventoryCorrupt)
        {
            throw new ChatProcessException(
                ChatFailureKind.ExecutableInventoryUnavailable,
                snapshot.Status.Title + " " + snapshot.Status.Message);
        }

        return new ApprovedChatExecutableCatalog(snapshot.Executables);
    }

    public ApprovedChatExecutable ApproveExecutable(string path, string? id = null)
    {
        ApprovedChatExecutable entry = EntryFor(path, id);
        ApprovedChatExecutable[] existing = LoadMutableEntries()
            .Where(item => !string.Equals(item.Id, entry.Id, StringComparison.OrdinalIgnoreCase))
            .Append(entry)
            .OrderBy(item => item.Id, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        Write(existing);
        return entry;
    }

    public ApprovedChatExecutable RotateExecutable(string id, string path)
    {
        if (string.IsNullOrWhiteSpace(id))
        {
            throw new ArgumentException("Executable id is required.", nameof(id));
        }

        ApprovedChatExecutable entry = EntryFor(path, id);
        ApprovedChatExecutable[] existing = LoadMutableEntries()
            .Where(item => !string.Equals(item.Id, entry.Id, StringComparison.OrdinalIgnoreCase))
            .Append(entry)
            .OrderBy(item => item.Id, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        Write(existing);
        return entry;
    }

    public bool RemoveExecutable(string id)
    {
        if (string.IsNullOrWhiteSpace(id))
        {
            return false;
        }

        ApprovedChatExecutable[] remaining = LoadMutableEntries()
            .Where(item => !string.Equals(item.Id, id.Trim(), StringComparison.OrdinalIgnoreCase))
            .ToArray();
        if (remaining.Length == 0)
        {
            _secretStore.Delete(_secretName);
            return true;
        }

        Write(remaining);
        return true;
    }

    private ApprovedChatExecutable[] LoadMutableEntries()
    {
        ChatExecutableInventorySnapshot snapshot = LoadSnapshot();
        if (snapshot.Status.Kind is ChatExecutableInventoryStatusKind.InventoryUnavailable
            or ChatExecutableInventoryStatusKind.InventoryCorrupt)
        {
            return Array.Empty<ApprovedChatExecutable>();
        }

        return snapshot.Executables.ToArray();
    }

    private void Write(IReadOnlyList<ApprovedChatExecutable> executables)
    {
        if (executables.Count == 0)
        {
            _secretStore.Delete(_secretName);
            return;
        }

        var envelope = new ChatExecutableInventoryEnvelope
        {
            Version = 1,
            UpdatedAt = DateTimeOffset.UtcNow,
            Executables = executables.ToArray(),
        };
        _secretStore.Write(_secretName, JsonSerializer.Serialize(envelope, JsonOptions));
    }

    private static ApprovedChatExecutable EntryFor(string path, string? id)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new ChatProcessException(ChatFailureKind.ExecutableDenied, "Chat executable path is required.");
        }

        string fullPath = Path.GetFullPath(path.Trim());
        if (!File.Exists(fullPath))
        {
            throw new ChatProcessException(
                ChatFailureKind.ExecutableUnavailable,
                "Chat executable does not exist: " + fullPath);
        }

        string entryId = NormalizeId(id) ?? NormalizeId(Path.GetFileNameWithoutExtension(fullPath))
            ?? throw new ChatProcessException(ChatFailureKind.ExecutableDenied, "Chat executable id is empty.");
        return new ApprovedChatExecutable(entryId, fullPath, ApprovedChatExecutableCatalog.ComputeSha256(fullPath));
    }

    private static ChatExecutableInventorySnapshot SnapshotFor(
        IReadOnlyList<ApprovedChatExecutable> executables,
        DateTimeOffset updatedAt)
    {
        ApprovedChatExecutable? missing = executables.FirstOrDefault(entry => !File.Exists(Path.GetFullPath(entry.Path)));
        if (missing is not null)
        {
            return new ChatExecutableInventorySnapshot(
                executables,
                new ChatExecutableInventoryStatus(
                    ChatExecutableInventoryStatusKind.ExecutableUnavailable,
                    "Approved chat executable is missing.",
                    missing.Path),
                updatedAt);
        }

        ApprovedChatExecutable? replaced = executables.FirstOrDefault(entry =>
            !string.Equals(
                ApprovedChatExecutableCatalog.ComputeSha256(Path.GetFullPath(entry.Path)),
                entry.Sha256,
                StringComparison.OrdinalIgnoreCase));
        if (replaced is not null)
        {
            return new ChatExecutableInventorySnapshot(
                executables,
                new ChatExecutableInventoryStatus(
                    ChatExecutableInventoryStatusKind.ExecutableReplaced,
                    "Approved chat executable was replaced.",
                    replaced.Path),
                updatedAt);
        }

        ApprovedChatExecutable primary = executables[0];
        return new ChatExecutableInventorySnapshot(
            executables,
            new ChatExecutableInventoryStatus(
                ChatExecutableInventoryStatusKind.Ready,
                "Chat CLI executable approved.",
                primary.Id + " -> " + primary.Path),
            updatedAt);
    }

    private static ChatExecutableInventorySnapshot UnavailableSnapshot(string message) =>
        new(
            Array.Empty<ApprovedChatExecutable>(),
            new ChatExecutableInventoryStatus(
                ChatExecutableInventoryStatusKind.InventoryUnavailable,
                "Protected chat executable inventory is unavailable.",
                message));

    private static ChatExecutableInventorySnapshot CorruptSnapshot(string message) =>
        new(
            Array.Empty<ApprovedChatExecutable>(),
            new ChatExecutableInventoryStatus(
                ChatExecutableInventoryStatusKind.InventoryCorrupt,
                "Protected chat executable inventory needs recovery.",
                message));

    private static bool IsWellFormed(ApprovedChatExecutable executable) =>
        !string.IsNullOrWhiteSpace(executable.Id)
        && !string.IsNullOrWhiteSpace(executable.Path)
        && !string.IsNullOrWhiteSpace(executable.Sha256);

    private static string? NormalizeId(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        string normalized = new string(value.Trim().Select(ch =>
            char.IsLetterOrDigit(ch) ? char.ToLowerInvariant(ch) : '-').ToArray()).Trim('-');
        while (normalized.Contains("--", StringComparison.Ordinal))
        {
            normalized = normalized.Replace("--", "-", StringComparison.Ordinal);
        }

        return normalized.Length == 0 ? null : normalized;
    }

    private sealed record ChatExecutableInventoryEnvelope
    {
        public int Version { get; init; }
        public DateTimeOffset UpdatedAt { get; init; }
        public ApprovedChatExecutable[] Executables { get; init; } = Array.Empty<ApprovedChatExecutable>();
    }
}
