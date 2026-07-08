using System;
using System.Linq;
using System.Threading.Tasks;
using System.Text.Json.Nodes;
using OpenBurnBar.Pretext;
using Xunit;

namespace OpenBurnBar.Pretext.Tests;

// Exercises the whole PretextEngine (handle cache, async plumbing, result parsing,
// shrink-wrap, error + readiness paths) against a deterministic in-memory host —
// no browser. This proves the bridge is wired method-for-method to the Swift engine.

public class PretextEngineTests
{
    // A deterministic stand-in for the JS method table. Geometry is fabricated but
    // stable so the engine's parsing + control flow are fully covered.
    private static Func<FakeRequest, FakeReply> BuildDispatcher()
    {
        var nextHandle = 100;
        return req =>
        {
            switch (req.Method)
            {
                case "prepare":
                case "prepareWithSegments":
                    return FakeReply.Success(new JsonObject { ["handle"] = nextHandle++ });

                case "prepareRichInline":
                    return FakeReply.Success(new JsonObject { ["handle"] = nextHandle++ });

                case "layout":
                {
                    var lh = req.Params["lineHeight"]!.GetValue<double>();
                    return FakeReply.Success(new JsonObject { ["height"] = lh * 2, ["lineCount"] = 2 });
                }

                case "layoutWithLines":
                {
                    var lh = req.Params["lineHeight"]!.GetValue<double>();
                    return FakeReply.Success(new JsonObject
                    {
                        ["height"] = lh * 2,
                        ["lineCount"] = 2,
                        ["lines"] = new JsonArray
                        {
                            new JsonObject { ["text"] = "first", ["width"] = 10.5 },
                            new JsonObject { ["text"] = "second", ["width"] = 20.25 },
                        },
                    });
                }

                case "measureLineStats":
                {
                    // Line count shrinks as width grows: boundary at 100px.
                    var w = req.Params["maxWidth"]!.GetValue<double>();
                    var count = w >= 100 ? 1 : 2;
                    return FakeReply.Success(new JsonObject { ["lineCount"] = count, ["maxLineWidth"] = 90.0 });
                }

                case "measureNaturalWidth":
                    return FakeReply.Success(new JsonObject { ["width"] = 123.5 });

                case "layoutRichInline":
                    return FakeReply.Success(new JsonObject
                    {
                        ["lines"] = new JsonArray
                        {
                            new JsonObject
                            {
                                ["width"] = 50.0,
                                ["fragments"] = new JsonArray
                                {
                                    new JsonObject { ["text"] = "Hi ", ["itemIndex"] = 0, ["gapBefore"] = 0.0 },
                                    new JsonObject { ["text"] = "@x", ["itemIndex"] = 1, ["gapBefore"] = 2.0 },
                                },
                            },
                        },
                    });

                case "releaseHandle":
                    return FakeReply.Success(new JsonObject { ["released"] = true });

                default:
                    return FakeReply.Failure("Unknown method: " + req.Method);
            }
        };
    }

    private static PretextEngine NewEngine(out FakePretextWebHost host, bool readyOnStart = true)
    {
        host = new FakePretextWebHost(BuildDispatcher()) { RaiseReadyOnStart = readyOnStart };
        return new PretextEngine(host);
    }

    [Fact]
    public async Task Prepare_then_layout_roundtrips()
    {
        using var engine = NewEngine(out _);
        var handle = await engine.PrepareAsync("hello", "16px Arial");
        var result = await engine.LayoutAsync(handle, maxWidth: 200, lineHeight: 22);
        Assert.Equal(44, result.Height);
        Assert.Equal(2, result.LineCount);
    }

    [Fact]
    public async Task LayoutWithLines_maps_every_line()
    {
        using var engine = NewEngine(out _);
        var handle = await engine.PrepareWithSegmentsAsync("hello world", "16px Arial");
        var result = await engine.LayoutWithLinesAsync(handle, maxWidth: 120, lineHeight: 20);
        Assert.Equal(2, result.LineCount);
        Assert.Equal(40, result.Height);
        Assert.Collection(result.Lines,
            l => { Assert.Equal("first", l.Text); Assert.Equal(10.5, l.Width); },
            l => { Assert.Equal("second", l.Text); Assert.Equal(20.25, l.Width); });
    }

    [Fact]
    public async Task MeasureNaturalWidth_and_lineStats_parse()
    {
        using var engine = NewEngine(out _);
        var handle = await engine.PrepareAsync("hi", "16px Arial");
        Assert.Equal(123.5, await engine.MeasureNaturalWidthAsync(handle));
        var stats = await engine.MeasureLineStatsAsync(handle, maxWidth: 80);
        Assert.Equal(2, stats.LineCount);
        Assert.Equal(90.0, stats.MaxLineWidth);
    }

    [Fact]
    public async Task Handle_cache_elides_duplicate_prepare()
    {
        using var engine = NewEngine(out var host);
        var a = await engine.PrepareAsync("same", "16px Arial");
        var b = await engine.PrepareAsync("same", "16px Arial");
        Assert.Equal(a, b);
        Assert.Equal(1, host.ObservedMethods.Count(m => m == "prepare"));
    }

    [Fact]
    public async Task Prepare_and_prepareWithSegments_use_separate_caches()
    {
        using var engine = NewEngine(out var host);
        await engine.PrepareAsync("same", "16px Arial");
        await engine.PrepareWithSegmentsAsync("same", "16px Arial");
        Assert.Equal(1, host.ObservedMethods.Count(m => m == "prepare"));
        Assert.Equal(1, host.ObservedMethods.Count(m => m == "prepareWithSegments"));
    }

    [Fact]
    public async Task Options_are_serialized_sparsely()
    {
        // Only non-null option keys ride the wire (mirrors Swift optionsJSON).
        JsonObject? seen = null;
        var host = new FakePretextWebHost(req =>
        {
            if (req.Method == "prepare")
            {
                seen = req.Params["options"] as JsonObject;
                return FakeReply.Success(new JsonObject { ["handle"] = 1 });
            }
            return FakeReply.Failure("no");
        });
        using var engine = new PretextEngine(host);
        await engine.PrepareAsync("t", "f", new PretextOptions
        {
            WhiteSpace = PretextOptions.WhiteSpaceMode.PreWrap,
            LetterSpacing = 1.5,
        });
        Assert.NotNull(seen);
        Assert.Equal("pre-wrap", seen!["whiteSpace"]!.GetValue<string>());
        Assert.Equal(1.5, seen["letterSpacing"]!.GetValue<double>());
        Assert.False(seen.ContainsKey("wordBreak")); // null -> omitted
    }

    [Fact]
    public async Task RichInline_roundtrips_fragments()
    {
        using var engine = NewEngine(out _);
        var handle = await engine.PrepareRichInlineAsync(new[]
        {
            new PretextRichInlineItem { Text = "Hi ", Font = "16px Arial" },
            new PretextRichInlineItem { Text = "@x", Font = "600 16px Arial", BreakNever = true, ExtraWidth = 8 },
        });
        var lines = await engine.LayoutRichInlineAsync(handle, maxWidth: 240);
        var line = Assert.Single(lines);
        Assert.Equal(50.0, line.Width);
        Assert.Collection(line.Fragments,
            f => { Assert.Equal(0, f.ItemIndex); Assert.Equal(0, f.GapBefore); },
            f => { Assert.Equal(1, f.ItemIndex); Assert.Equal(2.0, f.GapBefore); });
    }

    [Fact]
    public async Task Break_never_item_sends_break_never()
    {
        JsonArray? items = null;
        var host = new FakePretextWebHost(req =>
        {
            if (req.Method == "prepareRichInline")
            {
                items = req.Params["items"] as JsonArray;
                return FakeReply.Success(new JsonObject { ["handle"] = 1 });
            }
            return FakeReply.Failure("no");
        });
        using var engine = new PretextEngine(host);
        await engine.PrepareRichInlineAsync(new[]
        {
            new PretextRichInlineItem { Text = "chip", Font = "16px Arial", BreakNever = true, ExtraWidth = 8 },
        });
        Assert.NotNull(items);
        var first = items![0]!.AsObject();
        Assert.Equal("never", first["break"]!.GetValue<string>());
        Assert.Equal(8, first["extraWidth"]!.GetValue<double>());
    }

    [Fact]
    public async Task ShrinkWrap_bisects_to_the_width_boundary()
    {
        using var engine = NewEngine(out _);
        var handle = await engine.PrepareAsync("text", "16px Arial");
        var width = await engine.ShrinkWrapWidthAsync(handle, upper: 200, targetLines: 1);
        // Boundary is 100px (>=100 -> 1 line); bisection converges just above it.
        Assert.True(width >= 100 && width <= 101.5, $"width was {width}");
    }

    [Fact]
    public async Task Unknown_method_dispatcher_failure_throws()
    {
        var host = new FakePretextWebHost(_ => FakeReply.Failure("Unknown method: boom"));
        using var engine = new PretextEngine(host);
        var ex = await Assert.ThrowsAsync<PretextException>(
            () => engine.MeasureNaturalWidthAsync(new PretextHandle(1)));
        Assert.Contains("boom", ex.Message);
    }

    [Fact]
    public async Task ExecuteScript_failure_faults_the_call()
    {
        var host = new FakePretextWebHost(_ => FakeReply.Success(new JsonObject { ["width"] = 1.0 }))
        {
            ExecuteScriptThrows = new InvalidOperationException("webview crashed"),
        };
        using var engine = new PretextEngine(host);
        var ex = await Assert.ThrowsAsync<PretextException>(
            () => engine.MeasureNaturalWidthAsync(new PretextHandle(1)));
        Assert.Contains("webview crashed", ex.Message);
    }

    [Fact]
    public async Task Calls_block_until_ready_heartbeat()
    {
        using var engine = NewEngine(out var host, readyOnStart: false);
        var task = engine.MeasureNaturalWidthAsync(new PretextHandle(1));
        await Task.Delay(40);
        Assert.False(task.IsCompleted); // gated on readiness
        host.PostReady();
        Assert.Equal(123.5, await task);
    }

    [Fact]
    public async Task Dispose_faults_in_flight_and_future_calls()
    {
        var engine = NewEngine(out _, readyOnStart: false);
        var inflight = engine.MeasureNaturalWidthAsync(new PretextHandle(1));
        engine.Dispose();
        await Assert.ThrowsAnyAsync<Exception>(() => inflight);
    }
}
