using System;
using System.Security.Cryptography;
using OpenBurnBar.Integrations.Mercury.FileTransfer;
using OpenBurnBar.Integrations.Mercury.Wire;
using Xunit;

namespace OpenBurnBar.Integrations.Mercury.Tests;

public sealed class FileTransferTests
{
    private static byte[] Bytes(int length)
    {
        var data = new byte[length];
        for (var i = 0; i < length; i++)
        {
            data[i] = (byte)(i * 31 + 7);
        }

        return data;
    }

    [Fact]
    public void Chunk_ProducesCeilChunkCount_AndBindsHash()
    {
        var data = Bytes(1000);
        var plan = FileTransferChunker.Chunk(data, transferId: 1, chunkSize: 256);

        Assert.Equal(4, plan.Manifest.TotalChunks); // ceil(1000/256)
        Assert.Equal(1000, plan.Manifest.TotalBytes);
        Assert.Equal(Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant(), plan.Manifest.Sha256Hex);
        Assert.True(plan.Chunks[^1].IsLast);
        Assert.False(plan.Chunks[0].IsLast);
        Assert.Equal(232, plan.Chunks[^1].Payload.Length); // 1000 - 3*256
    }

    [Fact]
    public void Reassemble_InOrder_RestoresBytes()
    {
        var data = Bytes(1000);
        var plan = FileTransferChunker.Chunk(data, transferId: 7, chunkSize: 256);
        var reassembler = new FileTransferReassembler(plan.Manifest);

        foreach (var chunk in plan.Chunks)
        {
            Assert.Equal(FileTransferAcceptResult.Accepted, reassembler.Accept(chunk));
        }

        Assert.True(reassembler.IsComplete);
        Assert.Equal(data, reassembler.Reassemble());
    }

    [Fact]
    public void Reassemble_OutOfOrder_RestoresBytes()
    {
        var data = Bytes(2049);
        var plan = FileTransferChunker.Chunk(data, transferId: 9, chunkSize: 512);
        var reassembler = new FileTransferReassembler(plan.Manifest);

        // Feed chunks last-to-first.
        for (var i = plan.Chunks.Count - 1; i >= 0; i--)
        {
            reassembler.Accept(plan.Chunks[i]);
        }

        Assert.Equal(data, reassembler.Reassemble());
    }

    [Fact]
    public void Reassemble_Incomplete_Throws()
    {
        var plan = FileTransferChunker.Chunk(Bytes(1000), transferId: 1, chunkSize: 256);
        var reassembler = new FileTransferReassembler(plan.Manifest);
        reassembler.Accept(plan.Chunks[0]);

        var ex = Assert.Throws<FileTransferReassemblyException>(() => reassembler.Reassemble());
        Assert.Equal(FileTransferReassemblyError.Incomplete, ex.Error);
    }

    [Fact]
    public void Accept_Duplicate_IsIgnored()
    {
        var plan = FileTransferChunker.Chunk(Bytes(500), transferId: 1, chunkSize: 256);
        var reassembler = new FileTransferReassembler(plan.Manifest);

        Assert.Equal(FileTransferAcceptResult.Accepted, reassembler.Accept(plan.Chunks[0]));
        Assert.Equal(FileTransferAcceptResult.DuplicateIgnored, reassembler.Accept(plan.Chunks[0]));
        Assert.Equal(1, reassembler.ReceivedCount);
    }

    [Fact]
    public void Accept_WrongTransfer_IsRejected()
    {
        var plan = FileTransferChunker.Chunk(Bytes(500), transferId: 1, chunkSize: 256);
        var reassembler = new FileTransferReassembler(plan.Manifest);
        var foreign = new FileTransferChunk(transferId: 2, index: 0, totalChunks: 2, offset: 0, isLast: false, payload: new byte[1]);
        Assert.Equal(FileTransferAcceptResult.RejectedWrongTransfer, reassembler.Accept(foreign));
    }

    [Fact]
    public void Accept_OutOfRangeIndex_IsRejected()
    {
        var plan = FileTransferChunker.Chunk(Bytes(500), transferId: 1, chunkSize: 256);
        var reassembler = new FileTransferReassembler(plan.Manifest);
        var oob = new FileTransferChunk(transferId: 1, index: 99, totalChunks: 2, offset: 0, isLast: false, payload: new byte[1]);
        Assert.Equal(FileTransferAcceptResult.RejectedOutOfRange, reassembler.Accept(oob));
    }

    [Fact]
    public void Reassemble_HashMismatch_ThrowsTamperError()
    {
        var plan = FileTransferChunker.Chunk(Bytes(600), transferId: 3, chunkSize: 256);
        var reassembler = new FileTransferReassembler(plan.Manifest);

        // Tamper with a middle chunk's payload but keep its length so the total
        // length still matches — only the content hash catches the corruption.
        var tampered = new FileTransferChunk(
            plan.Chunks[1].TransferId,
            plan.Chunks[1].Index,
            plan.Chunks[1].TotalChunks,
            plan.Chunks[1].Offset,
            plan.Chunks[1].IsLast,
            new byte[plan.Chunks[1].Payload.Length]);

        reassembler.Accept(plan.Chunks[0]);
        reassembler.Accept(tampered);
        reassembler.Accept(plan.Chunks[2]);

        var ex = Assert.Throws<FileTransferReassemblyException>(() => reassembler.Reassemble());
        Assert.Equal(FileTransferReassemblyError.HashMismatch, ex.Error);
    }

    [Fact]
    public void EmptyFile_ZeroChunks_CompletesToEmpty()
    {
        var plan = FileTransferChunker.Chunk(Array.Empty<byte>(), transferId: 1);
        Assert.Equal(0, plan.Manifest.TotalChunks);

        var reassembler = new FileTransferReassembler(plan.Manifest);
        Assert.True(reassembler.IsComplete);
        Assert.Empty(reassembler.Reassemble());
    }

    [Fact]
    public void WireFrame_RoundTripsThroughMediaPacketCodec()
    {
        var plan = FileTransferChunker.Chunk(Bytes(300), transferId: 55, chunkSize: 256);
        var codec = new MediaPacketCodec();

        // Frame each chunk, decode it back, and reassemble from the wire.
        var reassembler = new FileTransferReassembler(plan.Manifest);
        foreach (var chunk in plan.Chunks)
        {
            var envelope = FileTransferChunker.ToFrameEnvelope(chunk, codec);
            var restored = FileTransferChunker.FromFrameEnvelope(envelope, plan.Manifest.TotalChunks, codec);
            Assert.Equal(chunk.Index, restored.Index);
            Assert.Equal(chunk.IsLast, restored.IsLast);
            reassembler.Accept(restored);
        }

        Assert.Equal(Bytes(300), reassembler.Reassemble());
    }
}
