using OpenBurnBar.App.Components;
using Xunit;

namespace OpenBurnBar.App.Components.Tests;

/// <summary>Asserts the update-banner presentation model against UpdateBannerCard.swift.</summary>
public sealed class UpdateBannerModelTests
{
    [Theory]
    [InlineData(UpdatePhaseKind.Idle, false)]
    [InlineData(UpdatePhaseKind.Checking, false)]
    [InlineData(UpdatePhaseKind.UpToDate, false)]
    [InlineData(UpdatePhaseKind.Available, true)]
    [InlineData(UpdatePhaseKind.Downloading, true)]
    [InlineData(UpdatePhaseKind.Failed, true)]
    public void IsActionable(UpdatePhaseKind phase, bool expected) =>
        Assert.Equal(expected, new UpdateBannerState { Phase = phase }.IsActionable);

    [Fact]
    public void Title_available_direct_vs_source()
    {
        Assert.Equal("Update available", new UpdateBannerState
        {
            Phase = UpdatePhaseKind.Available,
            Offer = UpdateOfferKind.DirectDownload,
        }.Title);

        Assert.Equal("New commits available", new UpdateBannerState
        {
            Phase = UpdatePhaseKind.Available,
            Offer = UpdateOfferKind.Source,
        }.Title);
    }

    [Theory]
    [InlineData(UpdatePhaseKind.Downloading, "Downloading update")]
    [InlineData(UpdatePhaseKind.Verifying, "Verifying update")]
    [InlineData(UpdatePhaseKind.Installing, "Installing update")]
    [InlineData(UpdatePhaseKind.Relaunching, "Relaunching")]
    [InlineData(UpdatePhaseKind.Failed, "Update didn't finish")]
    public void Title_progress_phases(UpdatePhaseKind phase, string expected) =>
        Assert.Equal(expected, new UpdateBannerState { Phase = phase }.Title);

    [Fact]
    public void Subtitle_direct_download_critical_flag()
    {
        var critical = new UpdateBannerState
        {
            Phase = UpdatePhaseKind.Available,
            Offer = UpdateOfferKind.DirectDownload,
            IsCritical = true,
        };
        Assert.StartsWith("A security fix is ready", critical.Subtitle);

        var normal = critical with { IsCritical = false };
        Assert.StartsWith("A new version is ready", normal.Subtitle);
    }

    [Fact]
    public void Subtitle_winget_channel()
    {
        var s = new UpdateBannerState
        {
            Phase = UpdatePhaseKind.Available,
            Offer = UpdateOfferKind.Winget,
        };
        Assert.Equal("A newer version is available. Update it through winget.", s.Subtitle);
    }

    [Theory]
    [InlineData(1, "Your build is 1 commit behind main.")]
    [InlineData(4, "Your build is 4 commits behind main.")]
    public void Subtitle_source_pluralizes(int behind, string expected)
    {
        var s = new UpdateBannerState
        {
            Phase = UpdatePhaseKind.Available,
            Offer = UpdateOfferKind.Source,
            CommitsBehind = behind,
            DefaultBranch = "main",
        };
        Assert.Equal(expected, s.Subtitle);
    }

    [Fact]
    public void Subtitle_null_outside_available()
    {
        Assert.Null(new UpdateBannerState { Phase = UpdatePhaseKind.Downloading }.Subtitle);
        Assert.Null(new UpdateBannerState { Phase = UpdatePhaseKind.Available }.Subtitle); // no offer
    }

    [Fact]
    public void AccessibilityLabel_combines_title_and_subtitle()
    {
        var s = new UpdateBannerState
        {
            Phase = UpdatePhaseKind.Available,
            Offer = UpdateOfferKind.Winget,
        };
        Assert.Equal("Update available. A newer version is available. Update it through winget.", s.AccessibilityLabel);
    }

    [Theory]
    [InlineData(UpdatePhaseKind.Verifying, "Verifying signature…")]
    [InlineData(UpdatePhaseKind.Installing, "Installing…")]
    [InlineData(UpdatePhaseKind.Relaunching, "Relaunching…")]
    public void IndeterminateLabel(UpdatePhaseKind phase, string expected) =>
        Assert.Equal(expected, new UpdateBannerState { Phase = phase }.IndeterminateLabel);

    [Fact]
    public void IconGlyph_always_present_for_actionable_phases()
    {
        foreach (UpdatePhaseKind phase in new[]
        {
            UpdatePhaseKind.Available, UpdatePhaseKind.Downloading, UpdatePhaseKind.Verifying,
            UpdatePhaseKind.Installing, UpdatePhaseKind.Relaunching, UpdatePhaseKind.Failed,
        })
        {
            Assert.False(string.IsNullOrEmpty(new UpdateBannerState { Phase = phase }.IconGlyph));
        }
    }
}
