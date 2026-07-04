using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.Versioning;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Pal.Ipc.Windows;

namespace OpenBurnBar.B0Spike.Cli;

/// <summary>
/// ConPTY-backed <see cref="ICliStream"/>: spawns a real console child via
/// <see cref="ConPtySession.Spawn"/> and maps terminal bytes to <see cref="CliStreamEvent"/>s.
/// Windows-only at runtime (VAL-P0-CONPTY-019); compiles on macOS for the spike contract.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class ConPtyCliStream : ICliStream
{
    private readonly string _commandLine;
    private readonly short _columns;
    private readonly short _rows;
    private readonly string? _workingDirectory;

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
                "ConPtyCliStream requires Windows (CreatePseudoConsole). See docs/windows-port/spikes/b0-end-to-end-spike.md.");
        }

        yield return new CliStreamEvent(CliStreamEventKind.System, $"$ {_commandLine}\n");

        using var session = ConPtySession.Spawn(_commandLine, _columns, _rows, _workingDirectory);
        yield return new CliStreamEvent(
            CliStreamEventKind.System,
            $"session pid {session.ProcessId} started\n");

        var buffer = new byte[4096];
        while (!cancellationToken.IsCancellationRequested)
        {
            int read = await session.Output.ReadAsync(buffer.AsMemory(0, buffer.Length), cancellationToken)
                .ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            string chunk = Encoding.UTF8.GetString(buffer, 0, read);
            yield return new CliStreamEvent(CliStreamEventKind.Stdout, chunk);
        }

        yield return new CliStreamEvent(CliStreamEventKind.System, "session complete\n");
    }
}