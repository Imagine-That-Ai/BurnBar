using System;
using System.Threading.Tasks;
using uniffi.burnbar_remote;

namespace OpenBurnBar.Native.BurnBarRemote;

/// <summary>
/// Availability-gated facade over the generated <c>uniffi.burnbar_remote</c>
/// binding. Registers the hardened resolver for the binding assembly on first
/// touch, and turns "cdylib absent" into the shim's graceful
/// <see cref="NativeShimUnavailableException"/> at every entry point.
///
/// The full generated surface (<see cref="BurnbarRemoteMethods"/>,
/// <see cref="BurnBarRemoteQualityController"/>, records, typed
/// <see cref="BurnBarRemoteFfiException"/> errors) stays public — callers that
/// need more than this facade can use it directly after
/// <see cref="EnsureAvailable"/>.
/// </summary>
public static class BurnBarRemoteNative
{
    /// <summary>Logical cdylib name: <c>burnbar_remote.dll</c> /
    /// <c>libburnbar_remote.dylib</c> / <c>libburnbar_remote.so</c>.</summary>
    public const string LibraryLogicalName = "burnbar_remote";

    private const string ShimDescription = "the burnbar-remote gen-2 remote engine";

    static BurnBarRemoteNative()
    {
        NativeShimLoader.RegisterResolver(typeof(BurnbarRemoteMethods).Assembly, LibraryLogicalName);
    }

    /// <summary>True when the engine cdylib is loadable on this host. Never
    /// throws; degradable callers branch on this instead of catching.</summary>
    public static bool IsAvailable => NativeShimLoader.IsAvailable(LibraryLogicalName);

    /// <summary>Throws <see cref="NativeShimUnavailableException"/> when the
    /// cdylib is absent. Call before using the generated binding directly.</summary>
    public static void EnsureAvailable() =>
        NativeShimLoader.ThrowIfUnavailable(LibraryLogicalName, ShimDescription);

    /// <summary>Engine capability handshake (protocol version + feature bits).</summary>
    public static RemoteReadiness Readiness()
    {
        EnsureAvailable();
        return BurnbarRemoteMethods.BurnbarRemoteReadiness();
    }

    /// <summary>Async wire-encode of a quality decision, reporting stages to
    /// <paramref name="listener"/> (a foreign callback crossing the FFI).</summary>
    public static Task<byte[]> EncodeQualityDecisionAsync(RemoteQualityDecision decision, WireProgressListener listener)
    {
        EnsureAvailable();
        return BurnbarRemoteMethods.EncodeQualityDecision(decision, listener);
    }

    /// <summary>Wire-decode of a quality decision; throws the typed
    /// <see cref="BurnBarRemoteFfiException"/> subclasses on bad input.</summary>
    public static RemoteQualityDecision DecodeQualityDecision(byte[] wire)
    {
        EnsureAvailable();
        return BurnbarRemoteMethods.DecodeQualityDecision(wire);
    }

    /// <summary>Whether a session mode requires a permission (pure engine-side
    /// policy table).</summary>
    public static bool ModeRequiresPermission(RemoteSessionMode mode, RemotePermission permission)
    {
        EnsureAvailable();
        return BurnbarRemoteMethods.RemoteModeRequiresPermission(mode, permission);
    }

    /// <summary>Integer-exact dimension scaling as the engine performs it.</summary>
    public static RemoteDimensions ScaledDimensions(RemoteDimensions dimensions, uint numerator, uint denominator)
    {
        EnsureAvailable();
        return BurnbarRemoteMethods.RemoteScaledDimensions(dimensions, numerator, denominator);
    }

    /// <summary>Creates the stateful adaptive-quality controller. Dispose the
    /// returned handle when done (it owns a Rust object).</summary>
    public static BurnBarRemoteQualityController CreateQualityController(
        RemoteDimensions initialDimensions,
        RemoteQualityPreference preference)
    {
        EnsureAvailable();
        return new BurnBarRemoteQualityController(initialDimensions, preference);
    }
}
