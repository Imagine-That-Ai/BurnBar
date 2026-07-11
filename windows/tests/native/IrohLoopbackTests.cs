using System;
using System.Text;
using OpenBurnBar.Native.Iroh;
using uniffi.openburnbar_iroh;
using Xunit;

namespace OpenBurnBar.Native.Tests;

/// <summary>
/// Real FFI round-trips through the windows/native shim against the natively
/// built <c>openburnbar_iroh</c> cdylib — protocol constants, key generation,
/// the endpoint-handle object lifecycle, and the typed error paths. Skips when
/// the cdylib is absent (<see cref="NativeFactAttribute"/>). No test here
/// touches the network beyond binding local UDP sockets.
/// </summary>
public sealed class IrohLoopbackTests
{
    private const string Lib = IrohNative.LibraryLogicalName;

    [NativeFact(Lib)]
    public void ProtocolVersion_IsTheV1TheMacPeerSpeaks()
    {
        Assert.Equal(1u, IrohNative.ProtocolVersion());
    }

    [NativeFact(Lib)]
    public void OpenBurnBarAlpn_MatchesThePinnedConstant()
    {
        // b"openburnbar/1" in crates/openburnbar-iroh/src/lib.rs — the same
        // bytes IrohRelayWireFormat pins on the Swift side.
        Assert.Equal("openburnbar/1", Encoding.UTF8.GetString(IrohNative.OpenBurnBarAlpn()));
    }

    [NativeFact(Lib)]
    public void AuxiliaryAlpns_AreNonEmpty_AndDistinct()
    {
        byte[] blobs = IrohNative.BlobsAlpn();
        byte[] mercury = IrohNative.MercuryAudioAlpn();

        Assert.NotEmpty(blobs);
        Assert.NotEmpty(mercury);
        Assert.NotEqual(Encoding.UTF8.GetString(blobs), Encoding.UTF8.GetString(mercury));
        Assert.False(string.IsNullOrWhiteSpace(IrohNative.BlobsCrateVersion()));
    }

    [NativeFact(Lib)]
    public void GenerateSecretKeyMaterial_Returns32FreshBytes()
    {
        IrohSecretKeyMaterial first = IrohNative.GenerateSecretKeyMaterial();
        IrohSecretKeyMaterial second = IrohNative.GenerateSecretKeyMaterial();

        Assert.Equal(32, first.raw.Length);
        Assert.Equal(32, second.raw.Length);
        Assert.NotEqual(first.raw, second.raw);
    }

    [NativeFact(Lib)]
    public void EndpointHandle_Identity_BeforeBootstrap_ThrowsTheTypedError()
    {
        using IrohEndpointHandle handle = IrohNative.CreateEndpointHandle();

        Assert.Throws<IrohFfiException.EndpointNotInitialized>(() => handle.Identity());
    }

    [NativeFact(Lib)]
    public void EndpointHandle_RejectsAnInvalidSecretKey()
    {
        using IrohEndpointHandle handle = IrohNative.CreateEndpointHandle();

        Assert.Throws<IrohFfiException.InvalidSecretKey>(
            () => handle.Bootstrap(new IrohSecretKeyMaterial(@raw: new byte[] { 1, 2, 3 }), @relayUrl: ""));
    }

    [NativeFact(Lib)]
    public void ParseBlobTicket_RejectsGarbage_WithTheTypedError()
    {
        // parse_blob_ticket maps a malformed ticket onto StreamFailed
        // ("invalid blob ticket: …") — see crates/openburnbar-iroh/src/blobs.rs.
        var error = Assert.Throws<IrohFfiException.StreamFailed>(() => IrohNative.ParseBlobTicket("not-a-ticket"));

        Assert.Contains("invalid blob ticket", error.detail, StringComparison.Ordinal);
    }
}
