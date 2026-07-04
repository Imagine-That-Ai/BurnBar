using System.Collections.Generic;
using System.Threading;

namespace OpenBurnBar.B0Spike.Cli;

/// <summary>Spike-local mirror of <c>OpenBurnBar.App.Cli.ICliStream</c> (WinUI app is not referenced on macOS).</summary>
public enum CliStreamEventKind
{
    System,
    Stdout,
    Stderr,
    ToolCall,
}

public readonly record struct CliStreamEvent(CliStreamEventKind Kind, string Text);

public interface ICliStream
{
    IAsyncEnumerable<CliStreamEvent> ReadAsync(CancellationToken cancellationToken);
}