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

    public async Task<string> LaunchAsync(BrowserSessionRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        cancellationToken.ThrowIfCancellationRequested();
        string? executable = Environment.GetEnvironmentVariable(ExecutableEnv);
        if (string.IsNullOrWhiteSpace(executable))
        {
            string legacyHint = string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(LegacyCommandEnv))
                ? string.Empty
                : " The legacy shell command is not supported; configure the direct executable instead.";
            throw new InvalidOperationException(
                "Browser CU executable is not configured (OPENBURNBAR_BROWSER_CU_EXECUTABLE)." + legacyHint);
        }

        string id = "brp-" + Guid.NewGuid().ToString("N")[..12];
        var psi = new ProcessStartInfo
        {
            FileName = executable.Trim(),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (string argument in ParseArguments(Environment.GetEnvironmentVariable(ArgumentsEnv)))
        {
            psi.ArgumentList.Add(argument);
        }

        Process process = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start browser CU process.");
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

        try
        {
            await browser.SendAsync(new { op = "close", sessionId }, cancellationToken).ConfigureAwait(false);
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

    private static IReadOnlyList<string> ParseArguments(string? json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return Array.Empty<string>();
        }

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

    private sealed class BrowserProcess : IDisposable
    {
        private const int MaxResponseBytes = 1024 * 1024;
        private readonly Process _process;
        private readonly StreamReader _reader;
        private readonly StreamWriter _writer;
        private readonly SemaphoreSlim _gate = new(1, 1);

        public BrowserProcess(Process process)
        {
            _process = process;
            _reader = process.StandardOutput;
            _writer = process.StandardInput;
            _writer.AutoFlush = true;
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
