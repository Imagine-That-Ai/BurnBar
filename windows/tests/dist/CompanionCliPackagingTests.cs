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
    public void AppBuildStagesCompleteCompanionCliAndFastPrWorkflowVerifiesTheBuiltOutput()
    {
        string root = DistTestSupport.RepositoryRoot();
        string appProjectPath = Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.App",
            "OpenBurnBar.App.csproj");
        XDocument appProject = XDocument.Load(appProjectPath);

        XElement cliProjectReference = appProject
            .Descendants()
            .Where(element =>
                string.Equals(
                    element.Name.LocalName,
                    "ProjectReference",
                    StringComparison.Ordinal))
            .Single(element =>
                string.Equals(
                    ((string?)element.Attribute("Include"))?.Replace('\\', '/'),
                    "../OpenBurnBar.Cli/OpenBurnBar.Cli.csproj",
                    StringComparison.Ordinal));

        Assert.Equal(
            "false",
            (string?)cliProjectReference.Attribute("ReferenceOutputAssembly"));

        XElement stagingTarget = appProject
            .Descendants()
            .Where(element =>
                string.Equals(
                    element.Name.LocalName,
                    "Target",
                    StringComparison.Ordinal))
            .Single(element =>
                string.Equals(
                    (string?)element.Attribute("Name"),
                    "StageUsageScanWorker",
                    StringComparison.Ordinal));

        string afterTargets = (string?)stagingTarget.Attribute("AfterTargets") ?? string.Empty;
        Assert.Contains(
            "Build",
            afterTargets.Split(
                ';',
                StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));

        XElement msBuild = stagingTarget
            .Descendants()
            .Where(element =>
                string.Equals(
                    element.Name.LocalName,
                    "MSBuild",
                    StringComparison.Ordinal))
            .Single();

        string msBuildTargets = (string?)msBuild.Attribute("Targets") ?? string.Empty;
        Assert.Contains(
            "GetTargetPath",
            msBuildTargets.Split(
                ';',
                StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));

        string msBuildProjects = (string?)msBuild.Attribute("Projects") ?? string.Empty;
        bool invokesCliProject = msBuildProjects
            .Split(
                ';',
                StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Any(project =>
                string.Equals(
                    project,
                    "@(ProjectReference)",
                    StringComparison.Ordinal)
                || project
                    .Replace('\\', '/')
                    .EndsWith(
                        "/../OpenBurnBar.Cli/OpenBurnBar.Cli.csproj",
                        StringComparison.Ordinal));

        Assert.True(
            invokesCliProject,
            "StageUsageScanWorker must invoke MSBuild GetTargetPath for the companion CLI project.");

        XElement copy = stagingTarget
            .Descendants()
            .Where(element =>
                string.Equals(
                    element.Name.LocalName,
                    "Copy",
                    StringComparison.Ordinal))
            .Single();

        Assert.Equal("$(TargetDir)", (string?)copy.Attribute("DestinationFolder"));

        string sourceFiles = (string?)copy.Attribute("SourceFiles") ?? string.Empty;
        Assert.True(
            sourceFiles.StartsWith("@(", StringComparison.Ordinal)
            && sourceFiles.EndsWith(")", StringComparison.Ordinal),
            "The staging Copy task must copy a declared MSBuild item.");

        int transformIndex = sourceFiles.IndexOf("->", StringComparison.Ordinal);
        int closingParenthesisIndex = sourceFiles.IndexOf(')');
        int itemNameEnd = transformIndex >= 0
            ? transformIndex
            : closingParenthesisIndex;
        Assert.True(
            itemNameEnd > 2,
            "The staging Copy task must reference a named MSBuild item.");

        string copiedItemName = sourceFiles.Substring(2, itemNameEnd - 2).Trim();
        string[] copiedIncludes = stagingTarget
            .Descendants()
            .Where(element =>
                string.Equals(
                    element.Name.LocalName,
                    copiedItemName,
                    StringComparison.Ordinal)
                && element.Attribute("Include") is not null)
            .SelectMany(element =>
                element.Attribute("Include")!.Value.Split(
                    ';',
                    StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            .ToArray();
        string[] requiredSuffixes =
        [
            "OpenBurnBar.Cli.exe",
            "OpenBurnBar.Cli.dll",
            "OpenBurnBar.Cli.deps.json",
            "OpenBurnBar.Cli.runtimeconfig.json",
        ];

        Assert.Equal(requiredSuffixes.Length, copiedIncludes.Length);
        Assert.All(
            copiedIncludes,
            include => Assert.Single(
                requiredSuffixes,
                suffix => include.Contains(suffix, StringComparison.Ordinal)));
        foreach (string requiredSuffix in requiredSuffixes)
        {
            Assert.Single(
                copiedIncludes,
                include => include.Contains(requiredSuffix, StringComparison.Ordinal));
        }

        string workflow = File.ReadAllText(Path.Combine(
            root,
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