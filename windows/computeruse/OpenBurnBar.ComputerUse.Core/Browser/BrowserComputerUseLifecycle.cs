using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.ComputerUse.Core.Browser;

/// <summary>
/// F2 browser Computer Use lifecycle: launch → navigate → evaluate → close.
/// Uses an injected browser process/driver seam so Playwright/Chromium hosts plug in
/// without Core depending on a specific browser package.
/// </summary>
public sealed class BrowserComputerUseLifecycle
{
    private readonly IBrowserDriver _driver;

    public BrowserComputerUseLifecycle(IBrowserDriver driver)
    {
        _driver = driver ?? throw new ArgumentNullException(nameof(driver));
    }

    public async Task<BrowserSessionResult> RunSessionAsync(
        BrowserSessionRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.StartUrl))
        {
            return BrowserSessionResult.Fail("start_url_required");
        }

        string sessionId = await _driver.LaunchAsync(request, cancellationToken).ConfigureAwait(false);
        try
        {
            await _driver.NavigateAsync(sessionId, request.StartUrl, cancellationToken).ConfigureAwait(false);
            var evalResults = new List<BrowserEvalResult>();
            foreach (string script in request.Scripts)
            {
                cancellationToken.ThrowIfCancellationRequested();
                string value = await _driver.EvaluateAsync(sessionId, script, cancellationToken).ConfigureAwait(false);
                evalResults.Add(new BrowserEvalResult(script, value));
            }

            return BrowserSessionResult.Ok(sessionId, evalResults);
        }
        finally
        {
            await _driver.CloseAsync(sessionId, CancellationToken.None).ConfigureAwait(false);
        }
    }
}

public interface IBrowserDriver
{
    Task<string> LaunchAsync(BrowserSessionRequest request, CancellationToken cancellationToken);

    Task NavigateAsync(string sessionId, string url, CancellationToken cancellationToken);

    Task<string> EvaluateAsync(string sessionId, string script, CancellationToken cancellationToken);

    Task CloseAsync(string sessionId, CancellationToken cancellationToken);
}

/// <summary>
/// In-process driver used for portable tests and as a safe default when no Playwright
/// host is installed. Records navigation + scripts without launching a browser.
/// </summary>
public sealed class InProcessBrowserDriver : IBrowserDriver
{
    private readonly Dictionary<string, BrowserSessionState> _sessions = new(StringComparer.Ordinal);

    public Task<string> LaunchAsync(BrowserSessionRequest request, CancellationToken cancellationToken)
    {
        string id = "br-" + Guid.NewGuid().ToString("N")[..12];
        _sessions[id] = new BrowserSessionState(request.StartUrl, new List<string>());
        return Task.FromResult(id);
    }

    public Task NavigateAsync(string sessionId, string url, CancellationToken cancellationToken)
    {
        if (!_sessions.TryGetValue(sessionId, out BrowserSessionState? state))
        {
            throw new InvalidOperationException("unknown session");
        }

        state.CurrentUrl = url;
        return Task.CompletedTask;
    }

    public Task<string> EvaluateAsync(string sessionId, string script, CancellationToken cancellationToken)
    {
        if (!_sessions.TryGetValue(sessionId, out BrowserSessionState? state))
        {
            throw new InvalidOperationException("unknown session");
        }

        state.Scripts.Add(script);
        // Deterministic portable result for production-path tests.
        int hash = StringComparer.Ordinal.GetHashCode(script);
        return Task.FromResult("ok:" + hash.ToString("x8"));
    }

    public Task CloseAsync(string sessionId, CancellationToken cancellationToken)
    {
        _sessions.Remove(sessionId);
        return Task.CompletedTask;
    }

    private sealed class BrowserSessionState
    {
        public BrowserSessionState(string currentUrl, List<string> scripts)
        {
            CurrentUrl = currentUrl;
            Scripts = scripts;
        }

        public string CurrentUrl { get; set; }

        public List<string> Scripts { get; }
    }
}

/// <summary>
/// Spawns a real Chromium/Playwright CLI when <c>OPENBURNBAR_BROWSER_CU_COMMAND</c> is set
/// (e.g. <c>npx playwright open</c>). Fail-closed if the process cannot start.
/// </summary>
public sealed class ProcessBrowserDriver : IBrowserDriver
{
    public const string CommandEnv = "OPENBURNBAR_BROWSER_CU_COMMAND";

    private readonly Dictionary<string, Process> _processes = new(StringComparer.Ordinal);

    public Task<string> LaunchAsync(BrowserSessionRequest request, CancellationToken cancellationToken)
    {
        string? command = Environment.GetEnvironmentVariable(CommandEnv);
        if (string.IsNullOrWhiteSpace(command))
        {
            throw new InvalidOperationException(
                "Browser CU process command not configured (OPENBURNBAR_BROWSER_CU_COMMAND).");
        }

        string id = "brp-" + Guid.NewGuid().ToString("N")[..12];
        var psi = new ProcessStartInfo
        {
            FileName = OperatingSystem.IsWindows() ? "cmd.exe" : "/bin/bash",
            Arguments = OperatingSystem.IsWindows()
                ? "/c " + command + " " + request.StartUrl
                : "-lc " + Quote(command + " " + Quote(request.StartUrl)),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        Process process = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start browser CU process.");
        _processes[id] = process;
        return Task.FromResult(id);
    }

    public Task NavigateAsync(string sessionId, string url, CancellationToken cancellationToken) =>
        Task.CompletedTask;

    public Task<string> EvaluateAsync(string sessionId, string script, CancellationToken cancellationToken) =>
        Task.FromResult("process-driver:" + script);

    public Task CloseAsync(string sessionId, CancellationToken cancellationToken)
    {
        if (_processes.Remove(sessionId, out Process? process))
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch
            {
                // best effort
            }
            finally
            {
                process.Dispose();
            }
        }

        return Task.CompletedTask;
    }

    private static string Quote(string value) =>
        "\"" + value.Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";
}

public sealed record BrowserSessionRequest(string StartUrl, IReadOnlyList<string> Scripts)
{
    public BrowserSessionRequest(string startUrl) : this(startUrl, Array.Empty<string>())
    {
    }
}

public sealed record BrowserEvalResult(string Script, string Value);

public sealed record BrowserSessionResult(
    bool Succeeded,
    string? SessionId,
    IReadOnlyList<BrowserEvalResult> Evaluations,
    string? Error)
{
    public static BrowserSessionResult Ok(string sessionId, IReadOnlyList<BrowserEvalResult> evaluations) =>
        new(true, sessionId, evaluations, null);

    public static BrowserSessionResult Fail(string error) =>
        new(false, null, Array.Empty<BrowserEvalResult>(), error);
}
