using System.Diagnostics;
using System.Text.Json;
using OpenBurnBar.ComputerUse.Core.Browser;

namespace OpenBurnBar.App.Configuration;

public sealed class WindowsBrowserComputerUseService : IComputerUseBrowserService
{
    private const string NodeExecutableEnvironment = "OPENBURNBAR_NODE_EXECUTABLE";
    private const string PlaywrightNodePathEnvironment = "OPENBURNBAR_PLAYWRIGHT_NODE_PATH";
    private readonly BrowserProcessLaunchOptions? _launchOptions;

    public WindowsBrowserComputerUseService()
    {
        (_launchOptions, RuntimeStatus) = Discover();
    }

    public bool IsAvailable => _launchOptions is not null;

    public string RuntimeStatus { get; }

    public Task<BrowserSessionResult> RunCheckAsync(
        string startUrl,
        CancellationToken cancellationToken)
    {
        if (_launchOptions is null)
        {
            return Task.FromResult(BrowserSessionResult.Fail("browser_runtime_not_configured"));
        }

        var lifecycle = new BrowserComputerUseLifecycle(
            new ProcessBrowserDriver(_launchOptions, ReviewedBrowserProcessLauncher.Instance));
        return lifecycle.RunSessionAsync(
            new BrowserSessionRequest(startUrl, new[] { "document.title" }),
            cancellationToken);
    }

    private static (BrowserProcessLaunchOptions? Options, string Status) Discover()
    {
        if (!string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(ProcessBrowserDriver.ExecutableEnv)))
        {
            try
            {
                return (BrowserProcessLaunchOptions.FromEnvironment(), "Ready through the explicit browser runtime configuration.");
            }
            catch (InvalidOperationException error)
            {
                return (null, error.Message);
            }
        }

        string bridgePath = Path.Combine(
            AppContext.BaseDirectory,
            "Resources",
            "PlaywrightBridge",
            "openburnbar-playwright-bridge.js");
        if (!File.Exists(bridgePath))
        {
            return (null, "The signed Playwright bridge is missing from this installation.");
        }

        string? nodeExecutable = FindNodeExecutable();
        if (nodeExecutable is null)
        {
            return (null, "Node.js is required for browser mode.");
        }

        string? nodePath = FindPinnedPlaywrightNodePath();
        if (nodePath is null)
        {
            return (null, "Pinned Playwright 1.49 is not installed for browser mode.");
        }

        string? browsersPath = FindChromiumBrowsersPath();
        if (browsersPath is null)
        {
            return (null, "The Playwright Chromium runtime is not installed.");
        }

        var requiredEnvironment = new Dictionary<string, string?>(StringComparer.Ordinal)
        {
            ["NODE_PATH"] = nodePath,
            ["PLAYWRIGHT_BROWSERS_PATH"] = browsersPath,
        };
        return (
            new BrowserProcessLaunchOptions(
                nodeExecutable,
                new[] { bridgePath, "--headless" },
                requiredEnvironment),
            "Ready: pinned Playwright bridge and Chromium runtime discovered.");
    }

    private static string? FindNodeExecutable()
    {
        IEnumerable<string?> candidates = new[]
        {
            Environment.GetEnvironmentVariable(NodeExecutableEnvironment),
            CombineEnvironmentPath("ProgramFiles", "nodejs", "node.exe"),
            CombineEnvironmentPath("ProgramW6432", "nodejs", "node.exe"),
            CombineEnvironmentPath("LOCALAPPDATA", "Programs", "nodejs", "node.exe"),
        }.Concat(PathCandidates("node.exe"));
        foreach (string? candidate in candidates.Where(candidate => !string.IsNullOrWhiteSpace(candidate)))
        {
            try
            {
                string fullPath = Path.GetFullPath(candidate!);
                if (File.Exists(fullPath))
                {
                    return fullPath;
                }
            }
            catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException)
            {
            }
        }

        return null;
    }

    private static string? FindPinnedPlaywrightNodePath()
    {
        IEnumerable<string?> candidates = new[]
        {
            Environment.GetEnvironmentVariable(PlaywrightNodePathEnvironment),
            Path.Combine(AppContext.BaseDirectory, "node_modules"),
            CombineEnvironmentPath("APPDATA", "npm", "node_modules"),
        };
        foreach (string? candidate in candidates.Where(candidate => !string.IsNullOrWhiteSpace(candidate)))
        {
            try
            {
                string root = Path.GetFullPath(candidate!);
                if (IsPinnedPlaywrightPackage(Path.Combine(root, "playwright", "package.json")))
                {
                    return root;
                }
            }
            catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException)
            {
            }
        }

        return null;
    }

    private static string? FindChromiumBrowsersPath()
    {
        IEnumerable<string?> candidates = new[]
        {
            Environment.GetEnvironmentVariable("PLAYWRIGHT_BROWSERS_PATH"),
            CombineEnvironmentPath("LOCALAPPDATA", "ms-playwright"),
        };
        foreach (string? candidate in candidates.Where(candidate => !string.IsNullOrWhiteSpace(candidate)))
        {
            try
            {
                string root = Path.GetFullPath(candidate!);
                if (Directory.Exists(root)
                    && Directory.EnumerateDirectories(root, "chromium*", SearchOption.TopDirectoryOnly).Any())
                {
                    return root;
                }
            }
            catch (Exception error) when (
                error is ArgumentException or IOException or UnauthorizedAccessException)
            {
            }
        }

        return null;
    }

    private static bool IsPinnedPlaywrightPackage(string packagePath)
    {
        try
        {
            using JsonDocument package = JsonDocument.Parse(File.ReadAllText(packagePath));
            return package.RootElement.TryGetProperty("version", out JsonElement version)
                && version.ValueKind == JsonValueKind.String
                && (version.GetString() ?? string.Empty).StartsWith("1.49.", StringComparison.Ordinal);
        }
        catch (Exception error) when (
            error is IOException or UnauthorizedAccessException or JsonException)
        {
            return false;
        }
    }

    private static IEnumerable<string> PathCandidates(string fileName)
    {
        foreach (string directory in (Environment.GetEnvironmentVariable("PATH") ?? string.Empty)
                     .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            string candidate;
            try
            {
                candidate = Path.Combine(directory, fileName);
            }
            catch (ArgumentException)
            {
                continue;
            }

            yield return candidate;
        }
    }

    private static string? CombineEnvironmentPath(string name, params string[] segments)
    {
        string? root = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrWhiteSpace(root)
            ? null
            : Path.Combine(new[] { root }.Concat(segments).ToArray());
    }

    private sealed class ReviewedBrowserProcessLauncher : IBrowserProcessLauncher
    {
        public static ReviewedBrowserProcessLauncher Instance { get; } = new();

        public Process Start(BrowserProcessLaunchOptions options)
        {
            ProcessStartInfo startInfo = ChildProcessLaunchPolicy.CreateStartInfo(
                ChildProcessProfile.ComputerUse,
                options.Executable,
                options.Arguments,
                redirectStandardInput: true,
                redirectStandardOutput: true,
                redirectStandardError: true,
                requiredEnvironment: options.RequiredEnvironment);
            return ChildProcessLaunchPolicy.Start(startInfo, ChildProcessProfile.ComputerUse);
        }
    }
}
