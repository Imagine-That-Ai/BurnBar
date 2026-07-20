using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace OpenBurnBar.ComputerUse.Core.Loop;

public enum PrivilegedInputReceiptState
{
    Reserved,
    Completed,
    Indeterminate,
}

public sealed record PrivilegedInputReceiptReservation(
    PrivilegedInputReceiptState State,
    PrivilegedInputResponse? Response = null);

/// <summary>
/// At-most-once action ledger. A reservation is durable before native input and
/// a completed response is replayable after a lost IPC response. An abandoned
/// reservation is indeterminate and is never dispatched a second time.
/// </summary>
public interface IPrivilegedInputReceiptStore
{
    PrivilegedInputReceiptReservation Reserve(string actionId);
    void Complete(string actionId, PrivilegedInputResponse response);
}

public sealed class InMemoryPrivilegedInputReceiptStore : IPrivilegedInputReceiptStore
{
    private readonly object _gate = new();
    private readonly Dictionary<string, PrivilegedInputResponse?> _entries = new(StringComparer.Ordinal);

    public PrivilegedInputReceiptReservation Reserve(string actionId)
    {
        ValidateActionId(actionId);
        lock (_gate)
        {
            if (!_entries.TryGetValue(actionId, out PrivilegedInputResponse? response))
            {
                _entries.Add(actionId, null);
                return new PrivilegedInputReceiptReservation(PrivilegedInputReceiptState.Reserved);
            }
            return response is null
                ? new PrivilegedInputReceiptReservation(PrivilegedInputReceiptState.Indeterminate)
                : new PrivilegedInputReceiptReservation(PrivilegedInputReceiptState.Completed, response);
        }
    }

    public void Complete(string actionId, PrivilegedInputResponse response)
    {
        ValidateActionId(actionId);
        ArgumentNullException.ThrowIfNull(response);
        lock (_gate)
        {
            if (!_entries.ContainsKey(actionId))
            {
                throw new InvalidOperationException("The privileged-input action was not reserved.");
            }
            _entries[actionId] = response;
        }
    }

    internal static void ValidateActionId(string actionId)
    {
        if (string.IsNullOrWhiteSpace(actionId)
            || actionId.Length > 128
            || actionId.Any(char.IsControl))
        {
            throw new ArgumentException("A bounded action id is required.", nameof(actionId));
        }
    }
}

public sealed class FilePrivilegedInputReceiptStore : IPrivilegedInputReceiptStore
{
    private const int MaximumEntries = 10_000;
    private const int MaximumBytes = 2 * 1024 * 1024;
    private readonly string _path;
    private readonly object _gate = new();

    public FilePrivilegedInputReceiptStore(string path)
    {
        _path = Path.GetFullPath(path ?? throw new ArgumentNullException(nameof(path)));
    }

    public PrivilegedInputReceiptReservation Reserve(string actionId)
    {
        InMemoryPrivilegedInputReceiptStore.ValidateActionId(actionId);
        lock (_gate)
        {
            Ledger ledger = Load();
            Receipt? existing = ledger.Entries.FirstOrDefault(entry =>
                string.Equals(entry.ActionId, actionId, StringComparison.Ordinal));
            if (existing is not null)
            {
                return existing.Completed
                    ? new PrivilegedInputReceiptReservation(
                        PrivilegedInputReceiptState.Completed,
                        new PrivilegedInputResponse(existing.Ok, existing.Detail))
                    : new PrivilegedInputReceiptReservation(PrivilegedInputReceiptState.Indeterminate);
            }

            ledger.Entries.Add(new Receipt(actionId, Completed: false, Ok: false, "reserved"));
            Trim(ledger);
            Persist(ledger);
            return new PrivilegedInputReceiptReservation(PrivilegedInputReceiptState.Reserved);
        }
    }

    public void Complete(string actionId, PrivilegedInputResponse response)
    {
        InMemoryPrivilegedInputReceiptStore.ValidateActionId(actionId);
        ArgumentNullException.ThrowIfNull(response);
        lock (_gate)
        {
            Ledger ledger = Load();
            int index = ledger.Entries.FindIndex(entry =>
                string.Equals(entry.ActionId, actionId, StringComparison.Ordinal));
            if (index < 0)
            {
                throw new InvalidOperationException("The privileged-input action was not reserved.");
            }
            ledger.Entries[index] = new Receipt(actionId, Completed: true, response.Ok, response.Detail);
            Persist(ledger);
        }
    }

    private Ledger Load()
    {
        if (!File.Exists(_path))
        {
            return new Ledger();
        }
        var info = new FileInfo(_path);
        if ((info.Attributes & FileAttributes.ReparsePoint) != 0
            || info.Length is <= 0 or > MaximumBytes)
        {
            throw new InvalidOperationException("The privileged-input receipt ledger is invalid.");
        }
        try
        {
            Ledger ledger = JsonSerializer.Deserialize<Ledger>(File.ReadAllBytes(_path))
                ?? throw new InvalidOperationException("The privileged-input receipt ledger is empty.");
            if (ledger.Entries is null
                || ledger.Entries.Count > MaximumEntries
                || ledger.Entries.Any(entry => !ValidReceipt(entry)))
            {
                throw new InvalidOperationException("The privileged-input receipt ledger is invalid.");
            }
            return ledger;
        }
        catch (JsonException error)
        {
            throw new InvalidOperationException("The privileged-input receipt ledger is corrupt.", error);
        }
    }

    private void Persist(Ledger ledger)
    {
        string? directory = Path.GetDirectoryName(_path);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }
        byte[] payload = JsonSerializer.SerializeToUtf8Bytes(ledger);
        if (payload.Length > MaximumBytes)
        {
            throw new InvalidOperationException("The privileged-input receipt ledger exceeds its size limit.");
        }
        string temporary = _path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            using (var stream = new FileStream(
                temporary,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                4096,
                FileOptions.WriteThrough))
            {
                stream.Write(payload);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, _path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private static void Trim(Ledger ledger)
    {
        if (ledger.Entries.Count > MaximumEntries)
        {
            ledger.Entries.RemoveRange(0, ledger.Entries.Count - (MaximumEntries / 2));
        }
    }

    private static bool ValidReceipt(Receipt? entry) =>
        entry is not null
        && !string.IsNullOrWhiteSpace(entry.ActionId)
        && entry.ActionId.Length <= 128
        && !entry.ActionId.Any(char.IsControl)
        && !string.IsNullOrWhiteSpace(entry.Detail)
        && entry.Detail.Length <= 128
        && !entry.Detail.Any(char.IsControl)
        && (entry.Completed || (!entry.Ok && entry.Detail == "reserved"));

    public sealed class Ledger
    {
        public List<Receipt> Entries { get; set; } = new();
    }

    public sealed record Receipt(string ActionId, bool Completed, bool Ok, string Detail);
}
