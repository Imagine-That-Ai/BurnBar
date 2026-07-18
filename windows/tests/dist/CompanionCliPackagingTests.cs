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

    [Fact]
    public void AppBuildStagesTheUsageScanWorkerWithHostSpecificArtifacts()
    {
        string root = DistTestSupport.RepositoryRoot();
        XDocument project = XDocument.Load(Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.App",
            "OpenBurnBar.App.csproj"));
        XNamespace ns = project.Root?.Name.Namespace
            ?? throw new InvalidOperationException("OpenBurnBar.App.csproj has no root element.");

        XElement target = project
            .Descendants(ns + "Target")
            .Single(element => string.Equals(
                (string?)element.Attribute("Name"),
                "StageUsageScanWorker",
                StringComparison.Ordinal));
        string[] afterTargets = ((string?)target.Attribute("AfterTargets") ?? string.Empty)
            .Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        Assert.Contains(afterTargets, value => string.Equals(value, "Build", StringComparison.Ordinal));

        XElement workerBuild = target.Elements(ns + "MSBuild").Single();
        Assert.Contains(
            "OpenBurnBar.Cli.csproj",
            (string?)workerBuild.Attribute("Projects") ?? string.Empty,
            StringComparison.Ordinal);
        string[] workerTargets = ((string?)workerBuild.Attribute("Targets") ?? string.Empty)
            .Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        int restoreIndex = Array.FindIndex(workerTargets, value =>
            string.Equals(value, "Restore", StringComparison.Ordinal));
        int buildIndex = Array.FindIndex(workerTargets, value =>
            string.Equals(value, "Build", StringComparison.Ordinal));
        Assert.True(restoreIndex >= 0, "The separately invoked worker project must restore on a clean runner.");
        Assert.True(
            buildIndex > restoreIndex,
            "The separately invoked worker project must build only after restore completes.");
        string[] removedProperties = ((string?)workerBuild.Attribute("RemoveProperties") ?? string.Empty)
            .Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        Assert.Contains("RuntimeIdentifier", removedProperties);

        XElement[] workerFiles = target
            .Descendants(ns + "OpenBurnBarUsageScanWorkerFile")
            .ToArray();
        string[] includes = workerFiles
            .Select(element => (string?)element.Attribute("Include") ?? string.Empty)
            .ToArray();
        Assert.Contains(includes, include => include.EndsWith("OpenBurnBar.Cli.exe", StringComparison.Ordinal));
        Assert.Contains(includes, include => include.EndsWith("OpenBurnBar.Cli.dll", StringComparison.Ordinal));
        Assert.Contains(includes, include => include.EndsWith("OpenBurnBar.Cli.deps.json", StringComparison.Ordinal));
        Assert.Contains(includes, include => include.EndsWith("OpenBurnBar.Cli.runtimeconfig.json", StringComparison.Ordinal));
        Assert.All(includes, include => Assert.Contains(
            "$(OpenBurnBarUsageScanWorkerPlatformDirectory)",
            include,
            StringComparison.Ordinal));

        XElement executable = workerFiles.Single(element =>
            ((string?)element.Attribute("Include") ?? string.Empty)
                .EndsWith("OpenBurnBar.Cli.exe", StringComparison.Ordinal));
        Assert.Contains(
            "Windows_NT",
            (string?)executable.Attribute("Condition") ?? string.Empty,
            StringComparison.Ordinal);

        XElement error = target.Elements(ns + "Error").Single();
        Assert.Contains(
            "Exists('%(OpenBurnBarUsageScanWorkerFile.FullPath)')",
            (string?)error.Attribute("Condition") ?? string.Empty,
            StringComparison.Ordinal);
        XElement copy = target.Elements(ns + "Copy").Single();
        Assert.Contains(
            "@(OpenBurnBarUsageScanWorkerFile)",
            (string?)copy.Attribute("SourceFiles") ?? string.Empty,
            StringComparison.Ordinal);
        Assert.Equal("$(TargetDir)", (string?)copy.Attribute("DestinationFolder"));
    }

}
