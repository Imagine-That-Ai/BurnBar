// Standalone offline verifier for exported audit chains.
//
// Port of the portable half of ComputerUseAuditVerifier.swift: chain integrity +
// head-anchor + head signature + no-entries-after-index. (The OpenTimestamps leg
// is a macOS-only external-binary dependency and is out of scope for the
// portable core; the interface leaves room for it.)

using System;
using OpenBurnBar.ComputerUse.Core.Crypto;

namespace OpenBurnBar.ComputerUse.Core.Audit;

/// <summary>Offline audit-chain verification report.</summary>
public sealed class AuditVerificationReport
{
    public AuditVerificationReport(
        bool chainValid,
        int entryCount,
        string? headHashHex,
        bool? headSignatureValid,
        bool? noEntriesAfterIndex,
        AuditChainInvalidReason firstInvalidReason)
    {
        ChainValid = chainValid;
        EntryCount = entryCount;
        HeadHashHex = headHashHex;
        HeadSignatureValid = headSignatureValid;
        NoEntriesAfterIndex = noEntriesAfterIndex;
        FirstInvalidReason = firstInvalidReason;
    }

    public bool ChainValid { get; }

    public int EntryCount { get; }

    public string? HeadHashHex { get; }

    public bool? HeadSignatureValid { get; }

    public bool? NoEntriesAfterIndex { get; }

    public AuditChainInvalidReason FirstInvalidReason { get; }

    /// <summary>True iff every supplied check passed (unsupplied checks are treated as passing).</summary>
    public bool IsFullyVerified =>
        ChainValid
        && (HeadSignatureValid ?? true)
        && (NoEntriesAfterIndex ?? true);
}

/// <summary>Composes chain integrity + head signature + bound checks into one report.</summary>
public sealed class ComputerUseAuditVerifier
{
    private readonly ComputerUseAuditChain _chainValidator;

    public ComputerUseAuditVerifier(AuditHasher? hasher = null)
    {
        _chainValidator = new ComputerUseAuditChain(hasher);
    }

    public AuditVerificationReport Verify(
        ReadOnlySpan<byte> chainJsonl,
        string sessionManifestHashHex,
        ComputerUseAuditSignedHead? signedHead,
        int? maxEntryIndexInclusive = null)
    {
        var chainResult = _chainValidator.Validate(
            chainJsonl,
            sessionManifestHashHex,
            expectedHeadHashHex: signedHead?.HeadHashHex);

        bool? headSignatureValid = signedHead is null ? null : signedHead.VerifySignature();

        bool? noEntriesAfterIndex = null;
        if (maxEntryIndexInclusive is { } maxIndex)
        {
            var lastIndex = signedHead?.LastEntryIndex
                ?? (chainResult.EntryCount > 0 ? chainResult.EntryCount - 1 : -1);
            noEntriesAfterIndex = chainResult.EntryCount <= maxIndex + 1 && lastIndex <= maxIndex;
        }

        return new AuditVerificationReport(
            chainValid: chainResult.IsValid,
            entryCount: chainResult.EntryCount,
            headHashHex: chainResult.HeadHashHex,
            headSignatureValid: headSignatureValid,
            noEntriesAfterIndex: noEntriesAfterIndex,
            firstInvalidReason: chainResult.FirstInvalidReason);
    }
}
