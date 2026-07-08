using System;
using System.Text;

namespace OpenBurnBar.App.CursorConnector;

// ── Log-stream manager ───────────────────────────────────────────────────────
//
// Faithful Windows peer of AgentLens/Services/CursorConnector/
// CursorConnectorLogStreamManager.swift. The Swift type is an `actor` holding two
// independent read offsets (usage-log tail + proxy-route-log tail) and returning
// only the *delta* appended since the last read. Behaviour mirrored exactly:
//
//   • a missing file yields null (no offset change);
//   • a truncation (offset past the current length — e.g. the proxy rotated its
//     log) resets that offset to 0 so the reader re-reads from the top;
//   • the offset advances by the raw byte count read, not the decoded char count;
//   • empty reads and non-UTF8/empty decodes yield null.
//
// The Swift actor serialises access; here a lock gives the same single-reader
// guarantee. File access rides ILogStreamSource so the tail is provable against
// recorded fixtures without a live file handle.

/// <summary>Tails Cursor connector logs, returning only newly-appended text.</summary>
public sealed class CursorConnectorLogStreamManager
{
    private readonly ILogStreamSource _source;
    private readonly object _gate = new();
    private long _usageReadOffset;
    private long _routeReadOffset;

    /// <summary>Creates a manager over the given stream source.</summary>
    public CursorConnectorLogStreamManager(ILogStreamSource source)
    {
        _source = source ?? throw new ArgumentNullException(nameof(source));
    }

    /// <summary>Swift <c>resetOffsets()</c>.</summary>
    public void ResetOffsets()
    {
        lock (_gate)
        {
            _usageReadOffset = 0;
            _routeReadOffset = 0;
        }
    }

    /// <summary>Swift <c>readRouteDelta(from:)</c>.</summary>
    public string? ReadRouteDelta(string path)
    {
        lock (_gate)
        {
            return ReadDelta(path, ref _routeReadOffset);
        }
    }

    /// <summary>Swift <c>readUsageDelta(from:)</c>.</summary>
    public string? ReadUsageDelta(string path)
    {
        lock (_gate)
        {
            return ReadDelta(path, ref _usageReadOffset);
        }
    }

    private string? ReadDelta(string path, ref long offset)
    {
        if (!_source.Exists(path))
        {
            return null;
        }

        var size = _source.Length(path);
        if (size is { } length && offset > length)
        {
            // The file shrank underneath us (rotation/truncation): re-read from 0.
            offset = 0;
        }

        var data = _source.ReadFrom(path, offset);
        offset += data.Length;

        if (data.Length == 0)
        {
            return null;
        }

        // Swift decodes with .utf8 and treats a decode failure OR an empty string
        // as "no delta". C# UTF8 decoding is lenient (replacement chars) rather
        // than failing, so mirror the *observable* contract: empty → null.
        var text = Encoding.UTF8.GetString(data);
        return text.Length == 0 ? null : text;
    }
}
