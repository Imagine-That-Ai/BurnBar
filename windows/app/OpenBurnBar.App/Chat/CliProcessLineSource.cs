using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Chat;

/// <summary>
/// Production line source: spawn a CLI agent with stream-json output and yield
/// stdout lines for <see cref="CliJsonLineChatStreamDriver"/>. Uses
/// <see cref="Process"/> (portable; works on macOS authoring host and Windows).
/// ConPTY is available separately for interactive terminal surfaces.
/// </summary>
public static class CliProcessLineSource
{
    /// <summary>Default Claude Code print + stream-json command (overridable via env).</summary>
    public const string DefaultCommandTemplate =
        "claude -p \"{0}\" --output-format stream-json --verbose";

    public static string ResolveCommandLine(string userText)
    {
        string? overrideCmd = Environment.GetEnvironmentVariable(ChatStreamDriverFactory.CliCommandEnv);
        if (!string.IsNullOrWhiteSpace(overrideCmd))
        {
            // If override already contains the user message placeholder, format it; else append -p.
            if (overrideCmd.Contains("{0}", StringComparison.Ordinal))
            {
                return string.Format(null, overrideCmd, EscapeForShell(userText));
            }

            return overrideCmd.Trim() + " -p " + Quote(userText);
        }

        return string.Format(null, DefaultCommandTemplate, EscapeForShell(userText));
    }

    /// <summary>
    /// Run <paramref name="commandLine"/> via the platform shell and yield stdout lines.
    /// On failure to start, yields a single stream-json text error line (fail-closed, not silent).
    /// </summary>
    public static async IAsyncEnumerable<string> ReadLinesAsync(
        string commandLine,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        ProcessStartInfo psi = OperatingSystem.IsWindows()
            ? new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = "/c " + commandLine,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
            }
            : new ProcessStartInfo
            {
                FileName = "/bin/bash",
                Arguments = "-lc " + Quote(commandLine),
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
            };

        Process? process = null;
        string? startError = null;
        try
        {
            process = Process.Start(psi);
            if (process is null)
            {
                startError = "CLI process failed to start (null Process).";
            }
        }
        catch (Exception ex)
        {
            startError = "Failed to start CLI process: " + ex.Message;
        }

        if (startError is not null)
        {
            yield return ErrorLine(startError);
            yield break;
        }

        if (process is null)
        {
            yield return ErrorLine("CLI process failed to start (null Process).");
            yield break;
        }

        try
        {
            using StreamReader reader = process.StandardOutput;
            while (!cancellationToken.IsCancellationRequested)
            {
                string? line = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
                if (line is null)
                {
                    break;
                }

                if (line.Length > 0)
                {
                    yield return line;
                }
            }

            string stderr = await process.StandardError.ReadToEndAsync(cancellationToken).ConfigureAwait(false);
            if (!process.HasExited)
            {
                try { process.Kill(entireProcessTree: true); } catch { /* best effort */ }
            }

            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            if (process.ExitCode != 0 && !string.IsNullOrWhiteSpace(stderr))
            {
                string snippet = stderr.Length <= 400 ? stderr : stderr[..400];
                yield return ErrorLine("CLI exited " + process.ExitCode + ": " + snippet.Replace('\n', ' '));
            }
        }
        finally
        {
            process.Dispose();
        }
    }

    /// <summary>Factory adapter for <see cref="CliJsonLineChatStreamDriver"/>.</summary>
    public static IAsyncEnumerable<string> ForChatTurn(
        string userText,
        IReadOnlyList<ChatMessageRecord> history,
        CancellationToken cancellationToken)
    {
        _ = history;
        string commandLine = ResolveCommandLine(userText);
        return ReadLinesAsync(commandLine, cancellationToken);
    }

    private static string ErrorLine(string message)
    {
        string escaped = message
            .Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("\"", "\\\"", StringComparison.Ordinal);
        return "{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"" + escaped + "\"}]}}";
    }

    private static string EscapeForShell(string text) =>
        text.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal);

    private static string Quote(string value) => "\"" + EscapeForShell(value) + "\"";
}
