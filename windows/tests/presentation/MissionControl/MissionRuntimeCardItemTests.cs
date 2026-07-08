using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.MissionControl;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.MissionControl;

/// <summary>Locks the runtime constellation rows ported from
/// <c>MissionRuntimeConstellation</c> (MissionRuntimeConstellation.swift).</summary>
public sealed class MissionRuntimeCardItemTests
{
    private static readonly IReadOnlyList<MissionRuntime> Runtimes = new[]
    {
        new MissionRuntime("claude", "Claude Code", "CLD", "claudeCode", RuntimeAvailability.Online, 0.84, 6),
        new MissionRuntime("codex", "Codex CLI", "CDX", "codex", RuntimeAvailability.Online),
        new MissionRuntime("ollama", "Ollama (local)", "OLM", "ollama", RuntimeAvailability.Unknown, tagline: "Free, on-device."),
    };

    [Fact]
    public void AutoCardIsAlwaysFirst()
    {
        var items = MissionRuntimeCardItem.Build(Runtimes, "auto", MissionKind.Diligence);
        Assert.Equal("auto", items[0].Id);
        Assert.True(items[0].IsAuto);
        Assert.Equal(4, items.Count); // auto + 3 runtimes
    }

    [Fact]
    public void SelectedRuntimeIsMarked()
    {
        var items = MissionRuntimeCardItem.Build(Runtimes, "codex", MissionKind.Diligence);
        Assert.True(items.Single(i => i.Id == "codex").IsSelected);
        Assert.False(items.Single(i => i.Id == "claude").IsSelected);
    }

    [Fact]
    public void PreferredHintShowsForKindFirstChoice_WhenUnselected()
    {
        // Diligence prefers claude first. With AUTO selected, claude shows the hint.
        var items = MissionRuntimeCardItem.Build(Runtimes, "auto", MissionKind.Diligence);
        MissionRuntimeCardItem claude = items.Single(i => i.Id == "claude");
        Assert.True(claude.IsPreferred);
        Assert.True(claude.ShowsPreferredHint);
        Assert.Equal("Preferred for Diligence", claude.PreferredLabel);
    }

    [Fact]
    public void PreferredHintHidesWhenThatRuntimeIsSelected()
    {
        var items = MissionRuntimeCardItem.Build(Runtimes, "claude", MissionKind.Diligence);
        MissionRuntimeCardItem claude = items.Single(i => i.Id == "claude");
        Assert.True(claude.IsPreferred);
        Assert.False(claude.ShowsPreferredHint); // selected -> no hint
    }

    [Fact]
    public void SubtitlePrefersTagline_ThenMedian_ThenNoHistory()
    {
        var items = MissionRuntimeCardItem.Build(Runtimes, "auto", MissionKind.Diligence);
        Assert.Equal("Free, on-device.", items.Single(i => i.Id == "ollama").Subtitle);
        Assert.Equal("$0.8400 median · n=6", items.Single(i => i.Id == "claude").Subtitle);
        Assert.Equal("No recent history", items.Single(i => i.Id == "codex").Subtitle);
    }

    [Fact]
    public void CreativeKindShiftsPreferredToOpenClaw()
    {
        var runtimes = Runtimes.Append(
            new MissionRuntime("openclaw", "OpenClaw", "OCL", "openClaw", RuntimeAvailability.Online)).ToList();
        var items = MissionRuntimeCardItem.Build(runtimes, "auto", MissionKind.Creative);
        Assert.True(items.Single(i => i.Id == "openclaw").IsPreferred);
        Assert.False(items.Single(i => i.Id == "claude").IsPreferred);
    }
}
