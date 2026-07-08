using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using uniffi.burnbar_remote;
using Xunit;

namespace BurnBarRemote.Ffi.Tests;

/// <summary>
/// Proves the Windows C# binding path (uniffi-bindgen-cs) round-trips a
/// byte-identical wire vector against the natively-built <c>burnbar-remote-ffi</c>
/// cdylib on macOS — exercising async (<c>EncodeQualityDecision</c>), a foreign
/// callback (<c>WireProgressListener</c>), and typed errors
/// (<c>BurnBarRemoteFfiException.*</c>). FFI-008 runs the identical assertions on
/// the <c>*-pc-windows-msvc</c> runtime.
/// </summary>
public sealed class WireRoundTripTests
{
    /// <summary>The exact decision the committed golden vector encodes. Kept in
    /// lock-step with the Rust <c>golden_decision()</c> in
    /// <c>burnbar-remote-ffi/src/lib.rs</c>.</summary>
    private static RemoteQualityDecision GoldenDecision() => new(
        @targetBitrateBps: 8_000_000u,
        @targetDimensions: new RemoteDimensions(@width: 2560u, @height: 1440u),
        @targetFps: 60,
        @qpMin: 24,
        @qpMax: 40,
        @fecOverheadPpm: 50_000u,
        @requestKeyframe: true,
        @allowFrameDrop: true,
        @cursorOnlyUntilNextDamage: false);

    /// <summary>The committed golden bytes — the same file the Rust test embeds
    /// via <c>include_bytes!</c>. Copied next to the test binary by the csproj.</summary>
    private static byte[] GoldenBytes() =>
        File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "quality_decision_v1.wire"));

    private sealed class RecordingListener : WireProgressListener
    {
        public readonly List<string> Stages = new();

        public void OnStage(string @stage) => Stages.Add(@stage);
    }

    [Fact]
    public async Task Encode_ProducesGoldenBytes_AndFiresCallbacksInOrder()
    {
        var listener = new RecordingListener();

        byte[] encoded = await BurnbarRemoteMethods.EncodeQualityDecision(GoldenDecision(), listener);

        Assert.Equal(GoldenBytes(), encoded);
        Assert.Equal(new[] { "validate", "encode", "done" }, listener.Stages);
    }

    [Fact]
    public void Decode_OfGolden_ReturnsTheOriginalDecision()
    {
        RemoteQualityDecision decoded = BurnbarRemoteMethods.DecodeQualityDecision(GoldenBytes());

        Assert.Equal(GoldenDecision(), decoded);
    }

    [Fact]
    public async Task EncodeThenDecode_IsIdentity()
    {
        var decision = GoldenDecision();

        byte[] encoded = await BurnbarRemoteMethods.EncodeQualityDecision(decision, new RecordingListener());
        RemoteQualityDecision decoded = BurnbarRemoteMethods.DecodeQualityDecision(encoded);

        Assert.Equal(decision, decoded);
    }

    [Fact]
    public void Decode_TruncatedBuffer_ThrowsWireTruncated()
    {
        var error = Assert.Throws<BurnBarRemoteFfiException.WireTruncated>(
            () => BurnbarRemoteMethods.DecodeQualityDecision(new byte[] { 1, 1, 1, 1 }));

        Assert.Equal(22u, error.expected);
        Assert.Equal(4u, error.found);
    }

    [Fact]
    public void Decode_UnknownVersion_ThrowsWireVersionMismatch()
    {
        byte[] bytes = GoldenBytes();
        bytes[0] = 99;

        var error = Assert.Throws<BurnBarRemoteFfiException.WireVersionMismatch>(
            () => BurnbarRemoteMethods.DecodeQualityDecision(bytes));

        Assert.Equal((byte)1, error.expected);
        Assert.Equal((byte)99, error.found);
    }
}
