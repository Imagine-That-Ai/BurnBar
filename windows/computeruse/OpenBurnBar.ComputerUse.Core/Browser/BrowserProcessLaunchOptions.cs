using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.ComputerUse.Core.Browser;

public sealed class BrowserProcessLaunchOptions
{
    public const int MaxArguments = 32;
    public const int MaxArgumentCharacters = 8 * 1024;

    public BrowserProcessLaunchOptions(
        string executable,
        IReadOnlyList<string>? arguments = null,
        IReadOnlyDictionary<string, string?>? requiredEnvironment = null)
    {
        if (string.IsNullOrWhiteSpace(executable))
        {
            throw new InvalidOperationException(
                "Browser CU executable is not configured (OPENBURNBAR_BROWSER_CU_EXECUTABLE).");
        }

        string[] normalizedArguments = (arguments ?? Array.Empty<string>()).ToArray();
        if (normalizedArguments.Length > MaxArguments
            || normalizedArguments.Any(argument => argument is null || argument.Length > MaxArgumentCharacters))
        {
            throw new InvalidOperationException("Browser CU arguments exceed the safety limit.");
        }

        Executable = executable.Trim();
        Arguments = normalizedArguments;
        RequiredEnvironment = requiredEnvironment is null
            ? new Dictionary<string, string?>(StringComparer.Ordinal)
            : new Dictionary<string, string?>(requiredEnvironment, StringComparer.Ordinal);
    }

    public string Executable { get; }

    public IReadOnlyList<string> Arguments { get; }

    public IReadOnlyDictionary<string, string?> RequiredEnvironment { get; }

    public static BrowserProcessLaunchOptions FromEnvironment() => new(
        Environment.GetEnvironmentVariable(ProcessBrowserDriver.ExecutableEnv) ?? string.Empty,
        ParseArguments(Environment.GetEnvironmentVariable(ProcessBrowserDriver.ArgumentsEnv)));

    internal static IReadOnlyList<string> ParseArguments(string? json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return Array.Empty<string>();
        }

        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Array)
            {
                throw new InvalidOperationException("Browser CU arguments must be a JSON array.");
            }

            var arguments = new List<string>();
            foreach (JsonElement element in document.RootElement.EnumerateArray())
            {
                if (element.ValueKind != JsonValueKind.String)
                {
                    throw new InvalidOperationException("Browser CU arguments must contain strings only.");
                }

                arguments.Add(element.GetString() ?? string.Empty);
            }

            return arguments;
        }
        catch (JsonException error)
        {
            throw new InvalidOperationException("Browser CU arguments must be valid JSON.", error);
        }
    }

    internal static ProcessStartInfo CreateStartInfo(BrowserProcessLaunchOptions options)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = options.Executable,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (string argument in options.Arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        foreach ((string name, string? value) in options.RequiredEnvironment)
        {
            if (value is null)
            {
                startInfo.Environment.Remove(name);
            }
            else
            {
                startInfo.Environment[name] = value;
            }
        }

        return startInfo;
    }
}

public interface IBrowserProcessLauncher
{
    Process Start(BrowserProcessLaunchOptions options);
}

public interface IComputerUseBrowserService
{
    bool IsAvailable { get; }

    string RuntimeStatus { get; }

    Task<BrowserSessionResult> RunCheckAsync(string startUrl, CancellationToken cancellationToken);
}

public sealed class DisabledComputerUseBrowserService : IComputerUseBrowserService
{
    public static DisabledComputerUseBrowserService Instance { get; } = new();

    public bool IsAvailable => false;

    public string RuntimeStatus => "The pinned Playwright browser runtime is not installed.";

    public Task<BrowserSessionResult> RunCheckAsync(string startUrl, CancellationToken cancellationToken) =>
        Task.FromResult(BrowserSessionResult.Fail("browser_runtime_not_configured"));
}

internal sealed class SystemBrowserProcessLauncher : IBrowserProcessLauncher
{
    public static SystemBrowserProcessLauncher Instance { get; } = new();

    public Process Start(BrowserProcessLaunchOptions options) =>
        Process.Start(BrowserProcessLaunchOptions.CreateStartInfo(options))
        ?? throw new InvalidOperationException("Failed to start browser CU process.");
}
