using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Mercury.FileTransfer;

namespace OpenBurnBar.Integrations.Mercury.Windows;

/// <summary>Production owner for safe Mercury outbound snapshots and inbound quarantine.</summary>
public sealed class WindowsMercuryFileTransferRuntime
{
    private readonly OutboundFileSnapshotService _outbound;
    private readonly InboundFileQuarantineService _inbound;
    private readonly WindowsDefenderThreatScanner _scanner;

    public WindowsMercuryFileTransferRuntime(string stateDirectory, string downloadDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(stateDirectory);
        ArgumentException.ThrowIfNullOrWhiteSpace(downloadDirectory);
        StateDirectory = Path.GetFullPath(stateDirectory);
        DownloadDirectory = Path.GetFullPath(downloadDirectory);
        SnapshotDirectory = Path.Combine(StateDirectory, "mercury", "outbound-snapshots");
        Directory.CreateDirectory(SnapshotDirectory);
        Directory.CreateDirectory(DownloadDirectory);

        _outbound = new OutboundFileSnapshotService();
        _scanner = new WindowsDefenderThreatScanner();
        _inbound = new InboundFileQuarantineService(new WindowsAttachmentOriginMarker(), _scanner);
    }

    public string StateDirectory { get; }

    public string SnapshotDirectory { get; }

    public string DownloadDirectory { get; }

    public bool IsThreatScannerAvailable => _scanner.IsAvailable;

    public int QuarantinedFileCount
    {
        get
        {
            string directory = Path.Combine(DownloadDirectory, ".openburnbar-quarantine");
            try
            {
                return Directory.Exists(directory)
                    ? Directory.GetFiles(directory, "*.quarantine", SearchOption.TopDirectoryOnly).Length
                    : 0;
            }
            catch (IOException)
            {
                return 0;
            }
            catch (UnauthorizedAccessException)
            {
                return 0;
            }
        }
    }

    public OutboundFileSnapshot CreateOutboundSnapshot(string sourcePath) =>
        _outbound.Create(sourcePath, SnapshotDirectory);

    public FileTransferManifest CreateManifest(
        OutboundFileSnapshot snapshot,
        uint transferId,
        int chunkSize = FileTransferChunker.DefaultChunkSize) =>
        FileTransferSnapshotChunker.CreateManifest(snapshot, transferId, chunkSize);

    public IEnumerable<FileTransferChunk> ReadChunks(
        OutboundFileSnapshot snapshot,
        uint transferId,
        int chunkSize = FileTransferChunker.DefaultChunkSize) =>
        FileTransferSnapshotChunker.ReadChunks(snapshot, transferId, chunkSize);

    public IEnumerable<FileTransferChunk> ReadChunks(
        OutboundFileSnapshot snapshot,
        FileTransferManifest manifest) =>
        FileTransferSnapshotChunker.ReadChunks(snapshot, manifest);

    public bool ReleaseOutboundSnapshot(OutboundFileSnapshot snapshot) =>
        _outbound.Release(snapshot, SnapshotDirectory);

    public Task<QuarantinedInboundFile> QuarantineIncomingAsync(
        FileTransferManifest manifest,
        IEnumerable<FileTransferChunk> chunks,
        string sourcePeerId,
        CancellationToken cancellationToken = default) =>
        _inbound.QuarantineAsync(manifest, chunks, DownloadDirectory, sourcePeerId, cancellationToken);

    public QuarantinedInboundFile ApproveAndPromote(QuarantinedInboundFile file) =>
        _inbound.ApproveAndPromote(file);

    public QuarantinedInboundFile Discard(QuarantinedInboundFile file) => _inbound.Discard(file);
}
