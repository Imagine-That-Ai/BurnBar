using System.Collections.Generic;
using System.Threading;

namespace OpenBurnBar.App.Cli;

/// <summary>The kind of a streamed CLI event, used to color/label the rendered line.</summary>
public enum CliStreamEventKind
{
    /// <summary>Session lifecycle / shell metadata (dim).</summary>
    System,

    /// <summary>Normal stdout output.</summary>
    Stdout,

    /// <summary>Stderr / warnings (warn color).</summary>
    Stderr,

    /// <summary>A tool / function call the agent emitted (accent color).</summary>
    ToolCall,
}

/// <summary>One streamed line (or partial chunk) from a CLI agent session.</summary>
/// <param name="Kind">How to render the text.</param>
/// <param name="Text">The chunk. May be a partial line — the view appends within a line
/// until it sees a newline, mirroring how a real ConPTY stream arrives token-by-token.</param>
public readonly record struct CliStreamEvent(CliStreamEventKind Kind, string Text);

/// <summary>
/// A source of live CLI output. The spike wires the view to <see cref="StubCliStream"/>;
/// WINUI-017 / W1-W2 swap in a ConPTY-backed implementation that spawns the real
/// <c>claude</c> / <c>codex</c> process — the Windows equivalent of the macOS
/// <c>CLIProcessStreamRunner</c>. The interface is deliberately tiny (one async pull) so
/// the real and stub sources are drop-in interchangeable.
/// </summary>
public interface ICliStream
{
    /// <summary>Stream events until the session ends or <paramref name="cancellationToken"/> fires.</summary>
    IAsyncEnumerable<CliStreamEvent> ReadAsync(CancellationToken cancellationToken);
}
