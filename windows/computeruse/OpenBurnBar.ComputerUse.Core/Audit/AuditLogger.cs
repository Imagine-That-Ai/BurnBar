// Append-only writer that maintains the parent-hash chain for a live session.
//
// Port of ComputerUseAuditLogger.swift. Given an already-built entry the writer:
//   1. validates entry.entryIndex == nextEntryIndex,
//   2. validates entry.parentEntryHashHex == the current head,
//   3. encodes the entry as canonical JSON + appends the line + '\n',
//   4. re-hashes the just-written entry to advance the head, and
//   5. rewrites head.json.
//
// It is the fail-closed audit reservation: the dispatcher appends the entry
// BEFORE it dispatches, so an unappendable audit denies the action.

using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using OpenBurnBar.ComputerUse.Core.Crypto;
using OpenBurnBar.ComputerUse.Core.Gate;

namespace OpenBurnBar.ComputerUse.Core.Audit;

/// <summary>Stateful, single-threaded audit-chain writer. Wrap calls in a serializer.</summary>
public sealed class ComputerUseAuditLogger
{
    private const long MaximumManifestBytes = 256 * 1024;
    private const long MaximumChainBytes = 32 * 1024 * 1024;
    private const long MaximumHeadBytes = 64 * 1024;
    private readonly AuditHasher _hasher;

    public ComputerUseAuditLogger(
        string sessionId,
        string baseDirectory,
        string macAppVersion,
        AuditHasher? hasher = null)
    {
        SessionId = sessionId;
        Directory = Path.Combine(baseDirectory, sessionId);
        MacAppVersion = macAppVersion;
        _hasher = hasher ?? AuditHasher.Current;
        HeadHashHex = AuditHasher.GenesisParentHashHex;
        NextEntryIndex = 0;

        System.IO.Directory.CreateDirectory(Directory);
        System.IO.Directory.CreateDirectory(Path.Combine(Directory, "screenshots"));
    }

    public string SessionId { get; }

    public string Directory { get; }

    public string MacAppVersion { get; }

    public string HeadHashHex { get; private set; }

    public int NextEntryIndex { get; private set; }

    /// <summary>Errors the logger can raise; every one denies the pending action.</summary>
    public enum AuditLoggerError
    {
        ManifestAlreadyExists,
        ChainHeadCorrupted,
        ParentHashMismatch,
    }

    /// <summary>Thrown for every <see cref="AuditLoggerError"/>.</summary>
    public sealed class AuditLoggerException : Exception
    {
        public AuditLoggerException(AuditLoggerError reason)
            : base($"Audit logger error: {reason}.")
        {
            Reason = reason;
        }

        public AuditLoggerError Reason { get; }
    }

    /// <summary>Writes the session manifest, hashes it, and seeds the chain head.</summary>
    public void BeginSession(ComputerUseSessionManifest manifest)
    {
        var manifestPath = Path.Combine(Directory, "manifest.json");
        var encoded = CanonicalJson.Encode(manifest.ToCanonicalMap());
        if (File.Exists(manifestPath))
        {
            var onDisk = File.ReadAllBytes(manifestPath);
            if (!ByteEquals(onDisk, encoded))
            {
                throw new AuditLoggerException(AuditLoggerError.ManifestAlreadyExists);
            }
        }
        else
        {
            File.WriteAllBytes(manifestPath, encoded);
        }

        HeadHashHex = _hasher.Hash(encoded);
        WriteHeadMarker();
    }

    /// <summary>
    /// Restores an existing session only after the manifest, complete chain, and
    /// terminal head marker agree. Any missing, redirected, or tampered state
    /// fails closed before a new entry can be appended.
    /// </summary>
    public void ResumeExistingSession()
    {
        EnsureNotReparsePoint(new DirectoryInfo(Directory));
        string manifestPath = Path.Combine(Directory, "manifest.json");
        string chainPath = Path.Combine(Directory, "chain.jsonl");
        string headPath = Path.Combine(Directory, "head.json");
        EnsureNotReparsePoint(new FileInfo(manifestPath));
        EnsureNotReparsePoint(new FileInfo(headPath));
        if (File.Exists(chainPath))
        {
            EnsureNotReparsePoint(new FileInfo(chainPath));
        }

        byte[] manifest = ReadBounded(manifestPath, MaximumManifestBytes);
        byte[] chain = File.Exists(chainPath)
            ? ReadBounded(chainPath, MaximumChainBytes)
            : Array.Empty<byte>();
        using JsonDocument headDocument = JsonDocument.Parse(ReadBounded(headPath, MaximumHeadBytes));
        JsonElement head = headDocument.RootElement;
        if (head.ValueKind != JsonValueKind.Object
            || !head.TryGetProperty("sessionId", out JsonElement sessionElement)
            || sessionElement.ValueKind != JsonValueKind.String
            || !string.Equals(sessionElement.GetString(), SessionId, StringComparison.Ordinal)
            || !head.TryGetProperty("index", out JsonElement indexElement)
            || indexElement.ValueKind != JsonValueKind.Number
            || !indexElement.TryGetInt32(out int index)
            || index < 0
            || !head.TryGetProperty("hashHex", out JsonElement hashElement)
            || hashElement.ValueKind != JsonValueKind.String
            || hashElement.GetString() is not string expectedHead
            || expectedHead.Length != 64
            || !expectedHead.All(Uri.IsHexDigit))
        {
            throw new AuditLoggerException(AuditLoggerError.ChainHeadCorrupted);
        }

        string manifestHash = _hasher.Hash(manifest);
        AuditChainValidationResult result = new ComputerUseAuditChain(_hasher).Validate(
            chain,
            manifestHash,
            expectedHead,
            requireExpectedHead: true);
        if (!result.IsValid || result.EntryCount != index)
        {
            throw new AuditLoggerException(AuditLoggerError.ChainHeadCorrupted);
        }

        HeadHashHex = expectedHead.ToLowerInvariant();
        NextEntryIndex = index;
    }

    /// <summary>Appends an entry and returns the resulting head hash.</summary>
    public string Append(ComputerUseAuditEntry entry)
    {
        if (entry.EntryIndex != NextEntryIndex)
        {
            throw new AuditLoggerException(AuditLoggerError.ChainHeadCorrupted);
        }

        if (entry.ParentEntryHashHex != HeadHashHex)
        {
            throw new AuditLoggerException(AuditLoggerError.ParentHashMismatch);
        }

        var encoded = entry.CanonicalBytes();
        var chainPath = Path.Combine(Directory, "chain.jsonl");
        using (var stream = new FileStream(chainPath, FileMode.Append, FileAccess.Write, FileShare.Read))
        {
            stream.Write(encoded, 0, encoded.Length);
            stream.WriteByte(0x0A); // '\n'
        }

        HeadHashHex = _hasher.Hash(encoded);
        NextEntryIndex++;
        WriteHeadMarker();
        return HeadHashHex;
    }

    /// <summary>Builds the next entry from a typed action + the gate's approvedBy verdict.</summary>
    public ComputerUseAuditEntry MakeEntry(
        ComputerUseAction action,
        DateTimeOffset timestamp,
        AuditApprovedBy approvedBy,
        string? approvalId = null,
        string? scopeRuleId = null,
        string? denyReason = null,
        string? beforeScreenshotHashHex = null,
        string? afterScreenshotHashHex = null,
        string? macHostNodeId = null,
        ScopeContextSummary? scopeContext = null)
    {
        var descriptorHash = _hasher.Hash(action.ToCanonicalMap());
        return new ComputerUseAuditEntry(
            sessionId: SessionId,
            entryIndex: NextEntryIndex,
            timestamp: timestamp,
            actionKind: action.AuditKind,
            actionSummary: action.ExecutableSummary(scopeContext),
            actionDescriptorHashHex: descriptorHash,
            approvedBy: approvedBy,
            parentEntryHashHex: HeadHashHex,
            macAppVersion: MacAppVersion,
            beforeScreenshotHashHex: beforeScreenshotHashHex,
            afterScreenshotHashHex: afterScreenshotHashHex,
            approvalId: approvalId,
            scopeRuleId: scopeRuleId,
            denyReason: denyReason,
            macHostNodeId: macHostNodeId);
    }

    private void WriteHeadMarker()
    {
        var map = new CanonicalJsonObject()
            .Set("index", NextEntryIndex)
            .Set("hashHex", HeadHashHex)
            .Set("updatedAt", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())
            .Set("sessionId", SessionId)
            .Set("schemaVersion", ComputerUseAuditEntry.CurrentSchemaVersion);
        File.WriteAllBytes(Path.Combine(Directory, "head.json"), CanonicalJson.Encode(map));
    }

    private static bool ByteEquals(byte[] a, byte[] b)
    {
        if (a.Length != b.Length)
        {
            return false;
        }

        for (var i = 0; i < a.Length; i++)
        {
            if (a[i] != b[i])
            {
                return false;
            }
        }

        return true;
    }

    private static void EnsureNotReparsePoint(FileSystemInfo info)
    {
        if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new AuditLoggerException(AuditLoggerError.ChainHeadCorrupted);
        }
    }

    private static byte[] ReadBounded(string path, long maximumBytes)
    {
        var info = new FileInfo(path);
        EnsureNotReparsePoint(info);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        long length = stream.Length;
        if (length < 0 || length > maximumBytes || length > int.MaxValue)
        {
            throw new AuditLoggerException(AuditLoggerError.ChainHeadCorrupted);
        }
        var bytes = new byte[(int)length];
        stream.ReadExactly(bytes);
        if (stream.ReadByte() != -1)
        {
            throw new AuditLoggerException(AuditLoggerError.ChainHeadCorrupted);
        }
        return bytes;
    }
}
