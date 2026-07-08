using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Pet.Reaction;

// MARK: - Pet reaction brain
//
// C# peer of `AgentLens/PetCompanion/Core/PetReactionBrain.swift`.
//
// Vocabulary-only: consumes senses and the set of available semantic clip names,
// then returns one clip/state name (or null). This is the single swap point when
// the shared `petcore` reaction contract lands a generated surface. The priority
// ladder and clip-preference lists are ported verbatim so the desktop pet reacts
// identically to the macOS companion and the web NPC.

public enum PetMessageIntent
{
    Neutral,
    Question,
    Praise,
    Hostile,
    Dismiss,
    Negate,
    Confused,
}

public enum PetTaskOutcome
{
    NormalReply,
    Success,
    BigWin,
    Failure,
    HardError,
}

/// The sensory snapshot the reaction brain reads (peer of `PetReactionSenses`).
/// Times are in seconds. <see cref="AvailableClips"/> is the set of clip names the
/// loaded pet actually has, so the brain only ever returns a playable clip.
public sealed class PetReactionSenses
{
    public required IReadOnlySet<string> AvailableClips { get; init; }
    public double SinceInteraction { get; init; }
    public bool UserTyping { get; init; }
    public bool AgentBusy { get; init; }
    public bool AppFocused { get; init; } = true;
    public bool OsIdle { get; init; }
    public bool PointerNear { get; init; }
    public PetMessageIntent? LastIntent { get; init; }
    public double? LastIntentAge { get; init; }
    public int RepeatedIntentCount { get; init; }
    public PetTaskOutcome? LastOutcome { get; init; }
    public double? LastOutcomeAge { get; init; }
    public int TimeOfDayHour { get; init; }
    public bool WasSleeping { get; init; }
    public bool AmbientPulse { get; init; }
}

/// The pure reaction picker + message classifier.
public static class PetReactionBrain
{
    /// Choose the clip that best fits the current senses, or null when nothing
    /// applies (peer of `pickReaction`). The priority ladder is verbatim from the
    /// Swift source.
    public static string? PickReaction(PetReactionSenses senses)
    {
        if (senses is null)
        {
            throw new ArgumentNullException(nameof(senses));
        }
        var clips = senses.AvailableClips;
        if (clips.Count == 0)
        {
            return null;
        }

        if (senses.WasSleeping && IsFresh(senses.LastIntentAge, within: 3))
        {
            return Choose(new[] { "excited", "wave", "standUp", "idle" }, clips);
        }

        if (senses.LastIntent is { } intent && IsFresh(senses.LastIntentAge, within: 8))
        {
            switch (intent)
            {
                case PetMessageIntent.Question:
                    return Choose(new[] { "think", "confused", "idle" }, clips);
                case PetMessageIntent.Praise:
                    return Choose(new[] { "cheer", "bow", "wave", "idle" }, clips);
                case PetMessageIntent.Hostile:
                {
                    var escalated = senses.RepeatedIntentCount > 1;
                    return Choose(
                        escalated
                            ? new[] { "stomp", "flinch", "offended", "sad", "idle" }
                            : new[] { "offended", "flinch", "stomp", "idle" },
                        clips);
                }
                case PetMessageIntent.Dismiss:
                    return Choose(new[] { "retreat", "sleep", "doze", "idle" }, clips);
                case PetMessageIntent.Negate:
                    return Choose(new[] { "no", "shrug", "idle" }, clips);
                case PetMessageIntent.Confused:
                    return Choose(new[] { "confused", "shrug", "idle" }, clips);
                case PetMessageIntent.Neutral:
                    break;
            }
        }

        if (senses.AgentBusy)
        {
            return Choose(new[] { "think", "confused", "idle" }, clips);
        }

        if (senses.UserTyping)
        {
            return Choose(new[] { "listen", "idle" }, clips);
        }

        if (senses.LastOutcome is { } outcome && IsFresh(senses.LastOutcomeAge, within: 8))
        {
            switch (outcome)
            {
                case PetTaskOutcome.NormalReply:
                    return Choose(new[] { "nod", "wave", "idle" }, clips);
                case PetTaskOutcome.Success:
                    return Choose(new[] { "cheer", "victory", "celebrate", "clap", "idle" }, clips);
                case PetTaskOutcome.BigWin:
                    return Choose(new[] { "victory", "dance", "celebrate", "taunt", "cheer", "idle" }, clips);
                case PetTaskOutcome.Failure:
                    return Choose(new[] { "sad", "confused", "shrug", "idle" }, clips);
                case PetTaskOutcome.HardError:
                    return Choose(new[] { "zap", "flinch", "sad", "confused", "idle" }, clips);
            }
        }

        var night = senses.TimeOfDayHour >= 23 || senses.TimeOfDayHour < 6;
        double dozeAt = night ? 45 : 60;
        double sleepAt = night ? 120 : 180;
        double retreatAt = night ? 240 : 300;

        if (senses.OsIdle || !senses.AppFocused)
        {
            if (senses.SinceInteraction >= dozeAt)
            {
                return Choose(new[] { "sleep", "doze", "sitDown", "idle" }, clips);
            }
            return Choose(new[] { "doze", "sleep", "idle" }, clips);
        }

        if (senses.PointerNear && senses.SinceInteraction > 8)
        {
            return Choose(new[] { "lookAround", "listen", "wave", "idle" }, clips);
        }

        if (senses.SinceInteraction >= retreatAt)
        {
            return Choose(new[] { "retreat", "wander", "sleep", "idle" }, clips);
        }
        if (senses.SinceInteraction >= sleepAt)
        {
            return Choose(new[] { "sleep", "doze", "idle" }, clips);
        }
        if (senses.SinceInteraction >= dozeAt)
        {
            return Choose(new[] { "doze", "stretch", "idle" }, clips);
        }

        if (senses.AmbientPulse && senses.SinceInteraction >= 20)
        {
            var morning = senses.TimeOfDayHour >= 6 && senses.TimeOfDayHour <= 10;
            return Choose(
                morning
                    ? new[] { "excited", "stretch", "idleVar", "lookAround", "idle" }
                    : new[] { "idleVar", "stretch", "lookAround", "sip", "vanity", "idle" },
                clips);
        }

        return null;
    }

    /// Classify a chat message into a coarse intent (peer of `classifyMessage`).
    public static PetMessageIntent ClassifyMessage(string? text)
    {
        var normalized = (text ?? string.Empty).Trim().ToLowerInvariant();
        if (normalized.Length == 0)
        {
            return PetMessageIntent.Neutral;
        }

        if (ContainsAny(normalized, new[]
        {
            "fuck off", "f*** off", "shut up", "stupid", "idiot", "useless",
            "dumb", "hate you", "you suck", "trash",
        }))
        {
            return PetMessageIntent.Hostile;
        }

        if (ContainsAny(normalized, new[]
        {
            "go away", "leave", "dismiss", "bye", "goodbye", "go sleep",
            "leave me alone",
        }))
        {
            return PetMessageIntent.Dismiss;
        }

        if (ContainsAny(normalized, new[]
        {
            "thanks", "thank you", "nice", "good job", "great job", "well done",
            "love it", "perfect", "beautiful",
        }))
        {
            return PetMessageIntent.Praise;
        }

        var words = normalized
            .Split(WordSeparators, StringSplitOptions.RemoveEmptyEntries)
            .ToHashSet(StringComparer.Ordinal);
        if (words.Contains("wrong") || words.Contains("stop") || words.Contains("no")
            || normalized.Contains("don't") || normalized.Contains("dont"))
        {
            return PetMessageIntent.Negate;
        }

        if (normalized.EndsWith("?", StringComparison.Ordinal)
            || StartsWithAny(normalized, new[] { "who ", "what ", "why ", "how ", "when ", "where " })
            || ContainsAny(normalized, new[] { "can you", "could you", "would you", "do you" }))
        {
            return PetMessageIntent.Question;
        }

        return PetMessageIntent.Neutral;
    }

    private static readonly char[] WordSeparators = BuildWordSeparators();

    private static char[] BuildWordSeparators()
    {
        // Split on every non-alphanumeric char (peer of the Swift
        // `split { !$0.isLetter && !$0.isNumber }` over ASCII punctuation/space).
        var seps = new List<char>();
        for (var c = (char)0; c < 128; c++)
        {
            if (!char.IsLetterOrDigit(c))
            {
                seps.Add(c);
            }
        }
        return seps.ToArray();
    }

    private static bool IsFresh(double? age, double within)
    {
        if (age is not { } value)
        {
            return false;
        }
        return value >= 0 && value <= within;
    }

    // Return the first preferred candidate the pet actually has; else "idle"; else
    // the lexicographically smallest clip (peer of `choose`).
    private static string? Choose(IReadOnlyList<string> candidates, IReadOnlySet<string> clips)
    {
        foreach (var candidate in candidates)
        {
            if (clips.Contains(candidate))
            {
                return candidate;
            }
        }
        if (clips.Contains("idle"))
        {
            return "idle";
        }
        return clips.OrderBy(c => c, StringComparer.Ordinal).FirstOrDefault();
    }

    private static bool ContainsAny(string text, IReadOnlyList<string> needles)
    {
        foreach (var n in needles)
        {
            if (text.Contains(n, StringComparison.Ordinal))
            {
                return true;
            }
        }
        return false;
    }

    private static bool StartsWithAny(string text, IReadOnlyList<string> prefixes)
    {
        foreach (var p in prefixes)
        {
            if (text.StartsWith(p, StringComparison.Ordinal))
            {
                return true;
            }
        }
        return false;
    }
}
