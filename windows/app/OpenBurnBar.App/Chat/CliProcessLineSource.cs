using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
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
        ChildProcessSpec spec = ResolveProcessSpec(userText);
        return spec.DisplayCommandLine;
    }

    public static ChildProcessSpec ResolveProcessSpec(string userText)
    {
        string? overrideCmd = Environment.GetEnvironmentVariable(ChatStreamDriverFactory.CliCommandEnv);
        if (!string.IsNullOrWhiteSpace(overrideCmd))
        {
            if (overrideCmd.Contains("{0}", StringComparison.Ordinal))
            {
                return ChildProcessSpec.Parse(string.Format(null, overrideCmd, QuoteForCommandLine(userText)));
            }

            ChildProcessSpec parsed = ChildProcessSpec.Parse(overrideCmd.Trim());
            return parsed.WithAdditionalArguments("-p", userText);
        }

        return new ChildProcessSpec(
            "claude",
            new[] { "-p", userText, "--output-format", "stream-json", "--verbose" });
    }

    /// <summary>
    /// Run <paramref name="commandLine"/> without a shell and yield stdout lines.
    /// On failure to start, yields a single stream-json text error line (fail-closed, not silent).
    /// </summary>
    public static async IAsyncEnumerable<string> ReadLinesAsync(
        string commandLine,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await foreach (string line in ReadLinesAsync(ChildProcessSpec.Parse(commandLine), cancellationToken)
            .ConfigureAwait(false))
        {
            yield return line;
        }
    }

    public static async IAsyncEnumerable<string> ReadLinesAsync(
        ChildProcessSpec spec,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        ProcessStartInfo psi = CreateStartInfo(spec);

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
        return ReadLinesAsync(ResolveProcessSpec(userText), cancellationToken);
    }

    internal static ProcessStartInfo CreateStartInfo(ChildProcessSpec spec)
    {
        var psi = new ProcessStartInfo
        {
            FileName = spec.FileName,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (string argument in spec.Arguments)
        {
            psi.ArgumentList.Add(argument);
        }

        ChildProcessEnvironment.Apply(psi, ChildProcessProfile.Chat);
        return psi;
    }

    private static string ErrorLine(string message)
    {
        message = SecretRedactor.Shared.Redact(message);
        string escaped = message
            .Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("\"", "\\\"", StringComparison.Ordinal);
        return "{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"" + escaped + "\"}]}}";
    }

    private static string QuoteForCommandLine(string value) =>
        "\"" + value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";
}

public sealed record ChildProcessSpec(string FileName, IReadOnlyList<string> Arguments)
{
    public string DisplayCommandLine =>
        FileName + (Arguments.Count == 0 ? string.Empty : " " + string.Join(" ", Arguments.Select(QuoteIfNeeded)));

    public static ChildProcessSpec Parse(string commandLine)
    {
        IReadOnlyList<string> parts = SplitCommandLine(commandLine);
        if (parts.Count == 0)
        {
            throw new ArgumentException("Command line must name an executable.", nameof(commandLine));
        }

        return new ChildProcessSpec(parts[0], parts.Skip(1).ToArray());
    }

    public ChildProcessSpec WithAdditionalArguments(params string[] arguments) =>
        new(FileName, Arguments.Concat(arguments).ToArray());

    private static IReadOnlyList<string> SplitCommandLine(string commandLine)
    {
        var parts = new List<string>();
        var current = new StringBuilder();
        bool inQuote = false;
        for (int i = 0; i < commandLine.Length; i++)
        {
            char ch = commandLine[i];
            if (ch == '\\' && i + 1 < commandLine.Length && commandLine[i + 1] == '"')
            {
                current.Append('"');
                i++;
                continue;
            }

            if (ch == '"')
            {
                inQuote = !inQuote;
                continue;
            }

            if (char.IsWhiteSpace(ch) && !inQuote)
            {
                if (current.Length > 0)
                {
                    parts.Add(current.ToString());
                    current.Clear();
                }

                continue;
            }

            current.Append(ch);
        }

        if (current.Length > 0)
        {
            parts.Add(current.ToString());
        }

        return parts;
    }

    private static string QuoteIfNeeded(string value)
    {
        if (value.Length == 0 || value.Any(char.IsWhiteSpace) || value.Contains('"', StringComparison.Ordinal))
        {
            return "\"" + value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";
        }

        return value;
    }
}
