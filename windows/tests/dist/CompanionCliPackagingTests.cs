using System;
using System.Collections.Generic;
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
        Assert.Contains("OpenBurnBar.Cli.deps.json", workflow, StringComparison.Ordinal);
        Assert.Contains("OpenBurnBar.Cli.runtimeconfig.json", workflow, StringComparison.Ordinal);
        Assert.Contains("OPENBURNBAR_REQUIRE_NATIVE_ENGINE_INTEGRATION", workflow, StringComparison.Ordinal);
        Assert.Contains("FullyQualifiedName~NativeUsageEngineIntegrationTests", workflow, StringComparison.Ordinal);
    }

    [Fact]
    public void AppUsesPublishedCompanionCliAsNativeUsageScanWorker()
    {
        string root = DistTestSupport.RepositoryRoot();
        string appComposition = File.ReadAllText(Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.App",
            "App.xaml.cs"));
        string cliEntryPoint = File.ReadAllText(Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.Cli",
            "Program.cs"));

        Assert.Contains("new OutOfProcessUsageEngine()", appComposition, StringComparison.Ordinal);
        Assert.DoesNotContain("new CAbiUsageEngine()", appComposition, StringComparison.Ordinal);
        Assert.Contains("UsageScanWorkerProtocol.WorkerArgument", cliEntryPoint, StringComparison.Ordinal);
        Assert.Contains("new CAbiUsageEngine()", cliEntryPoint, StringComparison.Ordinal);
        Assert.Contains("UsageScanWorkerHost.RunAsync", cliEntryPoint, StringComparison.Ordinal);
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

    [Fact]
    public void FastPrWorkflowVerifiesTheBuiltUsageScanWorker()
    {
        string workflow = File.ReadAllText(Path.Combine(
            DistTestSupport.RepositoryRoot(),
            ".github",
            "workflows",
            "pr-windows-fast.yml"));
        int buildStepIndex = workflow.IndexOf(
            "name: Build Windows solution",
            StringComparison.Ordinal);
        int verifyStepIndex = workflow.IndexOf(
            "name: Verify usage-scan worker staging",
            StringComparison.Ordinal);
        int testStepIndex = workflow.IndexOf(
            "name: Run Windows test suite",
            StringComparison.Ordinal);

        Assert.True(buildStepIndex >= 0, "The fast Windows PR workflow must contain the build step.");
        Assert.True(verifyStepIndex > buildStepIndex, "Worker staging verification must run after the Windows solution build.");
        Assert.True(testStepIndex > verifyStepIndex, "Worker staging verification must run before the Windows test suite.");

        string verificationStep = workflow.Substring(
            verifyStepIndex,
            testStepIndex - verifyStepIndex);
        string normalizedVerificationStep = verificationStep.Replace('\\', '/');

        Assert.Contains("Get-ChildItem", verificationStep, StringComparison.Ordinal);
        Assert.Contains("Test-Path", verificationStep, StringComparison.Ordinal);
        Assert.Contains(
            "windows/app/OpenBurnBar.App/bin",
            normalizedVerificationStep,
            StringComparison.OrdinalIgnoreCase);
    }
}
