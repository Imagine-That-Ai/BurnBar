using System;
using System.IO;
using Xunit;

namespace OpenBurnBar.App.Onboarding.Tests;

/// <summary>
/// Static file-content tests proving windows/Directory.Build.props centralizes the
/// three repo-wide strict-build properties (Nullable, LangVersion, TreatWarningsAsErrors)
/// so every project under windows/ inherits them — and proving the flagship
/// OpenBurnBar.App.csproj no longer duplicates TreatWarningsAsErrors (it inherits it).
/// These are static <c>File.ReadAllText</c> assertions, not runtime MSBuild evaluation,
/// so they run on the macOS authoring host without invoking the Windows-only build.
/// </summary>
public sealed class DirectoryBuildPropsInheritanceTests
{
    /// <summary>
    /// Walks up from the test assembly directory until it finds the windows/
    /// root (the folder that directly contains Directory.Build.props). The
    /// test assembly runs from windows/tests/onboarding/bin/Debug/net10.0/, so
    /// the walk terminates reliably regardless of build configuration.
    /// </summary>
    private static readonly string WindowsRoot = ResolveWindowsRoot();

    private static readonly string DirectoryBuildPropsPath =
        Path.Combine(WindowsRoot, "Directory.Build.props");

    private static readonly string FlagshipCsprojPath =
        Path.Combine(WindowsRoot, "app", "OpenBurnBar.App", "OpenBurnBar.App.csproj");

    private static string ResolveWindowsRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "Directory.Build.props")))
            {
                return dir.FullName;
            }
            dir = dir.Parent;
        }
        throw new FileNotFoundException(
            "Could not locate windows/ root (Directory.Build.props) walking up from " +
            AppContext.BaseDirectory);
    }

    // MARK: - Directory.Build.props exists

    [Fact]
    public void DirectoryBuildProps_FileExists()
    {
        Assert.True(File.Exists(DirectoryBuildPropsPath),
            $"Expected central build props at {DirectoryBuildPropsPath}");
    }

    // MARK: - Centralizes the three key properties

    [Fact]
    public void DirectoryBuildProps_ContainsTreatWarningsAsErrorsTrue()
    {
        string contents = File.ReadAllText(DirectoryBuildPropsPath);
        Assert.Contains("<TreatWarningsAsErrors>true</TreatWarningsAsErrors>", contents);
    }

    [Fact]
    public void DirectoryBuildProps_ContainsNullableEnable()
    {
        string contents = File.ReadAllText(DirectoryBuildPropsPath);
        Assert.Contains("<Nullable>enable</Nullable>", contents);
    }

    [Fact]
    public void DirectoryBuildProps_ContainsLangVersionLatest()
    {
        string contents = File.ReadAllText(DirectoryBuildPropsPath);
        Assert.Contains("<LangVersion>latest</LangVersion>", contents);
    }

    // MARK: - Flagship csproj does NOT duplicate TreatWarningsAsErrors

    [Fact]
    public void FlagshipCsproj_DoesNotContainTreatWarningsAsErrors()
    {
        string contents = File.ReadAllText(FlagshipCsprojPath);
        Assert.DoesNotContain("<TreatWarningsAsErrors>", contents);
    }
}