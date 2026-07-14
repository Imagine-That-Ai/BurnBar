using System;
using System.IO;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
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
    public const int MaxUrlCharacters = 8 * 1024;
    public const int MaxScripts = 32;
    public const int MaxScriptCharacters = 256 * 1024;

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

        if (request.StartUrl.Length > MaxUrlCharacters)
        {
            return BrowserSessionResult.Fail("start_url_too_large");
        }

        if (request.Scripts is null || request.Scripts.Count > MaxScripts)
        {
            return BrowserSessionResult.Fail("scripts_too_many");
        }

        int scriptCharacters = 0;
        foreach (string? script in request.Scripts)
        {
            if (string.IsNullOrWhiteSpace(script))
            {
                return BrowserSessionResult.Fail("script_required");
            }

            if (script.Length > MaxScriptCharacters - scriptCharacters)
            {
                return BrowserSessionResult.Fail("scripts_too_large");
            }

            scriptCharacters += script.Length;
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
/// Spawns a browser bridge using a direct executable and a JSON-line protocol.
/// The legacy shell-command environment variable is intentionally rejected:
/// browser URLs and evaluation payloads must never pass through cmd.exe/bash.
/// </summary>
public sealed class ProcessBrowserDriver : IBrowserDriver
{
    public const string ExecutableEnv = "OPENBURNBAR_BROWSER_CU_EXECUTABLE";
    public const string ArgumentsEnv = "OPENBURNBAR_BROWSER_CU_ARGUMENTS_JSON";
    public const string LegacyCommandEnv = "OPENBURNBAR_BROWSER_CU_COMMAND";

    private readonly Dictionary<string, BrowserProcess> _processes = new(StringComparer.Ordinal);
    private readonly object _gate = new();
    private readonly BrowserProcessLaunchOptions? _launchOptions;
    private readonly IBrowserProcessLauncher _launcher;

    public ProcessBrowserDriver()
    {
        _launcher = SystemBrowserProcessLauncher.Instance;
    }

    public ProcessBrowserDriver(
        BrowserProcessLaunchOptions launchOptions,
        IBrowserProcessLauncher? launcher = null)
    {
        _launchOptions = launchOptions ?? throw new ArgumentNullException(nameof(launchOptions));
        _launcher = launcher ?? SystemBrowserProcessLauncher.Instance;
    }

    public async Task<string> LaunchAsync(BrowserSessionRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        cancellationToken.ThrowIfCancellationRequested();
        BrowserProcessLaunchOptions launchOptions;
        try
        {
            launchOptions = _launchOptions ?? BrowserProcessLaunchOptions.FromEnvironment();
        }
        catch (InvalidOperationException error) when (
            !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(LegacyCommandEnv)))
        {
            throw new InvalidOperationException(
                error.Message + " The legacy shell command is not supported; configure the direct executable instead.",
                error);
        }

        string id = "brp-" + Guid.NewGuid().ToString("N")[..12];
        Process process = _launcher.Start(launchOptions);
        var browser = new BrowserProcess(process);
        lock (_gate)
        {
            _processes[id] = browser;
        }

        try
        {
            await browser.SendAsync(
                new { op = "launch", sessionId = id, url = request.StartUrl },
                cancellationToken).ConfigureAwait(false);
            return id;
        }
        catch
        {
            CloseProcess(id, browser);
            throw;
        }
    }

    internal static ProcessStartInfo CreateStartInfo(string executable, string? argumentsJson)
    {
        return BrowserProcessLaunchOptions.CreateStartInfo(
            new BrowserProcessLaunchOptions(
                executable,
                BrowserProcessLaunchOptions.ParseArguments(argumentsJson)));
    }

    public Task NavigateAsync(string sessionId, string url, CancellationToken cancellationToken)
    {
        BrowserProcess browser = GetProcess(sessionId);
        return browser.SendAsync(new { op = "navigate", sessionId, url }, cancellationToken);
    }

    public async Task<string> EvaluateAsync(string sessionId, string script, CancellationToken cancellationToken)
    {
        BrowserProcess browser = GetProcess(sessionId);
        using JsonDocument response = await browser
            .SendForResponseAsync(new { op = "evaluate", sessionId, script }, cancellationToken)
            .ConfigureAwait(false);
        if (!response.RootElement.TryGetProperty("result", out JsonElement result))
        {
            return string.Empty;
        }

        if (result.ValueKind == JsonValueKind.Object
            && result.TryGetProperty("value", out JsonElement value))
        {
            return value.ValueKind == JsonValueKind.String
                ? value.GetString() ?? string.Empty
                : value.GetRawText();
        }

        return result.ValueKind == JsonValueKind.String
            ? result.GetString() ?? string.Empty
            : result.GetRawText();
    }

    public async Task CloseAsync(string sessionId, CancellationToken cancellationToken)
    {
        BrowserProcess? browser;
        lock (_gate)
        {
            _processes.Remove(sessionId, out browser);
        }

        if (browser is null)
        {
            return;
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        try
        {
            await browser.SendAsync(new { op = "close", sessionId }, timeout.Token).ConfigureAwait(false);
        }
        catch
        {
            // Process cleanup below is still mandatory when the bridge is gone.
        }
        finally
        {
            browser.Dispose();
        }
    }

    private BrowserProcess GetProcess(string sessionId)
    {
        lock (_gate)
        {
            if (_processes.TryGetValue(sessionId, out BrowserProcess? browser))
            {
                return browser;
            }
        }

        throw new InvalidOperationException("unknown browser session");
    }

    private void CloseProcess(string sessionId, BrowserProcess browser)
    {
        lock (_gate)
        {
            _processes.Remove(sessionId);
        }

        browser.Dispose();
    }

    private sealed class BrowserProcess : IDisposable
    {
        private const int MaxResponseBytes = 1024 * 1024;
        private readonly Process _process;
        private readonly StreamReader _reader;
        private readonly StreamWriter _writer;
        private readonly Task _stderrDrain;
        private readonly SemaphoreSlim _gate = new(1, 1);

        public BrowserProcess(Process process)
        {
            _process = process;
            _reader = process.StandardOutput;
            _writer = process.StandardInput;
            _writer.AutoFlush = true;
            _stderrDrain = DrainStandardErrorAsync(process.StandardError);
        }

        public async Task SendAsync(object command, CancellationToken cancellationToken)
        {
            using JsonDocument response = await SendForResponseAsync(command, cancellationToken).ConfigureAwait(false);
            if (!IsOk(response.RootElement))
            {
                throw new InvalidOperationException(ErrorText(response.RootElement));
            }
        }

        public async Task<JsonDocument> SendForResponseAsync(object command, CancellationToken cancellationToken)
        {
            string line = JsonSerializer.Serialize(command);
            await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                await _writer.WriteLineAsync(line.AsMemory(), cancellationToken).ConfigureAwait(false);
                string? response = await _reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
                if (response is null)
                {
                    throw new InvalidOperationException("Browser CU bridge exited without a response.");
                }

                if (Encoding.UTF8.GetByteCount(response) > MaxResponseBytes)
                {
                    throw new InvalidOperationException("Browser CU bridge response exceeded the safety limit.");
                }

                return JsonDocument.Parse(response);
            }
            catch (JsonException error)
            {
                throw new InvalidOperationException("Browser CU bridge returned invalid JSON.", error);
            }
            finally
            {
                _gate.Release();
            }
        }

        public void Dispose()
        {
            try
            {
                if (!_process.HasExited)
                {
                    _process.Kill(entireProcessTree: true);
                }
            }
            catch
            {
                // best effort; the process is not allowed to survive a session close.
            }
            finally
            {
                _writer.Dispose();
                _reader.Dispose();
                _process.Dispose();
                _gate.Dispose();
            }
        }

        private static async Task DrainStandardErrorAsync(StreamReader reader)
        {
            try
            {
                while (await reader.ReadLineAsync().ConfigureAwait(false) is not null)
                {
                    // The bridge's stderr is diagnostic-only. Draining prevents
                    // a verbose bridge from blocking on a full pipe.
                }
            }
            catch (ObjectDisposedException)
            {
            }
            catch (IOException)
            {
            }
        }

        private static bool IsOk(JsonElement root) =>
            !root.TryGetProperty("ok", out JsonElement ok) || ok.ValueKind != JsonValueKind.False;

        private static string ErrorText(JsonElement root) =>
            root.TryGetProperty("error", out JsonElement error) && error.ValueKind == JsonValueKind.String
                ? error.GetString() ?? "Browser CU bridge rejected the command."
                : "Browser CU bridge rejected the command.";
    }
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
