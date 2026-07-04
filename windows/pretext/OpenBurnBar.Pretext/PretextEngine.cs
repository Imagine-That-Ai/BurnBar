using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Text.Json.Nodes;

namespace OpenBurnBar.Pretext;

// MARK: - Pretext Engine (C# peer of PretextEngine.swift)
//
// Drives a single offscreen web host (real: WebView2 on Windows; test: an
// in-memory fake) running the bundled Pretext shell. This is the C# translation
// of `OpenBurnBarCore/.../Pretext/PretextEngine.swift`, method-for-method:
//
//   Swift                               C#
//   ---------------------------------   -------------------------------------------
//   PretextEngine.shared                inject an IPretextWebHost (DI, not a global)
//   start()                             StartAsync()
//   awaitReady()                        AwaitReadyAsync()
//   prepare / prepareWithSegments       PrepareAsync / PrepareWithSegmentsAsync
//   layout / layoutWithLines            LayoutAsync / LayoutWithLinesAsync
//   measureLineStats                    MeasureLineStatsAsync
//   measureNaturalWidth                 MeasureNaturalWidthAsync
//   prepareRichInline / layoutRichInline PrepareRichInlineAsync / LayoutRichInlineAsync
//   release(_:)                         ReleaseAsync(...)
//   shrinkWrapWidth                     ShrinkWrapWidthAsync
//   call(_:params:)                     CallAsync(...)
//   callForHandle(_:params:)            CallForHandleAsync(...)
//   handleBridgeMessage(_:)             HandleBridgeMessage(...)
//   preparedCache / preparedSegmentsCache  _preparedCache / _preparedSegmentsCache
//
// The Swift engine is @MainActor-isolated; here shared mutable state is guarded by
// a lock and continuations run asynchronously so the WebView2 UI thread never
// deadlocks on a reply. The wire protocol + handle cache are otherwise identical.
public sealed class PretextEngine : IDisposable
{
    private readonly IPretextWebHost _host;
    private readonly object _gate = new();

    private int _nextRequestId = 1;
    private bool _didStartLoad;
    private bool _isReady;
    private bool _disposed;

    private readonly TaskCompletionSource<bool> _ready =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    private readonly Dictionary<int, TaskCompletionSource<JsonNode?>> _pending = new();

    // Cache of prepared-text handles keyed by their input contract — exactly like
    // the Swift `preparedCache` / `preparedSegmentsCache`.
    private readonly Dictionary<PreparedKey, PretextHandle> _preparedCache = new();
    private readonly Dictionary<PreparedKey, PretextHandle> _preparedSegmentsCache = new();

    private readonly record struct PreparedKey(string Text, string Font, PretextOptions Options);

    public PretextEngine(IPretextWebHost host)
    {
        _host = host ?? throw new ArgumentNullException(nameof(host));
        _host.WebMessageReceived += HandleBridgeMessage;
    }

    // MARK: Start / readiness

    /// Kick off the shell load. Idempotent — safe to call from app start or the
    /// first call site, whichever comes first (mirrors Swift `start()`).
    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            if (_didStartLoad)
            {
                return Task.CompletedTask;
            }
            _didStartLoad = true;
        }
        return _host.StartAsync(cancellationToken);
    }

    /// Block until the shell is fully loaded and Pretext is ready. Called implicitly
    /// by every public API (mirrors Swift `awaitReady()`).
    public async Task AwaitReadyAsync(CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            if (_isReady)
            {
                return;
            }
        }
        await StartAsync(cancellationToken).ConfigureAwait(false);
        using (cancellationToken.CanBeCanceled
                   ? cancellationToken.Register(static s => ((TaskCompletionSource<bool>)s!).TrySetCanceled(), _ready)
                   : default)
        {
            await _ready.Task.ConfigureAwait(false);
        }
    }

    // MARK: Public API

    /// Returns a cached handle for (text, font, options). The underlying JS
    /// `PreparedText` is created exactly once per unique input.
    public async Task<PretextHandle> PrepareAsync(
        string text, string font, PretextOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var opts = options ?? PretextOptions.Normal;
        var key = new PreparedKey(text, font, opts);
        lock (_gate)
        {
            if (_preparedCache.TryGetValue(key, out var cached))
            {
                return cached;
            }
        }
        var handle = await CallForHandleAsync("prepare", PrepareParams(text, font, opts), cancellationToken)
            .ConfigureAwait(false);
        lock (_gate)
        {
            _preparedCache[key] = handle;
        }
        return handle;
    }

    /// `prepareWithSegments` — richer prep used by manual line layout.
    public async Task<PretextHandle> PrepareWithSegmentsAsync(
        string text, string font, PretextOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var opts = options ?? PretextOptions.Normal;
        var key = new PreparedKey(text, font, opts);
        lock (_gate)
        {
            if (_preparedSegmentsCache.TryGetValue(key, out var cached))
            {
                return cached;
            }
        }
        var handle = await CallForHandleAsync("prepareWithSegments", PrepareParams(text, font, opts), cancellationToken)
            .ConfigureAwait(false);
        lock (_gate)
        {
            _preparedSegmentsCache[key] = handle;
        }
        return handle;
    }

    /// `layout(prepared, maxWidth, lineHeight)` — paragraph height + lineCount.
    public async Task<PretextLayoutResult> LayoutAsync(
        PretextHandle handle, double maxWidth, double lineHeight,
        CancellationToken cancellationToken = default)
    {
        var value = await CallAsync("layout", new JsonObject
        {
            ["handle"] = handle.Id,
            ["maxWidth"] = maxWidth,
            ["lineHeight"] = lineHeight,
        }, cancellationToken).ConfigureAwait(false);
        var dict = value.AsObjectOrThrow();
        return new PretextLayoutResult(dict.RequireDouble("height"), dict.RequireInt("lineCount"));
    }

    /// `layoutWithLines(prepared, maxWidth, lineHeight)`.
    public async Task<PretextLinesResult> LayoutWithLinesAsync(
        PretextHandle handle, double maxWidth, double lineHeight,
        CancellationToken cancellationToken = default)
    {
        var value = await CallAsync("layoutWithLines", new JsonObject
        {
            ["handle"] = handle.Id,
            ["maxWidth"] = maxWidth,
            ["lineHeight"] = lineHeight,
        }, cancellationToken).ConfigureAwait(false);
        var dict = value.AsObjectOrThrow();
        var rawLines = dict.RequireArray("lines");
        var lines = new List<PretextLine>(rawLines.Count);
        foreach (var entry in rawLines)
        {
            if (entry is JsonObject lineObj)
            {
                lines.Add(new PretextLine(lineObj.RequireString("text"), lineObj.RequireDouble("width")));
            }
        }
        return new PretextLinesResult(dict.RequireDouble("height"), dict.RequireInt("lineCount"), lines);
    }

    /// `measureLineStats(prepared, maxWidth)`.
    public async Task<PretextLineStats> MeasureLineStatsAsync(
        PretextHandle handle, double maxWidth,
        CancellationToken cancellationToken = default)
    {
        var value = await CallAsync("measureLineStats", new JsonObject
        {
            ["handle"] = handle.Id,
            ["maxWidth"] = maxWidth,
        }, cancellationToken).ConfigureAwait(false);
        var dict = value.AsObjectOrThrow();
        return new PretextLineStats(dict.RequireInt("lineCount"), dict.RequireDouble("maxLineWidth"));
    }

    /// `measureNaturalWidth(prepared)` — widest forced line when width itself isn't
    /// causing wraps.
    public async Task<double> MeasureNaturalWidthAsync(
        PretextHandle handle, CancellationToken cancellationToken = default)
    {
        var value = await CallAsync("measureNaturalWidth", new JsonObject
        {
            ["handle"] = handle.Id,
        }, cancellationToken).ConfigureAwait(false);
        return value.AsObjectOrThrow().RequireDouble("width");
    }

    /// `prepareRichInline(items)` for mixed-font inline layout.
    public async Task<PretextRichHandle> PrepareRichInlineAsync(
        IReadOnlyList<PretextRichInlineItem> items,
        CancellationToken cancellationToken = default)
    {
        var payload = new JsonArray();
        foreach (var item in items)
        {
            var entry = new JsonObject
            {
                ["text"] = item.Text,
                ["font"] = item.Font,
                ["extraWidth"] = item.ExtraWidth,
            };
            if (item.BreakNever)
            {
                entry["break"] = "never";
            }
            payload.Add(entry);
        }
        var value = await CallAsync("prepareRichInline", new JsonObject { ["items"] = payload }, cancellationToken)
            .ConfigureAwait(false);
        return new PretextRichHandle(value.AsObjectOrThrow().RequireInt("handle"));
    }

    /// Lay a prepared rich-inline run out at `maxWidth`. Returns one line per
    /// wrapped line; callers map fragment `itemIndex` back to their font/color.
    public async Task<IReadOnlyList<PretextRichLine>> LayoutRichInlineAsync(
        PretextRichHandle handle, double maxWidth,
        CancellationToken cancellationToken = default)
    {
        var value = await CallAsync("layoutRichInline", new JsonObject
        {
            ["handle"] = handle.Id,
            ["maxWidth"] = maxWidth,
        }, cancellationToken).ConfigureAwait(false);
        var rawLines = value.AsObjectOrThrow().RequireArray("lines");
        var result = new List<PretextRichLine>(rawLines.Count);
        foreach (var lineNode in rawLines)
        {
            if (lineNode is not JsonObject line)
            {
                continue;
            }
            var frags = line.RequireArray("fragments");
            var fragments = new List<PretextRichFragment>(frags.Count);
            foreach (var fragNode in frags)
            {
                if (fragNode is not JsonObject f)
                {
                    continue;
                }
                fragments.Add(new PretextRichFragment(
                    f.RequireString("text"),
                    f.RequireInt("itemIndex"),
                    f.OptionalDouble("gapBefore", 0)));
            }
            result.Add(new PretextRichLine(line.RequireDouble("width"), fragments));
        }
        return result;
    }

    /// Free the JS-side handle. Cached prepares keep theirs alive — only uncached
    /// one-off prepares need explicit release. Best-effort (errors swallowed), like
    /// the Swift `release(_:)`.
    public async Task ReleaseAsync(PretextHandle handle, CancellationToken cancellationToken = default)
    {
        try
        {
            await CallAsync("releaseHandle", new JsonObject { ["handle"] = handle.Id }, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (PretextException)
        {
            // best-effort
        }
    }

    public async Task ReleaseAsync(PretextRichHandle handle, CancellationToken cancellationToken = default)
    {
        try
        {
            await CallAsync("releaseHandle", new JsonObject { ["handle"] = handle.Id }, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (PretextException)
        {
            // best-effort
        }
    }

    // MARK: Convenience helpers

    /// Find the tightest container width (within [lower, upper]) that keeps the
    /// rendered line count &lt;= targetLines. Byte-for-byte port of Swift
    /// `shrinkWrapWidth` (same 24-iteration bisection, same &lt;=1px stop).
    public async Task<double> ShrinkWrapWidthAsync(
        PretextHandle handle, double upper, int targetLines, double lower = 16,
        CancellationToken cancellationToken = default)
    {
        var lo = Math.Max(lower, 1);
        var hi = Math.Max(upper, lo + 1);
        var upperStats = await MeasureLineStatsAsync(handle, hi, cancellationToken).ConfigureAwait(false);
        if (upperStats.LineCount > targetLines)
        {
            return hi;
        }
        for (var i = 0; i < 24; i++)
        {
            if (hi - lo <= 1)
            {
                break;
            }
            var mid = (lo + hi) / 2;
            var stats = await MeasureLineStatsAsync(handle, mid, cancellationToken).ConfigureAwait(false);
            if (stats.LineCount <= targetLines)
            {
                hi = mid;
            }
            else
            {
                lo = mid;
            }
        }
        return hi;
    }

    // MARK: Internal — bridge plumbing

    private void HandleBridgeMessage(string json)
    {
        var reply = PretextBridge.ParseReply(json);
        if (reply.Id < 0)
        {
            return; // malformed / unaddressable — nothing to resume.
        }

        if (reply.IsReady)
        {
            lock (_gate)
            {
                _isReady = true;
            }
            _ready.TrySetResult(true);
            return;
        }

        TaskCompletionSource<JsonNode?>? cont;
        lock (_gate)
        {
            if (!_pending.Remove(reply.Id, out cont))
            {
                return;
            }
        }

        if (reply.Ok)
        {
            cont!.TrySetResult(reply.Value);
        }
        else
        {
            cont!.TrySetException(PretextException.Bridge(reply.Error ?? "unknown"));
        }
    }

    private async Task<JsonNode?> CallAsync(string method, JsonObject @params, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await AwaitReadyAsync(cancellationToken).ConfigureAwait(false);

        int id;
        var tcs = new TaskCompletionSource<JsonNode?>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_gate)
        {
            id = _nextRequestId++;
            _pending[id] = tcs;
        }

        var script = PretextBridge.BuildDispatchScript(id, method, @params);
        try
        {
            await _host.ExecuteScriptAsync(script, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            if (RemovePending(id))
            {
                tcs.TrySetException(PretextException.Bridge(ex.Message));
            }
        }

        using (cancellationToken.CanBeCanceled
                   ? cancellationToken.Register(() =>
                   {
                       if (RemovePending(id))
                       {
                           tcs.TrySetCanceled(cancellationToken);
                       }
                   })
                   : default)
        {
            return await tcs.Task.ConfigureAwait(false);
        }
    }

    private async Task<PretextHandle> CallForHandleAsync(string method, JsonObject @params, CancellationToken cancellationToken)
    {
        var value = await CallAsync(method, @params, cancellationToken).ConfigureAwait(false);
        return new PretextHandle(value.AsObjectOrThrow().RequireInt("handle"));
    }

    private bool RemovePending(int id)
    {
        lock (_gate)
        {
            return _pending.Remove(id);
        }
    }

    private static JsonObject PrepareParams(string text, string font, PretextOptions options)
    {
        return new JsonObject
        {
            ["text"] = text,
            ["font"] = font,
            ["options"] = OptionsToJson(options),
        };
    }

    /// Emit the sparse `{ whiteSpace?, wordBreak?, letterSpacing? }` object the JS
    /// side reads (mirrors Swift `optionsJSON(_:)`). Always present as an object,
    /// possibly empty, exactly like the Swift engine.
    private static JsonObject OptionsToJson(PretextOptions options)
    {
        var obj = new JsonObject();
        if (options.WhiteSpace is { } ws)
        {
            obj["whiteSpace"] = PretextOptions.ToCssValue(ws);
        }
        if (options.WordBreak is { } wb)
        {
            obj["wordBreak"] = PretextOptions.ToCssValue(wb);
        }
        if (options.LetterSpacing is { } ls)
        {
            obj["letterSpacing"] = ls;
        }
        return obj;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _host.WebMessageReceived -= HandleBridgeMessage;

        List<TaskCompletionSource<JsonNode?>> pending;
        lock (_gate)
        {
            pending = new List<TaskCompletionSource<JsonNode?>>(_pending.Values);
            _pending.Clear();
        }
        foreach (var tcs in pending)
        {
            tcs.TrySetException(PretextException.EngineUnavailable());
        }
        _ready.TrySetException(PretextException.EngineUnavailable());
    }
}
