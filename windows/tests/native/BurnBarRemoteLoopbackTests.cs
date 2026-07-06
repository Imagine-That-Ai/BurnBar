using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using OpenBurnBar.Native.BurnBarRemote;
using uniffi.burnbar_remote;
using Xunit;

namespace OpenBurnBar.Native.Tests;

/// <summary>
/// Real FFI round-trips through the windows/native shim against the natively
/// built <c>burnbar_remote</c> cdylib — byte-parity with the SAME committed
/// golden wire vector the Rust unit tests and the crate-side C# round-trip
/// lock. Skips when the cdylib is absent (<see cref="NativeFactAttribute"/>).
/// </summary>
public sealed class BurnBarRemoteLoopbackTests
{
    private const string Lib = BurnBarRemoteNative.LibraryLogicalName;

    /// <summary>Kept in lock-step with the Rust <c>golden_decision()</c> in
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

    private static byte[] GoldenBytes() =>
        File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "quality_decision_v1.wire"));

    private sealed class RecordingListener : WireProgressListener
    {
        public readonly List<string> Stages = new();

        public void OnStage(string @stage) => Stages.Add(@stage);
    }

    [NativeFact(Lib)]
    public void Readiness_ReportsTheGen2Protocol()
    {
        RemoteReadiness readiness = BurnBarRemoteNative.Readiness();

        Assert.Equal("burnbar-remote/v1", readiness.protocolVersion);
        Assert.True(readiness.supportsIrohTransport);
        Assert.True(readiness.supportsAdaptiveQuality);
        Assert.True(readiness.supportsPermissionGate);
    }

    [NativeFact(Lib)]
    public async Task EncodeQualityDecision_MatchesTheCommittedGolden_AndFiresCallbacksInOrder()
    {
        var listener = new RecordingListener();

        byte[] encoded = await BurnBarRemoteNative.EncodeQualityDecisionAsync(GoldenDecision(), listener);

        Assert.Equal(GoldenBytes(), encoded);
        Assert.Equal(new[] { "validate", "encode", "done" }, listener.Stages);
    }

    [NativeFact(Lib)]
    public void DecodeQualityDecision_OfTheGolden_ReturnsTheOriginal()
    {
        Assert.Equal(GoldenDecision(), BurnBarRemoteNative.DecodeQualityDecision(GoldenBytes()));
    }

    [NativeFact(Lib)]
    public void DecodeQualityDecision_Truncated_ThrowsTheTypedError()
    {
        var error = Assert.Throws<BurnBarRemoteFfiException.WireTruncated>(
            () => BurnBarRemoteNative.DecodeQualityDecision(new byte[] { 1, 1, 1, 1 }));

        Assert.Equal(22u, error.expected);
        Assert.Equal(4u, error.found);
    }

    [NativeFact(Lib)]
    public void ModeRequiresPermission_MatchesTheEnginePolicyTable()
    {
        Assert.True(BurnBarRemoteNative.ModeRequiresPermission(RemoteSessionMode.Control, RemotePermission.InjectInput));
        Assert.False(BurnBarRemoteNative.ModeRequiresPermission(RemoteSessionMode.ViewOnly, RemotePermission.InjectInput));
    }

    [NativeFact(Lib)]
    public void QualityController_UpdatesThroughTheStatefulObjectPath()
    {
        using BurnBarRemoteQualityController controller = BurnBarRemoteNative.CreateQualityController(
            new RemoteDimensions(@width: 2560u, @height: 1440u),
            RemoteQualityPreference.Balanced);

        RemoteQualityDecision decision = controller.Update(new RemoteControllerInput(
            @network: new RemoteNetworkTelemetry(
                @pathKind: RemotePathKind.Direct,
                @rttMicros: 12_000ul,
                @jitterMicros: 1_500ul,
                @packetLossPpm: 0u,
                @sendQueueBytes: 0u,
                @datagramSendBufferSpace: 1_000_000u,
                @droppedMediaDatagrams: 0ul,
                @relay: false),
            @decodeTimeMicros: 4_000ul,
            @renderTimeMicros: 2_000ul,
            @receivedFrameAgeMicros: 16_000ul,
            @activeControl: true,
            @preference: RemoteQualityPreference.Balanced,
            @currentDimensions: new RemoteDimensions(@width: 2560u, @height: 1440u)));

        Assert.True(decision.targetBitrateBps > 0u);
        Assert.True(decision.targetDimensions.width > 0u);
        Assert.True(decision.targetFps > 0);
    }
}
