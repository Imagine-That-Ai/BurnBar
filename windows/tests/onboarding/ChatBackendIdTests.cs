using System.Linq;
using OpenBurnBar.App.Onboarding;
using OpenBurnBar.App.Theme;
using Xunit;

namespace OpenBurnBar.App.Onboarding.Tests;

/// <summary>
/// Parity tests for <see cref="ChatBackendId"/> — the settings-compatibility surface.
/// The raw string values + AllCases order + CSV round-trip must match the macOS
/// <c>ChatBackendID</c> so a wizard run persists tokens the macOS app can read back.
/// </summary>
public sealed class ChatBackendIdTests
{
    [Fact]
    public void AllCases_MatchSwiftOrder()
    {
        Assert.Equal(
            new[]
            {
                ChatBackendId.Codex,
                ChatBackendId.Claude,
                ChatBackendId.Hermes,
                ChatBackendId.PiAgent,
                ChatBackendId.OpenClaw,
                ChatBackendId.OpenClaude,
                ChatBackendId.Omp,
                ChatBackendId.Droid,
                ChatBackendId.Forge,
                ChatBackendId.Antigravity,
                ChatBackendId.CursorAgent,
            },
            ChatBackendMetadata.AllCases);
    }

    [Theory]
    [InlineData(ChatBackendId.Codex, "codex")]
    [InlineData(ChatBackendId.Claude, "claude")]
    [InlineData(ChatBackendId.Hermes, "hermes")]
    [InlineData(ChatBackendId.OpenClaw, "openclaw")]
    [InlineData(ChatBackendId.OpenClaude, "openclaude")]
    [InlineData(ChatBackendId.Omp, "omp")]
    [InlineData(ChatBackendId.PiAgent, "piAgent")]
    [InlineData(ChatBackendId.Droid, "droid")]
    [InlineData(ChatBackendId.Forge, "forge")]
    [InlineData(ChatBackendId.Antigravity, "antigravity")]
    [InlineData(ChatBackendId.CursorAgent, "cursorAgent")]
    public void RawValue_MatchesSwiftRawValue(ChatBackendId backend, string expected)
    {
        Assert.Equal(expected, backend.RawValue());
        Assert.Equal(backend, ChatBackendMetadata.FromRawValue(expected));
    }

    [Fact]
    public void FromRawValue_UnknownToken_IsNull()
    {
        Assert.Null(ChatBackendMetadata.FromRawValue("not-a-backend"));
        Assert.Null(ChatBackendMetadata.FromRawValue(null));
    }

    [Fact]
    public void CsvRoundTrip_PreservesOrderAndDropsUnknowns()
    {
        var backends = new[] { ChatBackendId.Codex, ChatBackendId.Hermes, ChatBackendId.CursorAgent };
        string csv = ChatBackendMetadata.EncodeEnabledList(backends);
        Assert.Equal("codex,hermes,cursorAgent", csv);

        var decoded = ChatBackendMetadata.DecodeEnabledList(csv);
        Assert.Equal(backends, decoded);
    }

    [Fact]
    public void DecodeEnabledList_TrimsWhitespace_AndSkipsBlanksAndUnknowns()
    {
        var decoded = ChatBackendMetadata.DecodeEnabledList(" codex , , bogus ,hermes");
        Assert.Equal(new[] { ChatBackendId.Codex, ChatBackendId.Hermes }, decoded);
    }

    [Fact]
    public void DecodeEnabledList_EmptyString_IsEmpty()
    {
        Assert.Empty(ChatBackendMetadata.DecodeEnabledList(string.Empty));
    }

    [Theory]
    [InlineData(ChatBackendId.Codex, AgentProviderBrand.Codex)]
    [InlineData(ChatBackendId.Claude, AgentProviderBrand.ClaudeCode)]
    [InlineData(ChatBackendId.Hermes, AgentProviderBrand.Hermes)]
    [InlineData(ChatBackendId.OpenClaw, AgentProviderBrand.OpenClaw)]
    [InlineData(ChatBackendId.OpenClaude, AgentProviderBrand.OpenClaude)]
    [InlineData(ChatBackendId.Omp, AgentProviderBrand.Omp)]
    [InlineData(ChatBackendId.PiAgent, AgentProviderBrand.PiAgent)]
    [InlineData(ChatBackendId.Droid, AgentProviderBrand.Factory)]
    [InlineData(ChatBackendId.Forge, AgentProviderBrand.ForgeDev)]
    [InlineData(ChatBackendId.Antigravity, AgentProviderBrand.Antigravity)]
    [InlineData(ChatBackendId.CursorAgent, AgentProviderBrand.CursorAgent)]
    public void AgentProvider_MapsToSwiftLogoProvider(ChatBackendId backend, AgentProviderBrand expected)
    {
        Assert.Equal(expected, backend.AgentProvider());
    }

    [Fact]
    public void RequiresCliAssistantConsent_MatchesSwiftPartition()
    {
        // Swift: hermes/openclaw/piAgent are the ONLY non-consenting backends.
        var nonConsenting = new[] { ChatBackendId.Hermes, ChatBackendId.OpenClaw, ChatBackendId.PiAgent };
        foreach (ChatBackendId backend in ChatBackendMetadata.AllCases)
        {
            bool expected = !nonConsenting.Contains(backend);
            Assert.Equal(expected, backend.RequiresCliAssistantConsent());
        }
    }

    [Fact]
    public void EveryBackend_HasNonEmptyMetadata()
    {
        foreach (ChatBackendId backend in ChatBackendMetadata.AllCases)
        {
            Assert.False(string.IsNullOrEmpty(backend.DisplayName()));
            Assert.False(string.IsNullOrEmpty(backend.ShortLabel()));
            Assert.False(string.IsNullOrEmpty(backend.Glyph()));
        }
    }
}
