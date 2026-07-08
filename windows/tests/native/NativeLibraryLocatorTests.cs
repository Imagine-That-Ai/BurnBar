using System;
using System.IO;
using System.Runtime.InteropServices;
using OpenBurnBar.Native;
using Xunit;

namespace OpenBurnBar.Native.Tests;

/// <summary>
/// Pure tests of the hardened locator — run on every host, no native library
/// needed. These pin the DLL-planting posture: absolute-only probing, no CWD,
/// no PATH.
/// </summary>
public sealed class NativeLibraryLocatorTests
{
    [Fact]
    public void PlatformFileName_MapsLogicalNamePerOs()
    {
        string name = NativeLibraryLocator.PlatformFileName("burnbar_remote");

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            Assert.Equal("burnbar_remote.dll", name);
        }
        else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            Assert.Equal("libburnbar_remote.dylib", name);
        }
        else
        {
            Assert.Equal("libburnbar_remote.so", name);
        }
    }

    [Fact]
    public void Locate_ReturnsNull_WhenNoDirectoryContainsTheLibrary()
    {
        string missingDir = Path.Combine(Path.GetTempPath(), "openburnbar-native-tests-" + Guid.NewGuid().ToString("N"));

        Assert.Null(NativeLibraryLocator.Locate("burnbar_remote", new[] { missingDir }));
    }

    [Fact]
    public void Locate_FindsTheLibrary_InAnAbsoluteDirectory()
    {
        string dir = Directory.CreateTempSubdirectory("openburnbar-native-tests-").FullName;
        try
        {
            string fileName = NativeLibraryLocator.PlatformFileName("fake_lib");
            File.WriteAllBytes(Path.Combine(dir, fileName), new byte[] { 0x00 });

            string? located = NativeLibraryLocator.Locate("fake_lib", new[] { dir });

            Assert.Equal(Path.Combine(dir, fileName), located);
            Assert.True(Path.IsPathRooted(located));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void Locate_SkipsRelativeDirectories_NeverProbingTheWorkingDirectory()
    {
        // Even a directory that WOULD resolve relative to the CWD is refused:
        // only absolute entries participate (the R19 search-order posture).
        Assert.Null(NativeLibraryLocator.Locate("burnbar_remote", new[] { ".", "bin", "relative/dir" }));
    }

    [Fact]
    public void Locate_Throws_OnEmptyLogicalName()
    {
        Assert.Throws<ArgumentException>(() => NativeLibraryLocator.Locate("", new[] { Path.GetTempPath() }));
    }

    [Fact]
    public void DefaultSearchDirectories_AreAllAbsolute_AndIncludeTheBaseDirectory()
    {
        var directories = NativeLibraryLocator.DefaultSearchDirectories();

        Assert.All(directories, d => Assert.True(Path.IsPathRooted(d), $"non-absolute probe dir: {d}"));
        Assert.Contains(AppContext.BaseDirectory, directories);
    }
}
