using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
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
    public void AppBuildStagesUsageWorkerFromOutputGroupsWithHostSpecificExecutable()
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

        XElement[] workerBuilds = target.Elements(ns + "MSBuild").ToArray();
        (string Targets, string OutputItem)[] expectedBuildOutputs =
        {
            ("Restore;Build", "_OpenBurnBarUsageScanWorkerPrimaryOutput"),
            ("GetCopyToOutputDirectoryItems", "_OpenBurnBarUsageScanWorkerContentOutput"),
            ("ReferenceCopyLocalPathsOutputGroup", "_OpenBurnBarUsageScanWorkerReferenceOutput"),
            ("SatelliteDllsProjectOutputGroup", "_OpenBurnBarUsageScanWorkerSatelliteOutput"),
        };
        Assert.Equal(expectedBuildOutputs.Length, workerBuilds.Length);

        foreach ((string expectedTargets, string expectedOutputItem) in expectedBuildOutputs)
        {
            XElement workerBuild = workerBuilds.Single(element => string.Equals(
                (string?)element.Attribute("Targets"),
                expectedTargets,
                StringComparison.Ordinal));
            Assert.Contains(
                "OpenBurnBar.Cli.csproj",
                (string?)workerBuild.Attribute("Projects") ?? string.Empty,
                StringComparison.Ordinal);
            Assert.Equal("Configuration=$(Configuration)", (string?)workerBuild.Attribute("Properties"));
            string[] removedProperties = ((string?)workerBuild.Attribute("RemoveProperties") ?? string.Empty)
                .Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            Assert.Equal(
                new[] { "RuntimeIdentifier", "SelfContained", "PublishSingleFile", "PublishTrimmed" },
                removedProperties);

            XElement output = workerBuild.Elements(ns + "Output").Single();
            Assert.Equal("TargetOutputs", (string?)output.Attribute("TaskParameter"));
            Assert.Equal(expectedOutputItem, (string?)output.Attribute("ItemName"));
        }

        XElement[] workerFiles = target
            .Descendants(ns + "OpenBurnBarUsageScanWorkerFile")
            .ToArray();
        XElement primaryOutput = workerFiles.Single(element => string.Equals(
            (string?)element.Attribute("Include"),
            "@(_OpenBurnBarUsageScanWorkerPrimaryOutput)",
            StringComparison.Ordinal));
        Assert.Equal("%(Filename)%(Extension)", primaryOutput.Element(ns + "TargetPath")?.Value);

        XElement groupedOutputs = workerFiles.Single(element =>
            ((string?)element.Attribute("Include"))?.Contains(
                "@(_OpenBurnBarUsageScanWorkerContentOutput)",
                StringComparison.Ordinal) == true);
        string groupedIncludes = (string?)groupedOutputs.Attribute("Include") ?? string.Empty;
        Assert.Contains("@(_OpenBurnBarUsageScanWorkerReferenceOutput)", groupedIncludes, StringComparison.Ordinal);
        Assert.Contains("@(_OpenBurnBarUsageScanWorkerSatelliteOutput)", groupedIncludes, StringComparison.Ordinal);

        XElement contentApphostRemoval = target
            .Descendants(ns + "_OpenBurnBarUsageScanWorkerContentOutput")
            .Single(element => element.Attribute("Remove") is not null);
        Assert.Equal(
            "@(_OpenBurnBarUsageScanWorkerContentOutput)",
            (string?)contentApphostRemoval.Attribute("Remove"));
        string removalCondition = (string?)contentApphostRemoval.Attribute("Condition") ?? string.Empty;
        Assert.Contains("OpenBurnBar.Cli.exe", removalCondition, StringComparison.Ordinal);
        Assert.Contains("OpenBurnBar.Cli'", removalCondition, StringComparison.Ordinal);

        XElement windowsExecutable = workerFiles.Single(element => string.Equals(
            element.Element(ns + "TargetPath")?.Value,
            "OpenBurnBar.Cli.exe",
            StringComparison.Ordinal));
        Assert.Equal(
            @"$(OpenBurnBarUsageScanWorkerPlatformDirectory)\OpenBurnBar.Cli.exe",
            (string?)windowsExecutable.Attribute("Include"));
        Assert.Contains(
            "'$(OS)' == 'Windows_NT'",
            (string?)windowsExecutable.Attribute("Condition") ?? string.Empty,
            StringComparison.Ordinal);

        XElement nonWindowsExecutable = workerFiles.Single(element => string.Equals(
            element.Element(ns + "TargetPath")?.Value,
            "OpenBurnBar.Cli",
            StringComparison.Ordinal));
        Assert.Equal(
            @"$(OpenBurnBarUsageScanWorkerPlatformDirectory)\OpenBurnBar.Cli",
            (string?)nonWindowsExecutable.Attribute("Include"));
        Assert.Contains(
            "'$(OS)' != 'Windows_NT'",
            (string?)nonWindowsExecutable.Attribute("Condition") ?? string.Empty,
            StringComparison.Ordinal);

        Assert.Contains(target.Elements(ns + "Error"), element =>
            ((string?)element.Attribute("Condition"))?.Contains(
                "!Exists('%(OpenBurnBarUsageScanWorkerFile.FullPath)')",
                StringComparison.Ordinal) == true);
        XElement copy = target.Elements(ns + "Copy").Single();
        Assert.Equal("@(OpenBurnBarUsageScanWorkerFile)", (string?)copy.Attribute("SourceFiles"));
        Assert.Equal(
            "@(OpenBurnBarUsageScanWorkerFile->'$(TargetDir)%(TargetPath)')",
            (string?)copy.Attribute("DestinationFiles"));
        Assert.Null(copy.Attribute("DestinationFolder"));
    }

    [Fact]
    public async Task DirectAppStageTargetReconcilesExactRunnableWorkerClosure()
    {
        string root = DistTestSupport.RepositoryRoot();
        string configuration = "WorkerStageTest" + Guid.NewGuid().ToString("N");
        string platform = RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.Arm64 => "arm64",
            Architecture.X64 => "x64",
            Architecture.X86 => "x86",
            Architecture.Arm => "arm",
            _ => throw new PlatformNotSupportedException(
                $"No explicit MSBuild Platform maps to {RuntimeInformation.ProcessArchitecture}."),
        };
        string appProject = Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.App",
            "OpenBurnBar.App.csproj");
        string appOutput = Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.App",
            "bin",
            platform,
            configuration,
            "net8.0-windows10.0.19041.0");
        string workerOutput = Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.Cli",
            "bin",
            platform,
            configuration,
            "net8.0");
        string manifestPath = Path.Combine(
            appOutput,
            ".openburnbar-usage-scan-worker.manifest");

        try
        {
            Assert.False(
                Directory.Exists(appOutput),
                "The direct staging regression must begin with a clean app target directory.");

            await RunAppStageTargetAsync(root, appProject, configuration, platform);

            Assert.True(
                File.Exists(manifestPath),
                "Direct staging must persist the exact worker-owned closure for the next incremental run.");
            string[] workerDeploymentClosure = (await File.ReadAllLinesAsync(manifestPath))
                .Where(path => !string.IsNullOrWhiteSpace(path))
                .Select(NormalizeRelativePath)
                .OrderBy(path => path, StringComparer.Ordinal)
                .ToArray();
            Assert.NotEmpty(workerDeploymentClosure);

            const string obsoleteRelativePath = "obsolete-worker-owned.fixture";
            const string appSentinelRelativePath = "app-owned-sentinel.fixture";
            const string sentinelContents = "the worker staging target must not delete app-owned files";
            string obsoletePath = Path.Combine(appOutput, obsoleteRelativePath);
            string appSentinelPath = Path.Combine(appOutput, appSentinelRelativePath);
            await File.WriteAllTextAsync(obsoletePath, "owned by the prior worker closure");
            await File.WriteAllTextAsync(appSentinelPath, sentinelContents);
            string[] priorWorkerClosure = (await File.ReadAllLinesAsync(manifestPath))
                .Append(obsoleteRelativePath)
                .ToArray();
            await File.WriteAllLinesAsync(manifestPath, priorWorkerClosure);

            await RunAppStageTargetAsync(root, appProject, configuration, platform);

            Assert.False(
                File.Exists(obsoletePath),
                "An artifact owned only by the prior worker closure must be removed.");
            Assert.Equal(sentinelContents, await File.ReadAllTextAsync(appSentinelPath));

            string[] stagedWorkerClosure = (await File.ReadAllLinesAsync(manifestPath))
                .Where(path => !string.IsNullOrWhiteSpace(path))
                .Select(NormalizeRelativePath)
                .OrderBy(path => path, StringComparer.Ordinal)
                .ToArray();
            Assert.Equal(workerDeploymentClosure, stagedWorkerClosure);

            var closureFailures = new List<string>();
            foreach (string relativePath in workerDeploymentClosure)
            {
                string platformRelativePath = relativePath.Replace('/', Path.DirectorySeparatorChar);
                string sourcePath = Path.Combine(workerOutput, platformRelativePath);
                string stagedPath = Path.Combine(appOutput, platformRelativePath);
                if (!File.Exists(stagedPath))
                {
                    closureFailures.Add($"missing: {relativePath}");
                }
                else if (!FilesHaveEqualSha256(sourcePath, stagedPath))
                {
                    closureFailures.Add($"content mismatch: {relativePath}");
                }
            }

            Assert.True(
                closureFailures.Count == 0,
                "Direct staging did not copy the worker's complete deployment closure:\n"
                + string.Join("\n", closureFailures));

            string[] expectedAppOutput = workerDeploymentClosure
                .Append(Path.GetFileName(manifestPath))
                .Append(appSentinelRelativePath)
                .OrderBy(path => path, StringComparer.Ordinal)
                .ToArray();
            string[] actualAppOutput = Directory
                .EnumerateFiles(appOutput, "*", SearchOption.AllDirectories)
                .Select(path => NormalizeRelativePath(Path.GetRelativePath(appOutput, path)))
                .OrderBy(path => path, StringComparer.Ordinal)
                .ToArray();
            Assert.Equal(expectedAppOutput, actualAppOutput);

            string workerHostRelativePath = OperatingSystem.IsWindows()
                ? "OpenBurnBar.Cli.exe"
                : "OpenBurnBar.Cli";
            Assert.Contains(workerHostRelativePath, stagedWorkerClosure);
            string workerHost = Path.Combine(appOutput, workerHostRelativePath);
            string invalidNativeEngine = Path.Combine(appOutput, "invalid-native-engine.fixture");
            await File.WriteAllTextAsync(invalidNativeEngine, "not a native library");
            string request = JsonSerializer.Serialize(new
            {
                supportDirectory = appOutput,
                homeDirectory = appOutput,
                claudeProjectsDirectory = appOutput,
                codexHomeDirectory = appOutput,
                cursorSessionsDirectory = appOutput,
                factorySessionsDirectory = appOutput,
                hermesHomeDirectory = appOutput,
                includeConversationBodies = false,
            });

            (int exitCode, string workerStandardOutput, string workerStandardError) =
                await RunStagedWorkerAsync(workerHost, appOutput, invalidNativeEngine, request);

            Assert.True(
                exitCode == 16,
                $"The staged worker returned exit code {exitCode}.\nstdout:\n{workerStandardOutput}\nstderr:\n{workerStandardError}");
            Assert.Equal(string.Empty, workerStandardOutput);
            Assert.Contains(
                "usage_scan_worker_failed: UsageRuntimeException: "
                + "The OpenBurnBar parser engine could not be loaded.",
                workerStandardError,
                StringComparison.Ordinal);
        }
        finally
        {
            DeleteBuildConfiguration(root, configuration, platform);
        }
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


    private static bool FilesHaveEqualSha256(string leftPath, string rightPath)
    {
        using FileStream left = File.OpenRead(leftPath);
        using FileStream right = File.OpenRead(rightPath);
        byte[] leftHash = SHA256.HashData(left);
        byte[] rightHash = SHA256.HashData(right);
        return CryptographicOperations.FixedTimeEquals(leftHash, rightHash);
    }

    private static string NormalizeRelativePath(string path) => path.Replace('\\', '/');

    private static async Task RunAppStageTargetAsync(
        string root,
        string appProject,
        string configuration,
        string platform)
    {
        var startInfo = new ProcessStartInfo("dotnet")
        {
            WorkingDirectory = root,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        startInfo.ArgumentList.Add("msbuild");
        startInfo.ArgumentList.Add(appProject);
        startInfo.ArgumentList.Add("-target:StageUsageScanWorker");
        startInfo.ArgumentList.Add($"-property:Configuration={configuration}");
        startInfo.ArgumentList.Add($"-property:Platform={platform}");
        startInfo.ArgumentList.Add("-property:EnableWindowsTargeting=true");
        startInfo.ArgumentList.Add("-nodeReuse:false");
        startInfo.ArgumentList.Add("-property:UseSharedCompilation=false");

        using Process process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("dotnet msbuild did not start.");
        Task<string> standardOutput = process.StandardOutput.ReadToEndAsync();
        Task<string> standardError = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        string output = await standardOutput;
        string error = await standardError;

        Assert.True(
            process.ExitCode == 0,
            $"Direct worker staging failed with exit code {process.ExitCode}.\n{output}\n{error}");
    }

    private static async Task<(int ExitCode, string StandardOutput, string StandardError)>
        RunStagedWorkerAsync(
            string workerHost,
            string workingDirectory,
            string invalidNativeEngine,
            string request)
    {
        var startInfo = new ProcessStartInfo(workerHost)
        {
            WorkingDirectory = workingDirectory,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        startInfo.Environment["DOTNET_ROLL_FORWARD"] = "Major";
        startInfo.ArgumentList.Add("--internal-usage-scan-worker");
        startInfo.Environment["OPENBURNBAR_CORE_CABI_PATH"] = invalidNativeEngine;

        using Process process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("The directly staged usage-scan worker did not start.");
        Task<string> standardOutput = process.StandardOutput.ReadToEndAsync();
        Task<string> standardError = process.StandardError.ReadToEndAsync();
        await process.StandardInput.WriteAsync(request);
        process.StandardInput.Close();

        try
        {
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));
        }
        catch (TimeoutException exception)
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync();
            }
            throw new TimeoutException(
                "The directly staged usage-scan worker did not answer the bounded protocol request within 15 seconds.",
                exception);
        }

        return (process.ExitCode, await standardOutput, await standardError);
    }

    private static void DeleteBuildConfiguration(
        string root,
        string configuration,
        string platform)
    {
        string[][] projectSegments =
        {
            new[] { "windows", "app", "OpenBurnBar.App" },
            new[] { "windows", "app", "OpenBurnBar.Cli" },
            new[] { "windows", "app", "OpenBurnBar.App.ManagedAgentRuntime" },
            new[] { "windows", "app", "OpenBurnBar.App.Configuration" },
            new[] { "windows", "app", "OpenBurnBar.App.UsageRuntime" },
            new[] { "windows", "computeruse", "OpenBurnBar.ComputerUse.Core" },
            new[] { "windows", "storage", "OpenBurnBar.Storage" },
        };

        foreach (string[] segments in projectSegments)
        {
            string projectRoot = segments.Aggregate(root, Path.Combine);
            foreach (string buildRoot in new[] { "bin", "obj" })
            {
                string configurationRoot = Path.Combine(projectRoot, buildRoot, platform, configuration);
                if (Directory.Exists(configurationRoot))
                {
                    DeleteDirectoryWithRetry(configurationRoot);
                }
            }
        }
    }

    private static void DeleteDirectoryWithRetry(string path)
    {
        const int attempts = 6;
        for (int attempt = 0; attempt < attempts; attempt++)
        {
            try
            {
                Directory.Delete(path, recursive: true);
                return;
            }
            catch (UnauthorizedAccessException) when (attempt < attempts - 1)
            {
                Thread.Sleep(TimeSpan.FromMilliseconds(100 * (attempt + 1)));
            }
            catch (IOException) when (attempt < attempts - 1)
            {
                Thread.Sleep(TimeSpan.FromMilliseconds(100 * (attempt + 1)));
            }
        }

        Directory.Delete(path, recursive: true);
    }
}
