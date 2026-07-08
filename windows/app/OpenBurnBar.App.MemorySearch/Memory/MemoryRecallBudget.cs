using System;
using System.Globalization;

namespace OpenBurnBar.App.MemorySearch.Memory;

// PORTED (faithful) from
//   AgentLens/Services/Memory/MemoryRecallBudget.swift
//   AgentLens/Services/ContextBuilder.swift          (PromptTokenArbiter.estimateProseTokens)
//   OpenBurnBarCore/.../LogParser/TokenExtractionUtility.swift (estimatedTokenCount)
//
// High-recall's lever is the LIMIT (how many distinct approved facts are eligible), NOT a larger
// token slice — the token budget tracks the arbiter's allocation in both modes.

/// <summary>Result of <see cref="MemoryRecallBudget.ForReply"/>. Peer of the Swift tuple.</summary>
public readonly record struct MemoryRecallBudgetResult(int Limit, int TokenBudget);

/// <summary>Maps the high-recall toggle to recall-request parameters. Swift: <c>enum MemoryRecallBudget</c>.</summary>
public static class MemoryRecallBudget
{
    /// <summary>Snippet limit when high-recall is off. Swift: <c>defaultLimit = 8</c>. Must match
    /// the <c>MemoryRecallRequest</c> default.</summary>
    public const int DefaultLimit = 8;

    /// <summary>Snippet limit when high-recall is on. Swift: <c>highRecallLimit = 16</c>.</summary>
    public const int HighRecallLimit = 16;

    /// <summary>Prose token ratio (~3.5 chars/token). Swift: <c>PromptTokenArbiter</c> prose ratio.</summary>
    public const double ProseCharsPerToken = 3.5;

    /// <summary>
    /// Per-snippet token cost of the untrusted-content wrapper envelope. Swift:
    /// <c>wrapperTokenOverhead</c> (a computed 202). Pinned here because the wrapper template
    /// (<c>LLMSafeContent.wrapUntrusted</c> + <c>criticalRule</c>) lives in the Core SharedModels
    /// safety utility, which is outside this memory-search core. Derivation:
    ///   worst-case provenance = "memory:" + 140×'x' (147 chars)
    ///   → the wrapUntrusted envelope of an empty body is 701 chars
    ///   → EstimateProseTokens(701) = ceil(701 / 3.5) = 201
    ///   → + 1 (the per-snippet "\n\n" join) = 202.
    /// A test pins <c>EstimateProseTokens(701) + 1 == 202</c>. If the Core template changes, this
    /// must be re-derived (a bucket-B wiring concern, since the wrap itself is not ported here).
    /// </summary>
    public const int WrapperTokenOverhead = 202;

    /// <summary>
    /// Returns <c>(limit, tokenBudget)</c> for a recall request. Swift:
    /// <c>forReply(arbiterBudget:highRecall:)</c>. <c>limit = highRecall ? 16 : 8</c>;
    /// <c>tokenBudget = max(arbiterBudget, 1)</c>.
    /// </summary>
    public static MemoryRecallBudgetResult ForReply(int arbiterBudget, bool highRecall)
    {
        int limit = highRecall ? HighRecallLimit : DefaultLimit;
        int tokenBudget = Math.Max(arbiterBudget, 1);
        return new MemoryRecallBudgetResult(limit, tokenBudget);
    }

    /// <summary>
    /// Estimated token count for a character count. Swift:
    /// <c>TokenExtractionUtility.estimatedTokenCount(for:charsPerToken:)</c>:
    /// <c>characters &lt;= 0 ? 0 : ceil(characters / charsPerToken)</c>.
    /// </summary>
    public static int EstimatedTokenCount(int characters, double charsPerToken)
    {
        if (characters <= 0)
        {
            return 0;
        }

        return (int)Math.Ceiling(characters / charsPerToken);
    }

    /// <summary>Estimated prose tokens for content (grapheme-count / 3.5, rounded up). Swift:
    /// <c>PromptTokenArbiter.estimateProseTokens(_:)</c>.</summary>
    public static int EstimateProseTokens(string content)
    {
        ArgumentNullException.ThrowIfNull(content);
        int characters = GraphemeCount(content);
        return EstimatedTokenCount(characters, ProseCharsPerToken);
    }

    private static int GraphemeCount(string value)
    {
        int count = 0;
        var enumerator = StringInfo.GetTextElementEnumerator(value);
        while (enumerator.MoveNext())
        {
            count++;
        }

        return count;
    }
}
