using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;

namespace OpenBurnBar.App.CursorConnector;

// ── Usage-event normalizer ───────────────────────────────────────────────────
//
// Faithful Windows peer of CursorConnectorManager.normalizeUsageEvent (+
// firstIntValue / nestedValue / parseInt). This is the connector's token-bucket
// reconciliation: it accepts a single JSONL usage record (any of the many
// provider spellings — snake/camel, OpenAI/Anthropic details objects) and returns
// canonical prompt / completion / cache-creation / cache-read / reasoning / total
// buckets. The VAL-TOKEN-004/006 gating (normalize from total_tokens vs.
// character-estimate fallback; reasoning kept as its own bucket) is preserved
// exactly, including Swift's away-from-zero rounding and ceil.

/// <summary>Swift <c>NormalizedUsageEvent</c>.</summary>
public readonly record struct NormalizedUsageEvent(
    int PromptTokens,
    int CompletionTokens,
    int CacheCreationTokens,
    int CacheReadTokens,
    int ReasoningTokens,
    int TotalTokens)
{
    /// <summary>True when every explicit bucket is zero/absent.</summary>
    public bool HasNoExplicitBuckets =>
        PromptTokens == 0
        && CompletionTokens == 0
        && CacheCreationTokens == 0
        && CacheReadTokens == 0
        && ReasoningTokens == 0;

    /// <summary>True when a primary bucket (prompt or completion) is explicitly present.</summary>
    public bool HasExplicitPrimaryBucket => PromptTokens > 0 || CompletionTokens > 0;
}

/// <summary>Reconciles a raw usage record into canonical token buckets.</summary>
public static class UsageEventNormalizer
{
    /// <summary>Swift <c>normalizeUsageEvent(_:)</c>.</summary>
    public static NormalizedUsageEvent Normalize(JsonElement json)
    {
        var prompt = FirstIntValue(json, new[]
        {
            new[] { "prompt_tokens" },
            new[] { "input_tokens" },
            new[] { "promptTokens" },
            new[] { "inputTokens" },
        }) ?? 0;

        var completion = FirstIntValue(json, new[]
        {
            new[] { "completion_tokens" },
            new[] { "output_tokens" },
            new[] { "completionTokens" },
            new[] { "outputTokens" },
        }) ?? 0;

        var cacheCreation = FirstIntValue(json, new[]
        {
            new[] { "cache_creation_input_tokens" },
            new[] { "cache_creation_tokens" },
            new[] { "cacheCreationTokens" },
        }) ?? 0;

        var exclusiveCacheRead = FirstIntValue(json, new[]
        {
            new[] { "cache_read_tokens" },
            new[] { "cache_read_input_tokens" },
            new[] { "cacheReadTokens" },
        }) ?? 0;

        var inclusiveCacheRead = FirstIntValue(json, new[]
        {
            new[] { "input_cached_tokens" },
            new[] { "inputCachedTokens" },
            new[] { "prompt_tokens_details", "cached_tokens" },
            new[] { "promptTokensDetails", "cachedTokens" },
            new[] { "input_tokens_details", "cached_tokens" },
            new[] { "inputTokensDetails", "cachedTokens" },
            new[] { "cached_tokens" },
            new[] { "cachedTokens" },
            new[] { "cached_input_tokens" },
            new[] { "cachedInputTokens" },
        }) ?? 0;

        var cacheRead = exclusiveCacheRead > 0 ? exclusiveCacheRead : inclusiveCacheRead;
        if (inclusiveCacheRead > 0 && exclusiveCacheRead == 0)
        {
            prompt = Math.Max(prompt - inclusiveCacheRead, 0);
        }

        // VAL-TOKEN-006: reasoning tokens from all known paths.
        var reasoningTokens = FirstIntValue(json, new[]
        {
            new[] { "thinking_tokens" },
            new[] { "reasoning_tokens" },
            new[] { "thinkingTokens" },
            new[] { "reasoningTokens" },
            new[] { "completion_tokens_details", "reasoning_tokens" },
            new[] { "output_tokens_details", "reasoning_tokens" },
        }) ?? 0;

        var total = FirstIntValue(json, new[]
        {
            new[] { "total_tokens" },
            new[] { "totalTokens" },
        }) ?? 0;

        var inputCharHint = FirstIntValue(json, new[]
        {
            new[] { "input_char_estimate" },
            new[] { "inputCharEstimate" },
        }) ?? 0;

        var outputCharHint = FirstIntValue(json, new[]
        {
            new[] { "output_char_estimate" },
            new[] { "outputCharEstimate" },
        }) ?? 0;

        var explicitTotal = prompt + completion + cacheCreation + cacheRead;
        var normalizedTotal = Math.Max(total, explicitTotal);

        if (normalizedTotal > 0)
        {
            // Normalization: derive missing primary buckets from total_tokens.
            var availableForInOut = Math.Max(normalizedTotal - cacheCreation - cacheRead - reasoningTokens, 0);
            if (prompt == 0 && completion == 0 && availableForInOut > 0)
            {
                var combinedHintChars = inputCharHint + outputCharHint;
                var inputRatio = combinedHintChars > 0
                    ? (double)inputCharHint / combinedHintChars
                    : 0.62;
                prompt = (int)Math.Round(availableForInOut * inputRatio, MidpointRounding.AwayFromZero);
                completion = Math.Max(availableForInOut - prompt, 0);
            }
            else if (prompt == 0 && completion > 0 && availableForInOut > completion)
            {
                prompt = availableForInOut - completion;
            }
            else if (completion == 0 && prompt > 0 && availableForInOut > prompt)
            {
                completion = availableForInOut - prompt;
            }
            else if (prompt + completion < availableForInOut)
            {
                completion += availableForInOut - (prompt + completion);
            }
        }
        else if (prompt == 0
            && completion == 0
            && cacheCreation == 0
            && cacheRead == 0
            && reasoningTokens == 0
            && inputCharHint + outputCharHint > 0)
        {
            // Fallback: character-based estimation only when NO token data at all.
            if (inputCharHint > 0)
            {
                prompt = Math.Max((int)Math.Ceiling(inputCharHint / 3.35), 1);
            }

            if (outputCharHint > 0)
            {
                completion = Math.Max((int)Math.Ceiling(outputCharHint / 3.35), 1);
            }
        }

        return new NormalizedUsageEvent(
            Math.Max(prompt, 0),
            Math.Max(completion, 0),
            Math.Max(cacheCreation, 0),
            Math.Max(cacheRead, 0),
            Math.Max(reasoningTokens, 0),
            Math.Max(normalizedTotal, prompt + completion + cacheCreation + cacheRead));
    }

    /// <summary>Swift <c>firstIntValue(in:paths:)</c>.</summary>
    public static int? FirstIntValue(JsonElement dictionary, IReadOnlyList<string[]> paths)
    {
        foreach (var path in paths)
        {
            if (NestedValue(dictionary, path) is { } value && ParseInt(value) is { } intValue)
            {
                return intValue;
            }
        }

        return null;
    }

    /// <summary>Swift <c>nestedValue(in:path:)</c>.</summary>
    public static JsonElement? NestedValue(JsonElement dictionary, IReadOnlyList<string> path)
    {
        var cursor = dictionary;
        foreach (var key in path)
        {
            if (cursor.ValueKind != JsonValueKind.Object || !cursor.TryGetProperty(key, out var next))
            {
                return null;
            }

            cursor = next;
        }

        return cursor;
    }

    /// <summary>Swift <c>parseInt(_:)</c> — clamps negatives to 0; nil when unparseable.</summary>
    public static int? ParseInt(JsonElement? valueOrNull)
    {
        if (valueOrNull is not { } value)
        {
            return null;
        }

        switch (value.ValueKind)
        {
            case JsonValueKind.Number:
                if (value.TryGetInt64(out var longValue))
                {
                    return (int)Math.Max(longValue, 0);
                }

                if (value.TryGetDouble(out var doubleValue))
                {
                    return (int)Math.Max(Math.Round(doubleValue, MidpointRounding.AwayFromZero), 0);
                }

                return null;

            case JsonValueKind.String:
                var trimmed = (value.GetString() ?? string.Empty).Trim();
                if (int.TryParse(trimmed, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedInt))
                {
                    return Math.Max(parsedInt, 0);
                }

                if (double.TryParse(trimmed, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsedDouble))
                {
                    return (int)Math.Max(Math.Round(parsedDouble, MidpointRounding.AwayFromZero), 0);
                }

                return null;

            default:
                return null;
        }
    }
}
