using System.IO;
using OpenBurnBar.Native;
using Xunit;

namespace OpenBurnBar.Native.Tests;

public sealed class NativeFfiLoopbackProbeTests
{
    [Fact]
    public void Probe_EmptyStem_IsInvalid()
    {
        NativeFfiProbeResult result = NativeFfiLoopbackProbe.Probe("  ");
        Assert.False(result.IsFound);
        Assert.Equal("library_stem_required", result.Reason);
    }

    [Fact]
    public void Probe_MissingLibrary_IsNotFound_WithCandidates()
    {
        NativeFfiProbeResult result = NativeFfiLoopbackProbe.Probe("definitely_missing_obb_lib_xyz");
        Assert.False(result.IsFound);
        Assert.Equal("not_found", result.Reason);
        Assert.NotEmpty(result.Candidates);
    }

    [Fact]
    public void Probe_FindsLibrary_WhenPresentInSearchRoot()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-ffi-" + Path.GetRandomFileName());
        Directory.CreateDirectory(root);
        try
        {
            string fileName = NativeLibraryLocator.PlatformFileName("probe_lib");
            string path = Path.Combine(root, fileName);
            File.WriteAllBytes(path, new byte[] { 0x00 });

            NativeFfiProbeResult result = NativeFfiLoopbackProbe.Probe("probe_lib", root);
            Assert.True(result.IsFound);
            Assert.Equal(path, result.Path);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
