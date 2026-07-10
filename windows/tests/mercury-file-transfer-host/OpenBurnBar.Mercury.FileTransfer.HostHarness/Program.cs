using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Mercury.FileTransfer;
using OpenBurnBar.Integrations.Mercury.Windows;

namespace OpenBurnBar.Mercury.FileTransfer.HostHarness;

internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    private static async Task<int> Main(string[] args)
    {
        string output = ParseOutput(args);
        Directory.CreateDirectory(output);
        try
        {
            HostSummary summary = await RunAsync(output).ConfigureAwait(false);
            File.WriteAllText(
                Path.Combine(output, "mercury-file-transfer-host-summary.json"),
                JsonSerializer.Serialize(summary, JsonOptions));
            return summary.Passed ? 0 : 1;
        }
        catch (Exception ex)
        {
            File.WriteAllText(
                Path.Combine(output, "mercury-file-transfer-host-summary.json"),
                JsonSerializer.Serialize(new
                {
                    passed = false,
                    generatedAtUtc = DateTimeOffset.UtcNow,
                    errorType = ex.GetType().FullName,
                    error = ex.Message,
                    stack = ex.StackTrace,
                }, JsonOptions));
            return 1;
        }
    }

    private static async Task<HostSummary> RunAsync(string output)
    {
        var checks = new List<HostCheck>();
        string state = Path.Combine(output, "state");
        string downloads = Path.Combine(output, "downloads");
        string sourcePath = Path.Combine(output, "source.bin");
        byte[] original = DeterministicBytes(1024 * 1024 + 37);
        File.WriteAllBytes(sourcePath, original);
        string expectedHash = Sha256(original);

        var runtime = new WindowsMercuryFileTransferRuntime(state, downloads);
        Add(checks, "defender-available", runtime.IsThreatScannerAvailable, "provider=Microsoft Defender MpCmdRun");

        OutboundFileSnapshot snapshot = runtime.CreateOutboundSnapshot(sourcePath);
        File.WriteAllText(sourcePath, "source changed after snapshot");
        Add(
            checks,
            "immutable-outbound-snapshot",
            snapshot.TotalBytes == original.LongLength
                && snapshot.Sha256Hex == expectedHash
                && File.GetAttributes(snapshot.SnapshotPath).HasFlag(FileAttributes.ReadOnly)
                && Sha256(File.ReadAllBytes(snapshot.SnapshotPath)) == expectedHash,
            $"bytes={snapshot.TotalBytes}; hash={snapshot.Sha256Hex}; readOnly={File.GetAttributes(snapshot.SnapshotPath).HasFlag(FileAttributes.ReadOnly)}");

        const uint transferId = 0x4d455243;
        FileTransferManifest manifest = runtime.CreateManifest(snapshot, transferId, chunkSize: 64 * 1024);
        FileTransferChunk[] chunks = runtime.ReadChunks(snapshot, manifest).ToArray();
        Add(
            checks,
            "streaming-chunk-plan",
            chunks.Length == manifest.TotalChunks
                && chunks.Sum(chunk => (long)chunk.Payload.Length) == manifest.TotalBytes
                && chunks[^1].IsLast,
            $"chunks={chunks.Length}; bytes={chunks.Sum(chunk => (long)chunk.Payload.Length)}");

        QuarantinedInboundFile quarantined = await runtime.QuarantineIncomingAsync(
            manifest,
            chunks.Reverse(),
            "host-certification-peer").ConfigureAwait(false);
        bool motwBeforePromotion = WindowsAttachmentOriginMarker.HasInternetZone(quarantined.QuarantinePath);
        Add(
            checks,
            "motw-and-defender-quarantine",
            quarantined.Disposition == InboundFileDisposition.AwaitingUserApproval
                && quarantined.OriginMark.IsMarked
                && quarantined.ThreatScan?.Status == FileThreatScanStatus.Clean
                && motwBeforePromotion,
            $"disposition={quarantined.Disposition}; origin={quarantined.OriginMark.Status}; scan={quarantined.ThreatScan?.Status}; motw={motwBeforePromotion}");

        QuarantinedInboundFile promoted = runtime.ApproveAndPromote(quarantined);
        bool motwAfterPromotion = promoted.PromotedPath is not null
            && WindowsAttachmentOriginMarker.HasInternetZone(promoted.PromotedPath);
        Add(
            checks,
            "explicit-approval-atomic-promotion",
            promoted.Disposition == InboundFileDisposition.Promoted
                && promoted.PromotedPath is not null
                && File.Exists(promoted.PromotedPath)
                && Sha256(File.ReadAllBytes(promoted.PromotedPath)) == expectedHash
                && motwAfterPromotion,
            $"disposition={promoted.Disposition}; motwPreserved={motwAfterPromotion}; hash={expectedHash}");

        const uint deniedTransferId = transferId + 1;
        FileTransferManifest deniedManifest = FileTransferSnapshotChunker.CreateManifest(snapshot, deniedTransferId, 64 * 1024);
        FileTransferChunk[] deniedChunks = FileTransferSnapshotChunker.ReadChunks(snapshot, deniedManifest).ToArray();
        var denyService = new InboundFileQuarantineService(
            new WindowsAttachmentOriginMarker(),
            new FixedThreatScanner(FileThreatScanStatus.ThreatDetected));
        QuarantinedInboundFile denied = await denyService.QuarantineAsync(
            deniedManifest,
            deniedChunks,
            downloads,
            "host-certification-peer").ConfigureAwait(false);
        bool promotionDenied;
        try
        {
            denyService.ApproveAndPromote(denied);
            promotionDenied = false;
        }
        catch (InboundQuarantineException ex) when (ex.Error == InboundQuarantineError.NotApproved)
        {
            promotionDenied = true;
        }

        Add(
            checks,
            "threat-result-fails-closed",
            denied.Disposition == InboundFileDisposition.ThreatDetected
                && promotionDenied
                && File.Exists(denied.QuarantinePath),
            $"disposition={denied.Disposition}; promotionDenied={promotionDenied}");
        denyService.Discard(denied);

        bool snapshotReleased = runtime.ReleaseOutboundSnapshot(snapshot);
        Add(
            checks,
            "outbound-snapshot-release",
            snapshotReleased && !File.Exists(snapshot.SnapshotPath),
            $"released={snapshotReleased}; exists={File.Exists(snapshot.SnapshotPath)}");

        return new HostSummary(
            Passed: checks.All(check => check.Passed),
            GeneratedAtUtc: DateTimeOffset.UtcNow,
            MachineName: Environment.MachineName,
            OsVersion: Environment.OSVersion.VersionString,
            OsArchitecture: RuntimeInformation.OSArchitecture.ToString(),
            ProcessArchitecture: RuntimeInformation.ProcessArchitecture.ToString(),
            Framework: RuntimeInformation.FrameworkDescription,
            SnapshotSha256: snapshot.Sha256Hex,
            PromotedFileSha256: expectedHash,
            Checks: checks);
    }

    private static byte[] DeterministicBytes(int length)
    {
        var bytes = new byte[length];
        for (int index = 0; index < length; index++)
        {
            bytes[index] = (byte)((index * 31 + 17) % 251);
        }

        return bytes;
    }

    private static string Sha256(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static string ParseOutput(string[] args)
    {
        for (int index = 0; index < args.Length - 1; index++)
        {
            if (string.Equals(args[index], "--output", StringComparison.Ordinal))
            {
                return Path.GetFullPath(args[index + 1]);
            }
        }

        throw new ArgumentException("Usage: --output <directory>");
    }

    private static void Add(List<HostCheck> checks, string name, bool passed, string detail) =>
        checks.Add(new HostCheck(name, passed, detail));

    private sealed class FixedThreatScanner(FileThreatScanStatus status) : IInboundFileThreatScanner
    {
        public bool IsAvailable => true;

        public ValueTask<FileThreatScanResult> ScanAsync(string filePath, CancellationToken cancellationToken = default) =>
            ValueTask.FromResult(new FileThreatScanResult(status, "host-fixed-scanner", status.ToString()));
    }

    private sealed record HostCheck(string Name, bool Passed, string Detail);

    private sealed record HostSummary(
        bool Passed,
        DateTimeOffset GeneratedAtUtc,
        string MachineName,
        string OsVersion,
        string OsArchitecture,
        string ProcessArchitecture,
        string Framework,
        string SnapshotSha256,
        string PromotedFileSha256,
        IReadOnlyList<HostCheck> Checks);
}
