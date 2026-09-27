using OpenBurnBar.App.Settings;
using Xunit;

namespace OpenBurnBar.App.Settings.Tests;

/// <summary>
/// Parity tests for <see cref="ChatModelResolution"/> — the override →
/// advertised → fallback chains (SettingsManager.swift / ChatBackendSettings.swift).
/// </summary>
public sealed class ChatModelResolutionTests
{
    [Theory]
    [InlineData("  custom ", "advertised", "custom")]
    [InlineData("custom", null, "custom")]
    [InlineData("  ", " advertised ", "advertised")]
    [InlineData("", "advertised", "advertised")]
    [InlineData("", null, "hermes")]
    [InlineData("  ", "   ", "hermes")]
    [InlineData("", "", "hermes")]
    public void ResolvedHermesChatModel_FollowsTheOverrideChain(
        string @override,
        string? advertised,
        string expected)
    {
        Assert.Equal(expected, ChatModelResolution.ResolvedHermesChatModel(@override, advertised));
    }

    [Theory]
    [InlineData("custom", null, "custom")]
    [InlineData("", "advertised", "advertised")]
    [InlineData("  ", " advertised ", "advertised")]
    [InlineData("", null, "pi")]
    [InlineData(" ", " ", "pi")]
    [InlineData("", "", "pi")]
    public void ResolvedPiChatModel_FollowsTheOverrideChain(
        string @override,
        string? advertised,
        string expected)
    {
        Assert.Equal(expected, ChatModelResolution.ResolvedPiChatModel(@override, advertised));
    }
}
