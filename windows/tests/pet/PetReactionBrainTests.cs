using System.Collections.Generic;
using OpenBurnBar.App.Pet.Reaction;
using Xunit;

namespace OpenBurnBar.App.Pet.Tests;

public sealed class PetReactionBrainTests
{
    private static IReadOnlySet<string> Clips(params string[] names) =>
        new HashSet<string>(names, System.StringComparer.Ordinal);

    // ── classifyMessage ──────────────────────────────────────────────────────────

    [Theory]
    [InlineData("", PetMessageIntent.Neutral)]
    [InlineData("what is this?", PetMessageIntent.Question)]
    [InlineData("How does it work", PetMessageIntent.Question)]
    [InlineData("can you help", PetMessageIntent.Question)]
    [InlineData("thanks, that's perfect", PetMessageIntent.Praise)]
    [InlineData("you are useless", PetMessageIntent.Hostile)]
    [InlineData("go away", PetMessageIntent.Dismiss)]
    [InlineData("no, stop", PetMessageIntent.Negate)]
    [InlineData("the sky is blue", PetMessageIntent.Neutral)]
    public void ClassifyMessage_MatchesSwiftLadder(string text, PetMessageIntent expected)
    {
        Assert.Equal(expected, PetReactionBrain.ClassifyMessage(text));
    }

    [Fact]
    public void HostileBeatsPraise_OrderMatters()
    {
        // "hate you" is hostile even though other words might look neutral.
        Assert.Equal(PetMessageIntent.Hostile, PetReactionBrain.ClassifyMessage("I hate you"));
    }

    // ── pickReaction ─────────────────────────────────────────────────────────────

    [Fact]
    public void NoClips_ReturnsNull()
    {
        var senses = new PetReactionSenses { AvailableClips = Clips() };
        Assert.Null(PetReactionBrain.PickReaction(senses));
    }

    [Fact]
    public void FreshQuestion_PicksThink()
    {
        var senses = new PetReactionSenses
        {
            AvailableClips = Clips("idle", "think", "confused"),
            LastIntent = PetMessageIntent.Question,
            LastIntentAge = 1,
        };
        Assert.Equal("think", PetReactionBrain.PickReaction(senses));
    }

    [Fact]
    public void FreshBigWin_PicksVictory()
    {
        var senses = new PetReactionSenses
        {
            AvailableClips = Clips("idle", "victory", "cheer"),
            LastOutcome = PetTaskOutcome.BigWin,
            LastOutcomeAge = 2,
        };
        Assert.Equal("victory", PetReactionBrain.PickReaction(senses));
    }

    [Fact]
    public void EscalatedHostile_PrefersStomp()
    {
        var senses = new PetReactionSenses
        {
            AvailableClips = Clips("idle", "stomp", "offended", "flinch", "sad"),
            LastIntent = PetMessageIntent.Hostile,
            LastIntentAge = 1,
            RepeatedIntentCount = 2,
        };
        Assert.Equal("stomp", PetReactionBrain.PickReaction(senses));
    }

    [Fact]
    public void AgentBusy_PicksThink()
    {
        var senses = new PetReactionSenses
        {
            AvailableClips = Clips("idle", "think"),
            AgentBusy = true,
        };
        Assert.Equal("think", PetReactionBrain.PickReaction(senses));
    }

    [Fact]
    public void MissingPreferredClip_FallsBackToIdle()
    {
        var senses = new PetReactionSenses
        {
            AvailableClips = Clips("idle"),
            LastIntent = PetMessageIntent.Praise, // wants cheer/bow/wave, none present
            LastIntentAge = 1,
        };
        Assert.Equal("idle", PetReactionBrain.PickReaction(senses));
    }

    [Fact]
    public void LongIdle_Sleeps()
    {
        var senses = new PetReactionSenses
        {
            AvailableClips = Clips("idle", "sleep", "doze"),
            SinceInteraction = 200, // >= sleepAt (180 day)
            AppFocused = true,
            TimeOfDayHour = 12,
        };
        Assert.Equal("sleep", PetReactionBrain.PickReaction(senses));
    }
}
