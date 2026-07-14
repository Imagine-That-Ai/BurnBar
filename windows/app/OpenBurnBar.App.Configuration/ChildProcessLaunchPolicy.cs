using System.Diagnostics;
using System.Text;

namespace OpenBurnBar.App.Configuration;

public enum ChildProcessHost
{
    Windows,
    MacOS,
    Linux,
}

public sealed record ChildProcessLaunchReview(
    string Id,
    ChildProcessProfile Profile,
    string Owner,
    bool UsesOsActivation);

/// <summary>
/// Single reviewed entry point for product child-process starts. All launch specs
/// get a non-shell start, an explicit argument vector, and a filtered environment.
/// </summary>
public static class ChildProcessLaunchPolicy
{
    public static IReadOnlyList<ChildProcessLaunchReview> ReviewedProductLaunches { get; } =
        new[]
        {
            new ChildProcessLaunchReview("chat.direct-cli", ChildProcessProfile.Chat, "ChatProcessRunner", false),
            new ChildProcessLaunchReview("chat.conpty-cli", ChildProcessProfile.Chat, "ConPtyCliStream", false),
            new ChildProcessLaunchReview("switcher.conpty-cli", ChildProcessProfile.Switcher, "ConPtyCliStream", false),
            new ChildProcessLaunchReview("cloud.oauth-browser", ChildProcessProfile.BrowserActivation, "SystemBrowserLauncher", true),
            new ChildProcessLaunchReview("computer-use.playwright-bridge", ChildProcessProfile.ComputerUse, "WindowsBrowserComputerUseService", false),
            new ChildProcessLaunchReview("computer-use.kill-switch-watchdog", ChildProcessProfile.Watchdog, "App", false),
            new ChildProcessLaunchReview("data.swift-engine-interim", ChildProcessProfile.ReleaseTool, "SwiftEngineInterim", false),
            new ChildProcessLaunchReview("gateway.provider-cli", ChildProcessProfile.Gateway, "WindowsProviderCliProcessRunner", false),
            new ChildProcessLaunchReview("project-code.language-server", ChildProcessProfile.ProjectTool, "LanguageServerProjectCodeParserClient", false),
            new ChildProcessLaunchReview("project-code.static-parser", ChildProcessProfile.ProjectTool, "JsonLinesProjectCodeStaticParserClient", false),
            new ChildProcessLaunchReview("quota.claude-statusline-forwarder", ChildProcessProfile.Chat, "ClaudeStatuslineHookInstaller", false),
        };

    public static ChildProcessHost CurrentHost =>
        OperatingSystem.IsWindows()
            ? ChildProcessHost.Windows
            : OperatingSystem.IsMacOS()
                ? ChildProcessHost.MacOS
                : ChildProcessHost.Linux;

    public static ProcessStartInfo CreateStartInfo(
        ChildProcessProfile profile,
        string fileName,
        IEnumerable<string>? arguments = null,
        string? workingDirectory = null,
        bool redirectStandardInput = false,
        bool redirectStandardOutput = false,
        bool redirectStandardError = false,
        bool createNoWindow = true,
        Encoding? standardInputEncoding = null,
        Encoding? standardOutputEncoding = null,
        Encoding? standardErrorEncoding = null,
        IEnumerable<KeyValuePair<string, string?>>? requiredEnvironment = null,
        IEnumerable<KeyValuePair<string, string?>>? sourceEnvironment = null,
        ChildProcessHost? host = null)
    {
        if (string.IsNullOrWhiteSpace(fileName))
        {
            throw new ArgumentException("Child process file name must be explicit.", nameof(fileName));
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            UseShellExecute = false,
            RedirectStandardInput = redirectStandardInput,
            RedirectStandardOutput = redirectStandardOutput,
            RedirectStandardError = redirectStandardError,
            CreateNoWindow = createNoWindow,
        };

        if (!string.IsNullOrWhiteSpace(workingDirectory))
        {
            startInfo.WorkingDirectory = workingDirectory;
        }

        if (standardInputEncoding is not null)
        {
            startInfo.StandardInputEncoding = standardInputEncoding;
        }

        if (standardOutputEncoding is not null)
        {
            startInfo.StandardOutputEncoding = standardOutputEncoding;
        }

        if (standardErrorEncoding is not null)
        {
            startInfo.StandardErrorEncoding = standardErrorEncoding;
        }

        if (arguments is not null)
        {
            foreach (string argument in arguments)
            {
                startInfo.ArgumentList.Add(argument);
            }
        }

        ChildProcessEnvironment.Apply(startInfo, profile, requiredEnvironment, sourceEnvironment, host);
        return startInfo;
    }

    public static IReadOnlyDictionary<string, string> CreateEnvironment(
        ChildProcessProfile profile,
        IEnumerable<KeyValuePair<string, string?>>? source = null,
        IEnumerable<KeyValuePair<string, string?>>? required = null) =>
        ChildProcessEnvironment.CreateAllowlisted(profile, source, required);

    public static Process Start(ProcessStartInfo startInfo, ChildProcessProfile expectedProfile)
    {
        ArgumentNullException.ThrowIfNull(startInfo);
        if (startInfo.UseShellExecute)
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.WriteDenied,
                "Child process launch policy forbids shell execution.",
                expectedProfile.ToString());
        }

        foreach (string name in startInfo.Environment.Keys)
        {
            if (ChildProcessEnvironment.IsForbidden(name)
                && !ChildProcessEnvironment.IsRequiredSecretAllowed(expectedProfile, name))
            {
                throw new SecretStoreException(
                    SecretStoreFailureKind.WriteDenied,
                    $"Child process launch policy blocked forbidden environment variable '{name}'.",
                    name);
            }
        }

        return Process.Start(startInfo)
            ?? throw new InvalidOperationException("Child process did not start.");
    }

    public static Process StartDefaultBrowser(Uri authorizationUrl) =>
        Start(CreateDefaultBrowserActivation(authorizationUrl), ChildProcessProfile.BrowserActivation);

    internal static ProcessStartInfo CreateDefaultBrowserActivation(
        Uri authorizationUrl,
        ChildProcessHost? host = null,
        string? windowsDirectory = null,
        IEnumerable<KeyValuePair<string, string?>>? sourceEnvironment = null)
    {
        ArgumentNullException.ThrowIfNull(authorizationUrl);
        string url = authorizationUrl.ToString();
        ChildProcessHost resolvedHost = host ?? CurrentHost;
        return resolvedHost switch
        {
            ChildProcessHost.Windows => CreateStartInfo(
                ChildProcessProfile.BrowserActivation,
                WindowsExplorerPath(windowsDirectory),
                new[] { url },
                sourceEnvironment: sourceEnvironment,
                host: resolvedHost),
            ChildProcessHost.MacOS => CreateStartInfo(
                ChildProcessProfile.BrowserActivation,
                "open",
                new[] { url },
                sourceEnvironment: sourceEnvironment,
                host: resolvedHost),
            _ => CreateStartInfo(
                ChildProcessProfile.BrowserActivation,
                "xdg-open",
                new[] { url },
                sourceEnvironment: sourceEnvironment,
                host: resolvedHost),
        };
    }

    public static string PowerShellEnvironmentNameArrayLiteral(ChildProcessProfile profile)
    {
        string[] names = ChildProcessEnvironment
            .AllowedEnvironmentVariableNames(profile, ChildProcessHost.Windows)
            .ToArray();
        return "@(" + string.Join(",", names.Select(name => "'" + name.Replace("'", "''", StringComparison.Ordinal) + "'")) + ")";
    }

    private static string WindowsExplorerPath(string? windowsDirectory)
    {
        string? root = FirstNonEmpty(
            windowsDirectory,
            Environment.GetEnvironmentVariable("WINDIR"),
            Environment.GetFolderPath(Environment.SpecialFolder.Windows));
        return string.IsNullOrWhiteSpace(root)
            ? "explorer.exe"
            : Path.Combine(root, "explorer.exe");
    }

    private static string? FirstNonEmpty(params string?[] values) =>
        values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))?.Trim();
}
