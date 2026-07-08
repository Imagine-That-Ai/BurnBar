// JSONL audit-chain reader + validator.
//
// Port of ComputerUseAuditChain.swift. Walks a JSONL chain and re-derives every
// entry's hash against its predecessor, stopping at the first mismatch. If an
// expected terminal head hash is supplied (from the signed head), the walker
// compares its recomputed head against it — this is what catches tampering of
// the LAST entry, which a parent-chain walk alone cannot detect. Strict
// verification (L8b) fails closed when the head anchor is required but missing.

using System;
using System.Collections.Generic;
using System.Text;
using OpenBurnBar.ComputerUse.Core.Crypto;

namespace OpenBurnBar.ComputerUse.Core.Audit;

/// <summary>Why a chain failed validation.</summary>
public enum AuditChainInvalidReason
{
    None = 0,
    ParentHashMismatch,
    UnexpectedEntryIndex,
    DecodeFailure,
    TruncatedFile,
    UnsupportedSchema,
    HeadHashMismatch,

    /// <summary>Strict verification requested but no signed terminal head supplied.</summary>
    HeadAnchorMissing,
}

/// <summary>Wire strings for <see cref="AuditChainInvalidReason"/>.</summary>
public static class AuditChainInvalidReasonWire
{
    public static string ToWire(this AuditChainInvalidReason reason) => reason switch
    {
        AuditChainInvalidReason.None => "none",
        AuditChainInvalidReason.ParentHashMismatch => "parent_hash_mismatch",
        AuditChainInvalidReason.UnexpectedEntryIndex => "unexpected_entry_index",
        AuditChainInvalidReason.DecodeFailure => "decode_failure",
        AuditChainInvalidReason.TruncatedFile => "truncated_file",
        AuditChainInvalidReason.UnsupportedSchema => "unsupported_schema",
        AuditChainInvalidReason.HeadHashMismatch => "head_hash_mismatch",
        AuditChainInvalidReason.HeadAnchorMissing => "head_anchor_missing",
        _ => throw new ArgumentOutOfRangeException(nameof(reason), reason, null),
    };
}

/// <summary>The result of walking a chain.</summary>
public sealed class AuditChainValidationResult
{
    public AuditChainValidationResult(
        int entryCount,
        bool isValid,
        int? firstInvalidEntryIndex = null,
        AuditChainInvalidReason firstInvalidReason = AuditChainInvalidReason.None,
        string? headHashHex = null)
    {
        EntryCount = entryCount;
        IsValid = isValid;
        FirstInvalidEntryIndex = firstInvalidEntryIndex;
        FirstInvalidReason = firstInvalidReason;
        HeadHashHex = headHashHex;
    }

    public int EntryCount { get; }

    public bool IsValid { get; }

    public int? FirstInvalidEntryIndex { get; }

    public AuditChainInvalidReason FirstInvalidReason { get; }

    public string? HeadHashHex { get; }
}

/// <summary>Pure JSONL chain validator (no file I/O beyond the caller-supplied bytes).</summary>
public sealed class ComputerUseAuditChain
{
    private readonly AuditHasher _hasher;

    public ComputerUseAuditChain(AuditHasher? hasher = null)
    {
        _hasher = hasher ?? AuditHasher.Current;
    }

    /// <summary>Hashes the session manifest — the parent an empty chain's first entry lists.</summary>
    public string HashSessionManifest(CanonicalJsonObject manifestCanonicalMap)
        => _hasher.Hash(manifestCanonicalMap);

    /// <summary>Validates a chain from raw JSONL bytes.</summary>
    public AuditChainValidationResult Validate(
        ReadOnlySpan<byte> rawJsonLines,
        string sessionManifestHashHex,
        string? expectedHeadHashHex = null,
        bool requireExpectedHead = false)
    {
        // L8b: a required-but-missing head anchor is a failure, not a silent pass.
        if (requireExpectedHead && string.IsNullOrEmpty(expectedHeadHashHex))
        {
            return new AuditChainValidationResult(0, isValid: false, firstInvalidReason: AuditChainInvalidReason.HeadAnchorMissing);
        }

        string text;
        try
        {
            text = Encoding.UTF8.GetString(rawJsonLines);
        }
        catch (ArgumentException)
        {
            return new AuditChainValidationResult(0, isValid: false, firstInvalidReason: AuditChainInvalidReason.DecodeFailure);
        }

        var expectedIndex = 0;
        var parentHashHex = sessionManifestHashHex;
        var entries = new List<ComputerUseAuditEntry>();
        var lineNumber = 0;

        foreach (var rawLine in SplitNonEmptyLines(text))
        {
            var lineBytes = Encoding.UTF8.GetBytes(rawLine);
            var entry = ComputerUseAuditEntry.FromJsonLine(lineBytes);
            if (entry is null)
            {
                return new AuditChainValidationResult(
                    entries.Count,
                    isValid: false,
                    firstInvalidEntryIndex: lineNumber,
                    firstInvalidReason: AuditChainInvalidReason.DecodeFailure);
            }

            if (entry.SchemaVersion != ComputerUseAuditEntry.CurrentSchemaVersion)
            {
                return new AuditChainValidationResult(
                    entries.Count,
                    isValid: false,
                    firstInvalidEntryIndex: entry.EntryIndex,
                    firstInvalidReason: AuditChainInvalidReason.UnsupportedSchema);
            }

            if (entry.EntryIndex != expectedIndex)
            {
                return new AuditChainValidationResult(
                    entries.Count,
                    isValid: false,
                    firstInvalidEntryIndex: entry.EntryIndex,
                    firstInvalidReason: AuditChainInvalidReason.UnexpectedEntryIndex);
            }

            if (entry.ParentEntryHashHex != parentHashHex)
            {
                return new AuditChainValidationResult(
                    entries.Count,
                    isValid: false,
                    firstInvalidEntryIndex: entry.EntryIndex,
                    firstInvalidReason: AuditChainInvalidReason.ParentHashMismatch);
            }

            parentHashHex = _hasher.Hash(entry.CanonicalBytes());
            entries.Add(entry);
            expectedIndex++;
            lineNumber++;
        }

        // A pinned head hash catches tampering of the LAST entry.
        if (!string.IsNullOrEmpty(expectedHeadHashHex) && expectedHeadHashHex != parentHashHex)
        {
            return new AuditChainValidationResult(
                entries.Count,
                isValid: false,
                firstInvalidEntryIndex: Math.Max(entries.Count - 1, 0),
                firstInvalidReason: AuditChainInvalidReason.HeadHashMismatch,
                headHashHex: parentHashHex);
        }

        var headHash = parentHashHex == sessionManifestHashHex && entries.Count == 0
            ? sessionManifestHashHex
            : parentHashHex;
        return new AuditChainValidationResult(entries.Count, isValid: true, headHashHex: headHash);
    }

    private static IEnumerable<string> SplitNonEmptyLines(string text)
    {
        foreach (var line in text.Split('\n'))
        {
            if (line.Length > 0)
            {
                yield return line;
            }
        }
    }
}
