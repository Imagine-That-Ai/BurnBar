using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Mercury.FileTransfer;
using Xunit;

namespace OpenBurnBar.Integrations.Mercury.Tests;

public sealed class FileTransferSecurityTests
{
    [Fact]
    public void OutboundSnapshot_IsContentAddressedAndUnaffectedBySourceMutation()
    {
        using var sandbox = new Sandbox();
        string source = sandbox.PathFor("draft.txt");
        string snapshots = sandbox.PathFor("snapshots");
        byte[] original = "immutable outbound"u8.ToArray();
        File.WriteAllBytes(source, original);

        OutboundFileSnapshot snapshot = new OutboundFileSnapshotService()
            .Create(source, snapshots);
        File.WriteAllText(source, "mutated source");

        Assert.Equal(original, File.ReadAllBytes(snapshot.SnapshotPath));
        Assert.Equal(Sha256(original), snapshot.Sha256Hex);
        Assert.StartsWith(snapshot.Sha256Hex + "-draft.txt", Path.GetFileName(snapshot.SnapshotPath), StringComparison.Ordinal);
        Assert.True(File.GetAttributes(snapshot.SnapshotPath).HasFlag(FileAttributes.ReadOnly));
        Assert.Empty(Directory.EnumerateFiles(snapshots, ".snapshot-*.tmp"));
    }

    [Fact]
    public void SnapshotChunker_StreamsOriginalBytesAndManifest()
    {
        using var sandbox = new Sandbox();
        byte[] original = Enumerable.Range(0, 911).Select(index => (byte)(index % 251)).ToArray();
        OutboundFileSnapshot snapshot = new OutboundFileSnapshotService()
            .Create(original, "payload.bin", sandbox.PathFor("snapshots"));

        FileTransferManifest manifest = FileTransferSnapshotChunker.CreateManifest(snapshot, transferId: 42, chunkSize: 128);
        FileTransferChunk[] chunks = FileTransferSnapshotChunker.ReadChunks(snapshot, transferId: 42, chunkSize: 128).ToArray();

        Assert.Equal(original.Length, manifest.TotalBytes);
        Assert.Equal(snapshot.Sha256Hex, manifest.Sha256Hex);
        Assert.Equal(8, chunks.Length);
        Assert.Equal(original, chunks.SelectMany(chunk => chunk.Payload).ToArray());
    }

    [Fact]
    public void OutboundSnapshot_ReleaseDeletesOnlyManagedContentAddressedFiles()
    {
        using var sandbox = new Sandbox();
        string root = sandbox.PathFor("snapshots");
        var service = new OutboundFileSnapshotService();
        OutboundFileSnapshot snapshot = service.Create("release"u8, "payload.txt", root);

        Assert.True(service.Release(snapshot, root));
        Assert.False(File.Exists(snapshot.SnapshotPath));
        Assert.False(service.Release(snapshot, root));

        string outside = sandbox.PathFor(snapshot.Sha256Hex + "-outside.txt");
        File.WriteAllText(outside, "outside");
        OutboundFileSnapshot forged = snapshot with { SnapshotPath = outside };
        OutboundSnapshotException error = Assert.Throws<OutboundSnapshotException>(() => service.Release(forged, root));
        Assert.Equal(OutboundSnapshotError.SnapshotOutsideDirectory, error.Error);
        Assert.True(File.Exists(outside));
    }

    [Fact]
    public void OutboundSnapshot_ReleaseRejectsChangedManagedSnapshot()
    {
        using var sandbox = new Sandbox();
        string root = sandbox.PathFor("snapshots");
        var service = new OutboundFileSnapshotService();
        OutboundFileSnapshot snapshot = service.Create("stable"u8, "payload.txt", root);

        File.SetAttributes(snapshot.SnapshotPath, FileAttributes.Normal);
        File.WriteAllText(snapshot.SnapshotPath, "changed");

        OutboundSnapshotException error = Assert.Throws<OutboundSnapshotException>(() => service.Release(snapshot, root));
        Assert.Equal(OutboundSnapshotError.SourceChanged, error.Error);
        Assert.True(File.Exists(snapshot.SnapshotPath));
    }

    [Fact]
    public void OutboundManifest_RejectsReceiverIncompatibleChunkSize()
    {
        using var sandbox = new Sandbox();
        string root = sandbox.PathFor("snapshots");
        var service = new OutboundFileSnapshotService();
        OutboundFileSnapshot snapshot = service.Create("payload"u8, "payload.txt", root);

        Assert.Throws<ArgumentOutOfRangeException>(() => FileTransferSnapshotChunker.CreateManifest(
            snapshot,
            transferId: 1,
            chunkSize: InboundFileQuarantineService.MaxChunkBytes + 1));
    }

    [Fact]
    public async Task CleanInbound_RequiresApprovalThenPromotesWithoutOverwrite()
    {
        using var sandbox = new Sandbox();
        byte[] original = "verified inbound"u8.ToArray();
        FileTransferPlan plan = FileTransferChunker.Chunk(original, transferId: 7, chunkSize: 4, fileName: "report.txt");
        var marker = new FakeMarker(FileOriginMarkStatus.Marked);
        var scanner = new FakeScanner(FileThreatScanStatus.Clean);
        var service = new InboundFileQuarantineService(marker, scanner);
        string downloads = sandbox.PathFor("downloads");
        Directory.CreateDirectory(downloads);
        File.WriteAllText(Path.Combine(downloads, "report.txt"), "existing");

        QuarantinedInboundFile quarantined = await service.QuarantineAsync(
            plan.Manifest,
            plan.Chunks.Reverse(),
            downloads,
            "peer-node-1");

        Assert.Equal(InboundFileDisposition.AwaitingUserApproval, quarantined.Disposition);
        Assert.True(File.Exists(quarantined.QuarantinePath));
        Assert.True(marker.Called);
        Assert.True(scanner.Called);
        Assert.Equal(64, quarantined.SourcePeerHash.Length);

        QuarantinedInboundFile promoted = service.ApproveAndPromote(quarantined);
        Assert.Equal(InboundFileDisposition.Promoted, promoted.Disposition);
        Assert.EndsWith("report (1).txt", promoted.PromotedPath, StringComparison.Ordinal);
        Assert.Equal(original, File.ReadAllBytes(promoted.PromotedPath!));
        Assert.Equal("existing", File.ReadAllText(Path.Combine(downloads, "report.txt")));
    }

    [Fact]
    public async Task ThreatDetected_RemainsQuarantinedAndCannotPromote()
    {
        using var sandbox = new Sandbox();
        FileTransferPlan plan = FileTransferChunker.Chunk("unsafe"u8.ToArray(), 9, fileName: "payload.exe");
        var service = new InboundFileQuarantineService(
            new FakeMarker(FileOriginMarkStatus.Marked),
            new FakeScanner(FileThreatScanStatus.ThreatDetected));

        QuarantinedInboundFile file = await service.QuarantineAsync(
            plan.Manifest,
            plan.Chunks,
            sandbox.PathFor("downloads"),
            "peer");

        Assert.Equal(InboundFileDisposition.ThreatDetected, file.Disposition);
        InboundQuarantineException error = Assert.Throws<InboundQuarantineException>(() => service.ApproveAndPromote(file));
        Assert.Equal(InboundQuarantineError.NotApproved, error.Error);
        Assert.True(File.Exists(file.QuarantinePath));
    }

    [Fact]
    public async Task MissingScanner_FailsClosedWithoutCallingScanner()
    {
        using var sandbox = new Sandbox();
        FileTransferPlan plan = FileTransferChunker.Chunk("data"u8.ToArray(), 3, fileName: "data.bin");
        var scanner = new FakeScanner(FileThreatScanStatus.Clean, isAvailable: false);
        var service = new InboundFileQuarantineService(new FakeMarker(FileOriginMarkStatus.Marked), scanner);

        QuarantinedInboundFile file = await service.QuarantineAsync(
            plan.Manifest,
            plan.Chunks,
            sandbox.PathFor("downloads"),
            "peer");

        Assert.Equal(InboundFileDisposition.ScannerUnavailable, file.Disposition);
        Assert.False(scanner.Called);
    }

    [Fact]
    public async Task MissingOriginMark_FailsClosedWithoutScanning()
    {
        using var sandbox = new Sandbox();
        FileTransferPlan plan = FileTransferChunker.Chunk("data"u8.ToArray(), 4, fileName: "data.bin");
        var scanner = new FakeScanner(FileThreatScanStatus.Clean);
        var service = new InboundFileQuarantineService(new FakeMarker(FileOriginMarkStatus.Failed), scanner);

        QuarantinedInboundFile file = await service.QuarantineAsync(
            plan.Manifest,
            plan.Chunks,
            sandbox.PathFor("downloads"),
            "peer");

        Assert.Equal(InboundFileDisposition.OriginMarkFailed, file.Disposition);
        Assert.False(scanner.Called);
    }

    [Fact]
    public async Task TamperedInbound_IsDeletedBeforeSecurityProvidersRun()
    {
        using var sandbox = new Sandbox();
        FileTransferPlan plan = FileTransferChunker.Chunk("integrity"u8.ToArray(), 5, chunkSize: 4, fileName: "data.bin");
        FileTransferChunk[] chunks = plan.Chunks.ToArray();
        chunks[0] = new FileTransferChunk(5, 0, chunks.Length, 0, false, new byte[] { 0, 0, 0, 0 });
        var marker = new FakeMarker(FileOriginMarkStatus.Marked);
        var scanner = new FakeScanner(FileThreatScanStatus.Clean);
        var service = new InboundFileQuarantineService(marker, scanner);

        InboundQuarantineException error = await Assert.ThrowsAsync<InboundQuarantineException>(() =>
            service.QuarantineAsync(plan.Manifest, chunks, sandbox.PathFor("downloads"), "peer"));

        Assert.Equal(InboundQuarantineError.HashMismatch, error.Error);
        Assert.False(marker.Called);
        Assert.False(scanner.Called);
    }

    [Fact]
    public async Task DuplicateChunk_IsRejected()
    {
        using var sandbox = new Sandbox();
        FileTransferPlan plan = FileTransferChunker.Chunk("duplicate"u8.ToArray(), 6, chunkSize: 4, fileName: "data.bin");
        var chunks = new List<FileTransferChunk> { plan.Chunks[0], plan.Chunks[0] };
        chunks.AddRange(plan.Chunks.Skip(1));
        var service = new InboundFileQuarantineService(
            new FakeMarker(FileOriginMarkStatus.Marked),
            new FakeScanner(FileThreatScanStatus.Clean));

        InboundQuarantineException error = await Assert.ThrowsAsync<InboundQuarantineException>(() =>
            service.QuarantineAsync(plan.Manifest, chunks, sandbox.PathFor("downloads"), "peer"));

        Assert.Equal(InboundQuarantineError.DuplicateChunk, error.Error);
    }

    [Fact]
    public async Task ExcessiveChunkCount_IsRejectedBeforeReceiverAllocation()
    {
        using var sandbox = new Sandbox();
        int chunks = InboundFileQuarantineService.DefaultMaxChunks + 1;
        var manifest = new FileTransferManifest(
            transferId: 11,
            totalBytes: chunks,
            chunkSize: 1,
            totalChunks: chunks,
            sha256Hex: new string('0', 64),
            fileName: "amplification.bin");
        var service = new InboundFileQuarantineService(
            new FakeMarker(FileOriginMarkStatus.Marked),
            new FakeScanner(FileThreatScanStatus.Clean));

        InboundQuarantineException error = await Assert.ThrowsAsync<InboundQuarantineException>(() =>
            service.QuarantineAsync(manifest, Array.Empty<FileTransferChunk>(), sandbox.PathFor("downloads"), "peer"));

        Assert.Equal(InboundQuarantineError.InvalidManifest, error.Error);
    }

    [Fact]
    public async Task UnsafeInboundName_IsReducedToFileName()
    {
        using var sandbox = new Sandbox();
        FileTransferPlan plan = FileTransferChunker.Chunk("safe"u8.ToArray(), 8, fileName: "../../CON.txt");
        var service = new InboundFileQuarantineService(
            new FakeMarker(FileOriginMarkStatus.Marked),
            new FakeScanner(FileThreatScanStatus.Clean));

        QuarantinedInboundFile file = await service.QuarantineAsync(
            plan.Manifest,
            plan.Chunks,
            sandbox.PathFor("downloads"),
            "peer");

        Assert.Equal("_CON.txt", file.DisplayName);
        Assert.StartsWith(Path.GetFullPath(sandbox.PathFor("downloads")), Path.GetFullPath(file.QuarantinePath), StringComparison.Ordinal);
    }

    private static string Sha256(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private sealed class FakeMarker(FileOriginMarkStatus status) : IInboundFileOriginMarker
    {
        public bool Called { get; private set; }

        public ValueTask<FileOriginMarkResult> MarkInternetOriginAsync(
            string filePath,
            string sourcePeerHash,
            CancellationToken cancellationToken = default)
        {
            Called = true;
            return ValueTask.FromResult(new FileOriginMarkResult(status, "fake-marker", status.ToString()));
        }
    }

    private sealed class FakeScanner(FileThreatScanStatus status, bool isAvailable = true) : IInboundFileThreatScanner
    {
        public bool IsAvailable { get; } = isAvailable;

        public bool Called { get; private set; }

        public ValueTask<FileThreatScanResult> ScanAsync(string filePath, CancellationToken cancellationToken = default)
        {
            Called = true;
            return ValueTask.FromResult(new FileThreatScanResult(status, "fake-scanner", status.ToString()));
        }
    }

    private sealed class Sandbox : IDisposable
    {
        private readonly string _root = Path.Combine(Path.GetTempPath(), "openburnbar-mercury-tests-" + Guid.NewGuid().ToString("N"));

        public Sandbox() => Directory.CreateDirectory(_root);

        public string PathFor(string relative) => Path.Combine(_root, relative);

        public void Dispose()
        {
            if (!Directory.Exists(_root))
            {
                return;
            }

            foreach (string file in Directory.EnumerateFiles(_root, "*", SearchOption.AllDirectories))
            {
                File.SetAttributes(file, FileAttributes.Normal);
            }

            Directory.Delete(_root, recursive: true);
        }
    }
}
