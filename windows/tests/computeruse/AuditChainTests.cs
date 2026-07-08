using System;
using System.IO;
using System.Text;
using OpenBurnBar.ComputerUse.Core.Audit;
using OpenBurnBar.ComputerUse.Core.Crypto;
using OpenBurnBar.ComputerUse.Core.Gate;
using Xunit;

namespace OpenBurnBar.ComputerUse.Tests;

public sealed class AuditChainTests : IDisposable
{
    private static readonly DateTimeOffset Started = new(2026, 7, 3, 9, 0, 0, TimeSpan.Zero);

    private readonly string _dir = Path.Combine(Path.GetTempPath(), "cu-audit-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_dir))
        {
            Directory.Delete(_dir, recursive: true);
        }
    }

    private static ComputerUseSessionManifest Manifest(string sessionId) => new(
        sessionId: sessionId,
        mode: ComputerUseMode.Browser,
        trustMode: ComputerUseTrustMode.Manual,
        startedAt: Started,
        userId: "user-1",
        entitlementProductId: "prod.computer_use",
        actionCap: 50,
        sessionTimeoutSeconds: 1800);

    private (byte[] chain, string manifestHash, string headHash, ComputerUseAuditLogger logger)
        BuildChain(int entries)
    {
        var manifest = Manifest("sess-1");
        var logger = new ComputerUseAuditLogger("sess-1", _dir, macAppVersion: "1.0.0");
        logger.BeginSession(manifest);
        for (var i = 0; i < entries; i++)
        {
            var entry = new ComputerUseAuditEntry(
                sessionId: "sess-1",
                entryIndex: i,
                timestamp: Started.AddSeconds(i),
                actionKind: "browser.click",
                actionSummary: $"sum-{i}",
                actionDescriptorHashHex: "deadbeef",
                approvedBy: AuditApprovedBy.Mac,
                parentEntryHashHex: logger.HeadHashHex,
                macAppVersion: "1.0.0");
            logger.Append(entry);
        }

        var chainPath = Path.Combine(logger.Directory, "chain.jsonl");
        // The chain file is created on first append (parity with the Swift logger),
        // so a zero-entry session has no file yet — treat that as empty bytes.
        var chainBytes = File.Exists(chainPath) ? File.ReadAllBytes(chainPath) : Array.Empty<byte>();
        var manifestHash = new ComputerUseAuditChain().HashSessionManifest(manifest.ToCanonicalMap());
        return (chainBytes, manifestHash, logger.HeadHashHex, logger);
    }

    [Fact]
    public void ValidChainVerifies()
    {
        var (chain, manifestHash, headHash, _) = BuildChain(3);
        var result = new ComputerUseAuditChain().Validate(chain, manifestHash);

        Assert.True(result.IsValid);
        Assert.Equal(3, result.EntryCount);
        Assert.Equal(headHash, result.HeadHashHex);
    }

    [Fact]
    public void EmptyChainHeadIsTheManifestHash()
    {
        var (chain, manifestHash, _, _) = BuildChain(0);
        var result = new ComputerUseAuditChain().Validate(chain, manifestHash);

        Assert.True(result.IsValid);
        Assert.Equal(0, result.EntryCount);
        Assert.Equal(manifestHash, result.HeadHashHex);
    }

    [Fact]
    public void TamperingAMiddleEntryIsDetected()
    {
        var (chain, manifestHash, _, _) = BuildChain(3);
        var text = Encoding.UTF8.GetString(chain).Replace("sum-0", "SUM-0", StringComparison.Ordinal);

        var result = new ComputerUseAuditChain().Validate(Encoding.UTF8.GetBytes(text), manifestHash);

        Assert.False(result.IsValid);
        Assert.Equal(AuditChainInvalidReason.ParentHashMismatch, result.FirstInvalidReason);
        Assert.Equal(1, result.FirstInvalidEntryIndex);
    }

    [Fact]
    public void TamperingTheLastEntryIsUndetectableWithoutTheSignedHead_ButDetectedWithIt()
    {
        var (chain, manifestHash, headHash, _) = BuildChain(3);
        var tampered = Encoding.UTF8.GetBytes(
            Encoding.UTF8.GetString(chain).Replace("sum-2", "SUM-2", StringComparison.Ordinal));

        // A parent-chain walk alone cannot catch a last-entry edit.
        Assert.True(new ComputerUseAuditChain().Validate(tampered, manifestHash).IsValid);

        // The pinned terminal head hash catches it.
        var withHead = new ComputerUseAuditChain().Validate(tampered, manifestHash, expectedHeadHashHex: headHash);
        Assert.False(withHead.IsValid);
        Assert.Equal(AuditChainInvalidReason.HeadHashMismatch, withHead.FirstInvalidReason);
    }

    [Fact]
    public void StrictVerificationFailsClosedWhenHeadAnchorMissing()
    {
        var (chain, manifestHash, _, _) = BuildChain(2);
        var result = new ComputerUseAuditChain().Validate(
            chain, manifestHash, expectedHeadHashHex: null, requireExpectedHead: true);

        Assert.False(result.IsValid);
        Assert.Equal(AuditChainInvalidReason.HeadAnchorMissing, result.FirstInvalidReason);
    }

    [Fact]
    public void ReorderedEntriesFailOnIndex()
    {
        var (chain, manifestHash, _, _) = BuildChain(2);
        var lines = Encoding.UTF8.GetString(chain).Split('\n', StringSplitOptions.RemoveEmptyEntries);
        var reversed = Encoding.UTF8.GetBytes(lines[1] + "\n" + lines[0] + "\n");

        var result = new ComputerUseAuditChain().Validate(reversed, manifestHash);

        Assert.False(result.IsValid);
        Assert.Equal(AuditChainInvalidReason.UnexpectedEntryIndex, result.FirstInvalidReason);
    }

    [Fact]
    public void GarbageLineIsADecodeFailure()
    {
        var (chain, manifestHash, _, _) = BuildChain(1);
        var withGarbage = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(chain) + "{not json\n");

        var result = new ComputerUseAuditChain().Validate(withGarbage, manifestHash);

        Assert.False(result.IsValid);
        Assert.Equal(AuditChainInvalidReason.DecodeFailure, result.FirstInvalidReason);
    }

    [Fact]
    public void UnsupportedSchemaIsRejected()
    {
        var manifest = Manifest("sess-schema");
        var manifestHash = new ComputerUseAuditChain().HashSessionManifest(manifest.ToCanonicalMap());
        var futureEntry = new ComputerUseAuditEntry(
            sessionId: "sess-schema",
            entryIndex: 0,
            timestamp: Started,
            actionKind: "browser.click",
            actionSummary: "future",
            actionDescriptorHashHex: "abc",
            approvedBy: AuditApprovedBy.Mac,
            parentEntryHashHex: manifestHash,
            macAppVersion: "1.0.0",
            schemaVersion: 999);
        var line = new byte[futureEntry.CanonicalBytes().Length + 1];
        Array.Copy(futureEntry.CanonicalBytes(), line, futureEntry.CanonicalBytes().Length);
        line[^1] = 0x0A;

        var result = new ComputerUseAuditChain().Validate(line, manifestHash);

        Assert.False(result.IsValid);
        Assert.Equal(AuditChainInvalidReason.UnsupportedSchema, result.FirstInvalidReason);
    }

    [Fact]
    public void SignedHeadVerifiesAndTamperFails()
    {
        var (_, _, headHash, _) = BuildChain(3);
        var signer = Ed25519KeyPair.Generate().Signer();
        var head = ComputerUseAuditSignedHead.Sign("sess-1", lastEntryIndex: 2, headHash, Started.AddMinutes(5), signer);

        Assert.True(head.VerifySignature());

        var tampered = new ComputerUseAuditSignedHead(
            head.SessionId, head.LastEntryIndex, headHashHex: "00" + head.HeadHashHex[2..],
            head.ClosedAt, head.SignatureEd25519Base64, head.SignerPublicKeyEd25519Base64);
        Assert.False(tampered.VerifySignature());
    }

    [Fact]
    public void VerifierReportsFullyVerifiedChainPlusHead()
    {
        var (chain, manifestHash, headHash, _) = BuildChain(3);
        var signer = Ed25519KeyPair.Generate().Signer();
        var head = ComputerUseAuditSignedHead.Sign("sess-1", 2, headHash, Started.AddMinutes(5), signer);

        var report = new ComputerUseAuditVerifier().Verify(chain, manifestHash, head, maxEntryIndexInclusive: 2);

        Assert.True(report.ChainValid);
        Assert.True(report.HeadSignatureValid);
        Assert.True(report.NoEntriesAfterIndex);
        Assert.True(report.IsFullyVerified);
        Assert.Equal(3, report.EntryCount);
    }

    [Fact]
    public void LoggerRejectsAnEntryWithAWrongParentHash()
    {
        var logger = new ComputerUseAuditLogger("sess-x", _dir, "1.0.0");
        logger.BeginSession(Manifest("sess-x"));

        var badParent = new ComputerUseAuditEntry(
            sessionId: "sess-x",
            entryIndex: 0,
            timestamp: Started,
            actionKind: "browser.click",
            actionSummary: "s",
            actionDescriptorHashHex: "abc",
            approvedBy: AuditApprovedBy.Mac,
            parentEntryHashHex: AuditHasher.GenesisParentHashHex, // wrong: head is the manifest hash
            macAppVersion: "1.0.0");

        var ex = Assert.Throws<ComputerUseAuditLogger.AuditLoggerException>(() => logger.Append(badParent));
        Assert.Equal(ComputerUseAuditLogger.AuditLoggerError.ParentHashMismatch, ex.Reason);
    }
}
