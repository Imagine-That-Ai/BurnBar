using System;
using System.Threading.Tasks;
using OpenBurnBar.Native;
using OpenBurnBar.Native.BurnBarRemote;
using OpenBurnBar.Native.Iroh;
using Xunit;

namespace OpenBurnBar.Native.Tests;

/// <summary>
/// The graceful NotSupported surface + generated-binding API shape — run on
/// every host, no native library needed. On hosts WITHOUT the cdylibs the
/// throw-path assertions execute; on hosts WITH them the loopback tests cover
/// the same entry points, so both states are proven across environments.
/// </summary>
public sealed class NativeShimSurfaceTests
{
    [Fact]
    public void UnavailableException_IsNotSupported_AndNamesTheRemedy()
    {
        var ex = new NativeShimUnavailableException("burnbar_remote", "test shim");

        Assert.IsAssignableFrom<NotSupportedException>(ex);
        Assert.Equal("burnbar_remote", ex.LibraryLogicalName);
        Assert.Contains(NativeLibraryLocator.SearchDirEnvVar, ex.Message, StringComparison.Ordinal);
        Assert.Contains(NativeLibraryLocator.PlatformFileName("burnbar_remote"), ex.Message, StringComparison.Ordinal);
        Assert.Contains("windows/native/README.md", ex.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void IsAvailable_NeverThrows()
    {
        // Whatever the host state, the probes must be non-throwing.
        _ = BurnBarRemoteNative.IsAvailable;
        _ = IrohNative.IsAvailable;
    }

    [Fact]
    public void BurnBarRemoteFacade_WhenCdylibAbsent_ThrowsGracefulNotSupported()
    {
        if (BurnBarRemoteNative.IsAvailable)
        {
            return; // present on this host — the loopback tests prove the call path instead.
        }

        var ex = Assert.Throws<NativeShimUnavailableException>(() => BurnBarRemoteNative.Readiness());
        Assert.Equal(BurnBarRemoteNative.LibraryLogicalName, ex.LibraryLogicalName);
    }

    [Fact]
    public void IrohFacade_WhenCdylibAbsent_ThrowsGracefulNotSupported()
    {
        if (IrohNative.IsAvailable)
        {
            return; // present on this host — the loopback tests prove the call path instead.
        }

        var ex = Assert.Throws<NativeShimUnavailableException>(() => IrohNative.ProtocolVersion());
        Assert.Equal(IrohNative.LibraryLogicalName, ex.LibraryLogicalName);
    }

    [Fact]
    public void GeneratedBurnBarRemoteBinding_ExposesTheEngineSurface()
    {
        // API-shape pin: the committed generated binding carries the async
        // encode (foreign-future path), the sync decode (typed-error path), the
        // policy/scaling helpers, and the stateful controller object.
        var methods = typeof(uniffi.burnbar_remote.BurnbarRemoteMethods);
        Assert.NotNull(methods.GetMethod("BurnbarRemoteReadiness"));
        Assert.Equal(typeof(Task<byte[]>), methods.GetMethod("EncodeQualityDecision")!.ReturnType);
        Assert.NotNull(methods.GetMethod("DecodeQualityDecision"));
        Assert.NotNull(methods.GetMethod("RemoteModeRequiresPermission"));
        Assert.NotNull(methods.GetMethod("RemoteScaledDimensions"));
        Assert.True(typeof(IDisposable).IsAssignableFrom(typeof(uniffi.burnbar_remote.BurnBarRemoteQualityController)));
        Assert.True(typeof(Exception).IsAssignableFrom(typeof(uniffi.burnbar_remote.BurnBarRemoteFfiException)));
    }

    [Fact]
    public void GeneratedIrohBinding_ExposesTheTransportSurface()
    {
        var methods = typeof(uniffi.openburnbar_iroh.OpenburnbarIrohMethods);
        Assert.NotNull(methods.GetMethod("OpenburnbarIrohProtocolVersion"));
        Assert.NotNull(methods.GetMethod("OpenburnbarAlpn"));
        Assert.NotNull(methods.GetMethod("GenerateSecretKeyMaterial"));
        Assert.NotNull(methods.GetMethod("ParseBlobTicket"));
        Assert.True(typeof(IDisposable).IsAssignableFrom(typeof(uniffi.openburnbar_iroh.IrohEndpointHandle)));
        Assert.True(typeof(IDisposable).IsAssignableFrom(typeof(uniffi.openburnbar_iroh.IrohStream)));
        Assert.True(typeof(IDisposable).IsAssignableFrom(typeof(uniffi.openburnbar_iroh.IrohBlobNode)));
        Assert.True(typeof(IDisposable).IsAssignableFrom(typeof(uniffi.openburnbar_iroh.IrohDatagramChannel)));
        Assert.True(typeof(Exception).IsAssignableFrom(typeof(uniffi.openburnbar_iroh.IrohFfiException)));
    }
}
