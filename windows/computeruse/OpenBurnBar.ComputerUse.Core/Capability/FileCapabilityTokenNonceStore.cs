// File-backed single-use nonce ledger.
//
// Port of FileCapabilityTokenNonceStore.swift — the offline, no-network ledger
// the Virtual-HID / daemon leaf consults. A lock serializes every load/persist
// cycle; the ledger is capped so it cannot grow without bound.

using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace OpenBurnBar.ComputerUse.Core.Capability;

/// <summary>Durable, capped, lock-serialized nonce ledger.</summary>
public sealed class FileCapabilityTokenNonceStore : ICapabilityTokenNonceStore
{
    private const int MaximumEntries = 10_000;

    private readonly string _path;
    private readonly object _gate = new();

    public FileCapabilityTokenNonceStore(string path)
    {
        _path = path ?? throw new ArgumentNullException(nameof(path));
    }

    public bool HasConsumed(string nonce, CapabilityDomain domain)
    {
        lock (_gate)
        {
            return Load().Contains(EntryKey(nonce, domain));
        }
    }

    public void Consume(string nonce, CapabilityDomain domain)
    {
        lock (_gate)
        {
            var ledger = Load();
            var entry = EntryKey(nonce, domain);
            if (ledger.Contains(entry))
            {
                throw new CapabilityTokenReplayException();
            }

            ledger.Add(entry);
            if (ledger.Count > MaximumEntries)
            {
                ledger = new List<string>(ledger.GetRange(ledger.Count - (MaximumEntries / 2), MaximumEntries / 2));
            }

            Persist(ledger);
        }
    }

    private static string EntryKey(string nonce, CapabilityDomain domain) => $"{domain.ToWire()}:{nonce}";

    private List<string> Load()
    {
        try
        {
            if (!File.Exists(_path))
            {
                return new List<string>();
            }

            var json = File.ReadAllText(_path);
            var ledger = JsonSerializer.Deserialize<Ledger>(json);
            return ledger?.Consumed ?? new List<string>();
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            return new List<string>();
        }
    }

    private void Persist(List<string> consumed)
    {
        var directory = Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var json = JsonSerializer.Serialize(new Ledger { Consumed = consumed });
        var temp = _path + ".tmp";
        File.WriteAllText(temp, json);
        // Atomic-ish replace so a crash mid-write never leaves a truncated ledger.
        if (File.Exists(_path))
        {
            File.Replace(temp, _path, destinationBackupFileName: null);
        }
        else
        {
            File.Move(temp, _path);
        }
    }

    private sealed class Ledger
    {
        public List<string> Consumed { get; set; } = new();
    }
}
