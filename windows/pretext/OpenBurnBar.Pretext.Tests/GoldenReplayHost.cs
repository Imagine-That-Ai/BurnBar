using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Text.Json.Nodes;
using OpenBurnBar.Pretext;
using OpenBurnBar.Pretext.MetricParity;

namespace OpenBurnBar.Pretext.Tests;

/// An <see cref="IPretextWebHost"/> that answers every measurement with the exact
/// Mac golden for the corresponding corpus case. Used to drive
/// <see cref="MetricParityRunner.MeasureAsync"/> end-to-end without a browser, so the
/// runner's method dispatch + result shaping + engine wiring are proven against real
/// captured numbers. The real Chromium measurement is the Windows live run.
public sealed class GoldenReplayHost : IPretextWebHost
{
    private readonly PretextCorpus _corpus;
    private readonly PretextGolden _golden;

    private readonly Dictionary<int, string> _handleToCaseId = new();
    private readonly HashSet<string> _consumed = new();
    private int _nextHandle = 1;

    public event Action<string>? WebMessageReceived;

    public GoldenReplayHost(PretextCorpus corpus, PretextGolden golden)
    {
        _corpus = corpus;
        _golden = golden;
    }

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        WebMessageReceived?.Invoke("{\"id\":0,\"ok\":true,\"value\":{\"ready\":true}}");
        return Task.CompletedTask;
    }

    public Task<string?> ExecuteScriptAsync(string script, CancellationToken cancellationToken = default)
    {
        var req = FakePretextWebHost.ParseDispatchScript(script);
        var value = Dispatch(req);
        var reply = new JsonObject { ["id"] = req.Id, ["ok"] = true, ["value"] = value };
        WebMessageReceived?.Invoke(reply.ToJsonString());
        return Task.FromResult<string?>(null);
    }

    private JsonNode Dispatch(FakeRequest req)
    {
        switch (req.Method)
        {
            case "prepare":
                return Handle(MatchPrepare(req, segments: false));
            case "prepareWithSegments":
                return Handle(MatchPrepare(req, segments: true));
            case "prepareRichInline":
                return Handle(MatchRich());
            case "releaseHandle":
                return new JsonObject { ["released"] = true };
            case "layout":
            case "layoutWithLines":
            case "measureLineStats":
            case "measureNaturalWidth":
            case "layoutRichInline":
                return GoldenFor(req);
            default:
                throw new InvalidOperationException($"GoldenReplayHost: unexpected method '{req.Method}'.");
        }
    }

    private JsonObject Handle(PretextCorpusCase c)
    {
        var id = _nextHandle++;
        _handleToCaseId[id] = c.Id;
        _consumed.Add(c.Id);
        return new JsonObject { ["handle"] = id };
    }

    private PretextCorpusCase MatchPrepare(FakeRequest req, bool segments)
    {
        var text = req.Params["text"]!.GetValue<string>();
        var font = req.Params["font"]!.GetValue<string>();
        bool Family(ParityMethod m) => segments
            ? m == ParityMethod.LayoutWithLines
            : m is ParityMethod.Layout or ParityMethod.MeasureLineStats or ParityMethod.MeasureNaturalWidth;

        return _corpus.Cases.FirstOrDefault(c =>
                   !_consumed.Contains(c.Id) && Family(c.ResolvedMethod) && c.Text == text && c.Font == font)
               ?? throw new InvalidOperationException($"No corpus case for prepare(segments={segments}) text='{text}'.");
    }

    private PretextCorpusCase MatchRich()
    {
        return _corpus.Cases.FirstOrDefault(c =>
                   !_consumed.Contains(c.Id) && c.ResolvedMethod == ParityMethod.LayoutRichInline)
               ?? throw new InvalidOperationException("No corpus case for prepareRichInline.");
    }

    private JsonObject GoldenFor(FakeRequest req)
    {
        var handleId = (int)req.Params["handle"]!.GetValue<double>();
        if (!_handleToCaseId.TryGetValue(handleId, out var caseId))
        {
            throw new InvalidOperationException($"GoldenReplayHost: unknown handle {handleId}.");
        }
        var g = _golden.Results[caseId];

        switch (req.Method)
        {
            case "layout":
                return new JsonObject { ["height"] = g.Height, ["lineCount"] = g.LineCount };
            case "layoutWithLines":
            {
                var lines = new JsonArray();
                var widths = g.LineWidths ?? new List<double>();
                var texts = g.LineTexts ?? new List<string>();
                for (var i = 0; i < widths.Count; i++)
                {
                    lines.Add(new JsonObject
                    {
                        ["text"] = i < texts.Count ? texts[i] : string.Empty,
                        ["width"] = widths[i],
                    });
                }
                return new JsonObject { ["height"] = g.Height, ["lineCount"] = g.LineCount, ["lines"] = lines };
            }
            case "measureLineStats":
                return new JsonObject { ["lineCount"] = g.LineCount, ["maxLineWidth"] = g.MaxLineWidth };
            case "measureNaturalWidth":
                return new JsonObject { ["width"] = g.Width };
            case "layoutRichInline":
            {
                var lines = new JsonArray();
                foreach (var w in g.LineWidths ?? new List<double>())
                {
                    lines.Add(new JsonObject { ["width"] = w, ["fragments"] = new JsonArray() });
                }
                return new JsonObject { ["lines"] = lines };
            }
            default:
                throw new InvalidOperationException($"GoldenReplayHost: unexpected measurement '{req.Method}'.");
        }
    }
}
