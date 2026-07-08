using System.Linq;
using OpenBurnBar.Integrations.HomeAssistant.Rest;
using Xunit;

namespace OpenBurnBar.Integrations.Tests;

public class HomeAssistantStateProjectionTests
{
    private static System.Collections.Generic.IReadOnlyList<OpenBurnBar.Integrations.HomeAssistant.Models.HaMediaPlayer> ProjectFixture()
    {
        var states = HomeAssistantStateProjection.DecodeStates(Fixtures.Load("ha_states.json"));
        return HomeAssistantStateProjection.ProjectMediaPlayers(states);
    }

    [Fact]
    public void Decode_ParsesEntitiesAndFiltersToMediaPlayers()
    {
        var states = HomeAssistantStateProjection.DecodeStates(Fixtures.Load("ha_states.json"));
        Assert.Equal(7, states.Count);
        var mediaPlayers = HomeAssistantStateProjection.ProjectMediaPlayers(states);
        Assert.Equal(5, mediaPlayers.Count);
        Assert.DoesNotContain(mediaPlayers, p => p.EntityId.StartsWith("light."));
        Assert.DoesNotContain(mediaPlayers, p => p.EntityId.StartsWith("sensor."));
    }

    [Fact]
    public void Projection_SortsCastableFirstThenFriendlyName()
    {
        var players = ProjectFixture();
        var order = players.Select(p => p.FriendlyName).ToArray();
        Assert.Equal(
            new[] { "Aux Amp", "Chromecast TV", "Living Room Nest Hub", "Office Speaker", "spare_no_name" },
            order);
    }

    [Fact]
    public void NumericSupportedFeatures_ParsesToZero_ParityWithSwift()
    {
        // Numeric supported_features (152461) stringifies to "152461.0", which
        // Int(...) rejects -> 0 on both platforms; castability comes only from the
        // keyword haystack here.
        var nest = ProjectFixture().Single(p => p.EntityId == "media_player.living_room_nest_hub");
        Assert.Equal(0, nest.SupportedFeatures);
        Assert.True(nest.SupportsCast); // "nest hub" keyword
    }

    [Fact]
    public void StringSupportedFeatures_HitsPlayMediaBitmask()
    {
        // A STRING "512" parses to 512, so the PLAY_MEDIA bit makes it castable
        // even with no Cast keyword in the name.
        var aux = ProjectFixture().Single(p => p.EntityId == "media_player.play_media_only");
        Assert.Equal(512, aux.SupportedFeatures);
        Assert.True(aux.SupportsCast);
    }

    [Fact]
    public void NonCastable_WithoutKeywordOrBitmask()
    {
        var office = ProjectFixture().Single(p => p.EntityId == "media_player.office_speaker");
        Assert.False(office.SupportsCast);
    }

    [Fact]
    public void MissingFriendlyName_FallsBackToEntitySuffix()
    {
        var spare = ProjectFixture().Single(p => p.EntityId == "media_player.spare_no_name");
        Assert.Equal("spare_no_name", spare.FriendlyName);
        Assert.False(spare.SupportsCast);
    }

    [Fact]
    public void ModelName_IsProjectedFromAttributes()
    {
        var nest = ProjectFixture().Single(p => p.EntityId == "media_player.living_room_nest_hub");
        Assert.Equal("Google Nest Hub", nest.Model);
    }

    [Fact]
    public void EntityLooksCastable_HonorsBitmask()
    {
        Assert.True(HomeAssistantStateProjection.EntityLooksCastable("media_player.x", "X", null, 0x200));
        Assert.False(HomeAssistantStateProjection.EntityLooksCastable("media_player.x", "Plain", null, 0));
    }

    [Theory]
    [InlineData("chromecast")]
    [InlineData("nest hub")]
    [InlineData("google tv")]
    [InlineData("nest audio")]
    public void EntityLooksCastable_HonorsKeywords(string keyword)
    {
        Assert.True(HomeAssistantStateProjection.EntityLooksCastable("media_player.x", "Living " + keyword, null, 0));
    }

    [Fact]
    public void BestMatch_PrefersNameMatch()
    {
        var players = ProjectFixture();
        var best = HomeAssistantStateProjection.BestMatch(players, "Nest Hub");
        Assert.NotNull(best);
        Assert.Equal("media_player.living_room_nest_hub", best!.EntityId);
    }

    [Fact]
    public void BestMatch_EmptyNeedle_ReturnsFirstCastable()
    {
        var players = ProjectFixture();
        var best = HomeAssistantStateProjection.BestMatch(players, "");
        Assert.NotNull(best);
        Assert.True(best!.SupportsCast);
        Assert.Equal("Aux Amp", best.FriendlyName); // first castable in sorted order
    }

    [Fact]
    public void Decode_MalformedJson_ThrowsDecoding()
    {
        var ex = Assert.Throws<HomeAssistantClientException>(() => HomeAssistantStateProjection.DecodeStates("{ not an array"));
        Assert.Equal(HomeAssistantClientErrorKind.Decoding, ex.Kind);
    }

    [Fact]
    public void Decode_NonArrayJson_ThrowsDecoding()
    {
        var ex = Assert.Throws<HomeAssistantClientException>(() => HomeAssistantStateProjection.DecodeStates("{\"a\":1}"));
        Assert.Equal(HomeAssistantClientErrorKind.Decoding, ex.Kind);
    }
}
