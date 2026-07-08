using System;
using uniffi.openburnbar_iroh;

namespace OpenBurnBar.Native.Iroh;

/// <summary>
/// Availability-gated facade over the generated <c>uniffi.openburnbar_iroh</c>
/// binding. Registers the hardened resolver for the binding assembly on first
/// touch, and turns "cdylib absent" into the shim's graceful
/// <see cref="NativeShimUnavailableException"/> at every entry point.
///
/// The full generated surface (<see cref="OpenburnbarIrohMethods"/>,
/// <see cref="IrohEndpointHandle"/>, <see cref="IrohStream"/>,
/// <see cref="IrohBlobNode"/>, <see cref="IrohDatagramChannel"/>, records,
/// typed <see cref="IrohFfiException"/> errors) stays public — callers that
/// need more than this facade use it directly after
/// <see cref="EnsureAvailable"/>.
/// </summary>
public static class IrohNative
{
    /// <summary>Logical cdylib name: <c>openburnbar_iroh.dll</c> /
    /// <c>libopenburnbar_iroh.dylib</c> / <c>libopenburnbar_iroh.so</c>.</summary>
    public const string LibraryLogicalName = "openburnbar_iroh";

    private const string ShimDescription = "the openburnbar-iroh QUIC transport";

    static IrohNative()
    {
        NativeShimLoader.RegisterResolver(typeof(OpenburnbarIrohMethods).Assembly, LibraryLogicalName);
    }

    /// <summary>True when the transport cdylib is loadable on this host. Never
    /// throws; degradable callers branch on this instead of catching.</summary>
    public static bool IsAvailable => NativeShimLoader.IsAvailable(LibraryLogicalName);

    /// <summary>Throws <see cref="NativeShimUnavailableException"/> when the
    /// cdylib is absent. Call before using the generated binding directly.</summary>
    public static void EnsureAvailable() =>
        NativeShimLoader.ThrowIfUnavailable(LibraryLogicalName, ShimDescription);

    /// <summary>Wire protocol version this cdylib speaks (must match the Mac
    /// peer's — currently 1).</summary>
    public static uint ProtocolVersion()
    {
        EnsureAvailable();
        return OpenburnbarIrohMethods.OpenburnbarIrohProtocolVersion();
    }

    /// <summary>The OpenBurnBar chat/control ALPN (same bytes Swift pins).</summary>
    public static byte[] OpenBurnBarAlpn()
    {
        EnsureAvailable();
        return OpenburnbarIrohMethods.OpenburnbarAlpn();
    }

    /// <summary>The iroh-blobs ALPN — used to classify/refuse blob streams.</summary>
    public static byte[] BlobsAlpn()
    {
        EnsureAvailable();
        return OpenburnbarIrohMethods.IrohBlobsAlpn();
    }

    /// <summary>The Mercury audio ALPN.</summary>
    public static byte[] MercuryAudioAlpn()
    {
        EnsureAvailable();
        return OpenburnbarIrohMethods.MercuryAudioAlpn();
    }

    /// <summary>The pinned iroh-blobs crate version compiled into the cdylib —
    /// asserted against Cargo.toml by the crate CI to surface version drift.</summary>
    public static string BlobsCrateVersion()
    {
        EnsureAvailable();
        return OpenburnbarIrohMethods.IrohBlobsCrateVersion();
    }

    /// <summary>Fresh 32-byte iroh secret-key material.</summary>
    public static IrohSecretKeyMaterial GenerateSecretKeyMaterial()
    {
        EnsureAvailable();
        return OpenburnbarIrohMethods.GenerateSecretKeyMaterial();
    }

    /// <summary>Parses a blob-ticket string to its canonical form; throws the
    /// typed <see cref="IrohFfiException"/> on malformed input.</summary>
    public static BlobTicketBytes ParseBlobTicket(string text)
    {
        EnsureAvailable();
        return OpenburnbarIrohMethods.ParseBlobTicket(text);
    }

    /// <summary>Creates an un-bootstrapped endpoint handle. Call
    /// <see cref="IrohEndpointHandle.Bootstrap"/> with secret-key material to
    /// bring the QUIC endpoint up; dispose the handle when done (it owns a
    /// Rust object + tokio runtime once bootstrapped).</summary>
    public static IrohEndpointHandle CreateEndpointHandle()
    {
        EnsureAvailable();
        return new IrohEndpointHandle();
    }
}
