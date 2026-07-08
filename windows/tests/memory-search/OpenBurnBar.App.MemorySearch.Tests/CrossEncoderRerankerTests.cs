using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.MemorySearch.Search;
using Xunit;

namespace OpenBurnBar.App.MemorySearch.Tests;

/// <summary>
/// Cross-encoder reranker scoring/ordering over a FAKE completion client. Swift:
/// <c>CrossEncoderPromptBuilder</c> (buildPrompt / parseScores / rerankedResults) +
/// the shared reranker logic.
/// </summary>
public sealed class CrossEncoderRerankerTests
{
    private sealed class FakeClient : ICrossEncoderCompletionClient
    {
        private readonly string _response;

        public string? LastSystemPrompt { get; private set; }

        public string? LastUserPrompt { get; private set; }

        public FakeClient(string response) => _response = response;

        public Task<string> CompleteAsync(string systemPrompt, string userPrompt, CancellationToken cancellationToken = default)
        {
            LastSystemPrompt = systemPrompt;
            LastUserPrompt = userPrompt;
            return Task.FromResult(_response);
        }
    }

    private static RetrievalResult Candidate(string chunkId, string title, string snippet) =>
        new(chunkId, "doc-" + chunkId, title, snippet, DateTimeOffset.UnixEpoch, 0);

    [Fact]
    public void BuildPrompt_NumbersPassagesFromOne_AndPrefersSnippet()
    {
        var payload = CrossEncoderPromptBuilder.BuildPrompt(
            "find memory",
            new[] { Candidate("a", "Alpha", "alpha snippet"), Candidate("b", "Beta", "") },
            512,
            40);

        Assert.NotNull(payload);
        Assert.Contains("User Query: find memory", payload!.UserPrompt);
        Assert.Contains("[1] Title: Alpha", payload.UserPrompt);
        Assert.Contains("[1] Content: alpha snippet", payload.UserPrompt);
        // Empty snippet falls back to the title text.
        Assert.Contains("[2] Content: Beta", payload.UserPrompt);
    }

    [Fact]
    public void BuildPrompt_EmptyQueryOrNoCandidates_ReturnsNull()
    {
        Assert.Null(CrossEncoderPromptBuilder.BuildPrompt("   ", new[] { Candidate("a", "A", "s") }, 512, 40));
        Assert.Null(CrossEncoderPromptBuilder.BuildPrompt("q", Array.Empty<RetrievalResult>(), 512, 40));
    }

    [Fact]
    public void ParseScores_StripsJsonFence_AndFiltersOutOfRange()
    {
        const string content = "```json\n[{\"chunk_id\":\"1\",\"relevance\":0.9},{\"chunk_id\":\"2\",\"relevance\":1.5},{\"chunk_id\":\"\",\"relevance\":0.5}]\n```";
        var scores = CrossEncoderPromptBuilder.ParseScores(content);
        // 1.5 is out of [0,1] and the empty chunk_id is dropped → only passage 1 survives.
        Assert.Single(scores);
        Assert.Equal("1", scores[0].ChunkId);
        Assert.Equal(0.9, scores[0].Relevance, 12);
    }

    [Fact]
    public void ParseScores_ExtractsArrayFromProseWrappedReply()
    {
        var scores = CrossEncoderPromptBuilder.ParseScores("Sure! [{\"chunk_id\":\"1\",\"relevance\":0.2}] done");
        Assert.Single(scores);
    }

    [Fact]
    public void ParseScores_NoArray_Throws()
    {
        Assert.Throws<CrossEncoderParseException>(() => CrossEncoderPromptBuilder.ParseScores("no json here"));
    }

    [Fact]
    public void RerankedResults_OrdersByRelevance_MissingScoreIsZero()
    {
        var scored = new[] { Candidate("a", "A", "s"), Candidate("b", "B", "s"), Candidate("c", "C", "s") };
        var scores = new[]
        {
            new CrossEncoderRelevanceScore("1", 0.2), // passage 1 = a
            new CrossEncoderRelevanceScore("3", 0.9), // passage 3 = c
            // passage 2 (b) omitted → treated as 0
        };

        var reranked = CrossEncoderPromptBuilder.RerankedResults(scores, scored, scored, 3, 40);
        Assert.Equal(new[] { "c", "a", "b" }, reranked.Select(r => r.ChunkId));
    }

    [Fact]
    public void RerankedResults_TieBreaksByOriginalIndex()
    {
        var scored = new[] { Candidate("a", "A", "s"), Candidate("b", "B", "s") };
        var scores = new[] { new CrossEncoderRelevanceScore("1", 0.5), new CrossEncoderRelevanceScore("2", 0.5) };

        var reranked = CrossEncoderPromptBuilder.RerankedResults(scores, scored, scored, 2, 40);
        Assert.Equal(new[] { "a", "b" }, reranked.Select(r => r.ChunkId));
    }

    [Fact]
    public void RerankedResults_AppendsCandidatesBeyondScoredWindowUnchanged()
    {
        var all = new[] { Candidate("a", "A", "s"), Candidate("b", "B", "s"), Candidate("c", "C", "s") };
        var scored = new[] { all[0], all[1] }; // window of 2 (maxCandidatesPerRequest = 2)
        var scores = new[] { new CrossEncoderRelevanceScore("2", 0.9), new CrossEncoderRelevanceScore("1", 0.1) };

        var reranked = CrossEncoderPromptBuilder.RerankedResults(scores, scored, all, 10, 2);
        // b, a reranked; c appended from the tail unchanged.
        Assert.Equal(new[] { "b", "a", "c" }, reranked.Select(r => r.ChunkId));
    }

    [Fact]
    public async Task Reranker_EndToEnd_WithFakeClient_ReordersByModelRelevance()
    {
        var client = new FakeClient("[{\"chunk_id\":\"1\",\"relevance\":0.1},{\"chunk_id\":\"2\",\"relevance\":0.99}]");
        var reranker = new CrossEncoderReranker(client);
        var candidates = new[] { Candidate("a", "A", "s"), Candidate("b", "B", "s") };

        var result = await reranker.RerankAsync("q", candidates, 10);
        Assert.Equal(new[] { "b", "a" }, result.Select(r => r.ChunkId));
        Assert.Equal(CrossEncoderPromptBuilder.BuildPrompt("q", candidates, 512, 40)!.SystemPrompt, client.LastSystemPrompt);
    }

    [Fact]
    public async Task Reranker_ParseFailure_FallsBackToPrefix()
    {
        var reranker = new CrossEncoderReranker(new FakeClient("garbage, no array"));
        var candidates = new[] { Candidate("a", "A", "s"), Candidate("b", "B", "s"), Candidate("c", "C", "s") };

        var result = await reranker.RerankAsync("q", candidates, 2);
        Assert.Equal(new[] { "a", "b" }, result.Select(r => r.ChunkId));
    }

    [Fact]
    public async Task NoOpReranker_ReturnsPrefixUnchanged()
    {
        var candidates = new[] { Candidate("a", "A", "s"), Candidate("b", "B", "s") };
        var result = await new NoOpRetrievalReranker().RerankAsync("q", candidates, 1);
        Assert.Equal(new[] { "a" }, result.Select(r => r.ChunkId));
    }
}
