using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.Versioning;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Pal.Ipc.Windows;

namespace OpenBurnBar.App.Cli;

/// <summary>
/// ConPTY-backed <see cref="ICliStream"/>: spawns a real console child via
/// <see cref="ConPtySession.Spawn"/> and maps terminal bytes to <see cref="CliStreamEvent"/>s.
/// Windows-only at runtime; compiles on the macOS authoring host with the Pal scaffold.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class ConPtyCliStream : ICliStream
{
    private readonly string _commandLine;
    private readonly short _columns;
    private readonly short _rows;
    private readonly string? _workingDirectory;

    /// <param name="commandLine">Full command line passed to <c>CreateProcessW</c> (e.g. <c>claude --print ""</c>).</param>
    /// <param name="columns">Initial pseudoconsole width.</param>
    /// <param name="rows">Initial pseudoconsole height.</param>
    /// <param name="workingDirectory">Optional child working directory.</param>
    public ConPtyCliStream(
        string commandLine,
        short columns = 120,
        short rows = 30,
        string? workingDirectory = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(commandLine);
        _commandLine = commandLine;
        _columns = columns;
        _rows = rows;
        _workingDirectory = workingDirectory;
    }

    public async IAsyncEnumerable<CliStreamEvent> ReadAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "ConPtyCliStream requires Windows (CreatePseudoConsole).");
        }

        yield return new CliStreamEvent(CliStreamEventKind.System, $"$ {_commandLine}\n");

        using var session = ConPtySession.Spawn(_commandLine, _columns, _rows, _workingDirectory);
        yield return new CliStreamEvent(
            CliStreamEventKind.System,
            $"session pid {session.ProcessId} started\n");

        var carry = new StringBuilder();
        var buffer = new byte[4096];
        while (!cancellationToken.IsCancellationRequested)
        {
            int read = await session.Output
                .ReadAsync(buffer.AsMemory(0, buffer.Length), cancellationToken)
                .ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            carry.Append(Encoding.UTF8.GetString(buffer, 0, read));
            foreach (var evt in DrainCompleteLines(carry))
            {
                yield return evt;
            }
        }

        if (carry.Length > 0)
        {
            yield return ClassifyLineFragment(carry.ToString());
        }

        yield return new CliStreamEvent(CliStreamEventKind.System, "session complete\n");
    }

    private static IEnumerable<CliStreamEvent> DrainCompleteLines(StringBuilder carry)
    {
        while (true)
        {
            string text = carry.ToString();
            int newline = text.IndexOf('\n', StringComparison.Ordinal);
            if (newline < 0)
            {
                yield break;
            }

            string line = text[..(newline + 1)];
            carry.Remove(0, newline + 1);
            yield return ClassifyLineFragment(line);
        }
    }

    private static CliStreamEvent ClassifyLineFragment(string text)
    {
        if (text.Length == 0)
        {
            return new CliStreamEvent(CliStreamEventKind.Stdout, text);
        }

        string trimmed = text.TrimStart();
        if (trimmed.StartsWith("warn:", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("error:", StringComparison.OrdinalIgnoreCase))
        {
            return new CliStreamEvent(CliStreamEventKind.Stderr, text);
        }

        if (trimmed.StartsWith("→ tool:", StringComparison.Ordinal)
            || trimmed.Contains("\"type\":\"tool_use\"", StringComparison.Ordinal)
            || trimmed.Contains("\"type\": \"tool_use\"", StringComparison.Ordinal))
        {
            return new CliStreamEvent(CliStreamEventKind.ToolCall, text);
        }

        return new CliStreamEvent(CliStreamEventKind.Stdout, text);
    }
}