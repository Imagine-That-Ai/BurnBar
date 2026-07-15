using System;
using System.IO;
using System.Linq;
using System.Xml.Linq;
using Xunit;

namespace OpenBurnBar.Dist.Tests;

public sealed class CompanionCliPackagingTests
{
    [Fact]
    public void ReleasePublishesSignedCompanionCliForEachAppRid()
    {
        string root = DistTestSupport.RepositoryRoot();
        string workflow = File.ReadAllText(Path.Combine(
            root,
            ".github",
            "workflows",
            "openburnbar-release-windows.yml"));
        string projectPath = Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.Cli",
            "OpenBurnBar.Cli.csproj");

        Assert.True(File.Exists(projectPath));
        Assert.Contains("dotnet publish \"$cli\"", workflow, StringComparison.Ordinal);
        Assert.Contains("OpenBurnBar.Cli.exe", workflow, StringComparison.Ordinal);
        Assert.Contains("OpenBurnBar*.exe,OpenBurnBar*.dll", workflow, StringComparison.Ordinal);
    }

    [Fact]
    public void MsixExposesCompanionCliThroughAppExecutionAlias()
    {
        string root = DistTestSupport.RepositoryRoot();
        XDocument manifest = XDocument.Load(Path.Combine(
            root,
            "windows",
            "packaging",
            "msix",
            "Package.appxmanifest"));
        XNamespace uap5 = "http://schemas.microsoft.com/appx/manifest/uap/windows10/5";
        XElement extension = manifest
            .Descendants(uap5 + "Extension")
            .Single(element =>
                string.Equals(
                    (string?)element.Attribute("Category"),
                    "windows.appExecutionAlias",
                    StringComparison.Ordinal));
        XElement alias = extension.Descendants(uap5 + "ExecutionAlias").Single();

        Assert.Equal("OpenBurnBar.Cli.exe", (string?)extension.Attribute("Executable"));
        Assert.Equal("Windows.FullTrustApplication", (string?)extension.Attribute("EntryPoint"));
        Assert.Equal("openburnbar.exe", (string?)alias.Attribute("Alias"));
    }

    [Fact]
    public void BothPackagersFailClosedWhenCompanionCliIsMissing()
    {
        string root = DistTestSupport.RepositoryRoot();
        string msix = File.ReadAllText(Path.Combine(
            root,
            "windows",
            "packaging",
            "msix",
            "New-MsixPackage.ps1"));
        string portable = File.ReadAllText(Path.Combine(
            root,
            "windows",
            "packaging",
            "portable",
            "New-PortableZip.ps1"));

        Assert.Contains("OpenBurnBar.Cli.exe", msix, StringComparison.Ordinal);
        Assert.Contains("Authenticated companion CLI is missing", msix, StringComparison.Ordinal);
        Assert.Contains("OpenBurnBar.Cli.exe", portable, StringComparison.Ordinal);
        Assert.Contains("Authenticated companion CLI 'OpenBurnBar.Cli.exe' is missing", portable, StringComparison.Ordinal);
    }
}
