using System;
using System.Linq;
using OpenBurnBar.Particles.Policy;
using Xunit;

namespace OpenBurnBar.Particles.Tests;

/// <summary>
/// Parity tests for the swarm gate-policy layer
/// (OpenBurnBarMobile/Models/SwarmBackgroundPreferences.swift): every resolve
/// guard, the visibility lattice, the decorative-effects gate, the environment
/// truth table, and the persisted-preference codec.
/// </summary>
public sealed class SwarmBackgroundPolicyTests
{
    private static SwarmBackgroundRenderPlan Resolve(
        SwarmBackgroundLocation location = SwarmBackgroundLocation.Everywhere,
        bool conditionMet = true,
        MobileBackgroundVisibility requestedVisibility = MobileBackgroundVisibility.Prominent,
        bool scenePhaseActive = true,
        bool isLowPowerModeEnabled = false,
        bool reduceMotion = false) =>
        SwarmBackgroundPowerPolicy.Resolve(
            location, conditionMet, requestedVisibility,
            scenePhaseActive, isLowPowerModeEnabled, reduceMotion);

    [Fact]
    public void DisabledLocation_ResolvesToDisabledFallback()
    {
        Assert.Equal(
            SwarmBackgroundRenderPlan.DisabledFallback,
            Resolve(location: SwarmBackgroundLocation.Disabled));
    }

    [Fact]
    public void Disabled_WinsOverEveryOtherLiveSignal()
    {
        SwarmBackgroundRenderPlan plan = Resolve(
            location: SwarmBackgroundLocation.Disabled,
            conditionMet: true,
            requestedVisibility: MobileBackgroundVisibility.Prominent,
            scenePhaseActive: true,
            isLowPowerModeEnabled: true,
            reduceMotion: true);
        Assert.Equal(SwarmBackgroundRenderPlan.DisabledFallback, plan);
    }

    [Theory]
    [InlineData(false, MobileBackgroundVisibility.Prominent, true, false, false)]
    [InlineData(true, MobileBackgroundVisibility.Prominent, false, false, false)]
    [InlineData(true, MobileBackgroundVisibility.Hidden, true, false, false)]
    [InlineData(true, MobileBackgroundVisibility.Prominent, true, false, true)]
    [InlineData(true, MobileBackgroundVisibility.Obscured, true, false, false)]
    [InlineData(true, MobileBackgroundVisibility.Obscured, true, true, false)]
    public void NegativeBranches_ResolveToStaticBackdrop(
        bool conditionMet,
        MobileBackgroundVisibility visibility,
        bool scenePhaseActive,
        bool isLowPowerModeEnabled,
        bool reduceMotion)
    {
        Assert.Equal(
            SwarmBackgroundRenderPlan.StaticBackdrop,
            Resolve(
                conditionMet: conditionMet,
                requestedVisibility: visibility,
                scenePhaseActive: scenePhaseActive,
                isLowPowerModeEnabled: isLowPowerModeEnabled,
                reduceMotion: reduceMotion));
    }

    [Fact]
    public void LowPowerProminent_ThrottlesToSubtleLive()
    {
        Assert.Equal(
            SwarmBackgroundRenderPlan.SubtleLive,
            Resolve(isLowPowerModeEnabled: true));
    }

    [Fact]
    public void LowPowerSubtle_DegradesToStaticBackdrop()
    {
        Assert.Equal(
            SwarmBackgroundRenderPlan.StaticBackdrop,
            Resolve(
                requestedVisibility: MobileBackgroundVisibility.Subtle,
                isLowPowerModeEnabled: true));
    }

    [Fact]
    public void Prominent_ResolvesToProminentLiveWithExactPlanValues()
    {
        SwarmBackgroundRenderPlan plan = Resolve();
        Assert.Equal(SwarmRenderMode.Live, plan.Mode);
        Assert.Equal(30, plan.MaxFrameRate);
        Assert.Equal(1.0, plan.ParticleScale);
        Assert.Equal(1.0, plan.MotionSpeedMultiplierScale);
        Assert.True(plan.AllowsAutoCycling);
        Assert.True(plan.AllowsSparkles);
        Assert.False(plan.IsBatteryThrottled);
    }

    [Fact]
    public void Subtle_ResolvesToSubtleLiveWithExactPlanValues()
    {
        SwarmBackgroundRenderPlan plan = Resolve(requestedVisibility: MobileBackgroundVisibility.Subtle);
        Assert.Equal(SwarmRenderMode.Live, plan.Mode);
        Assert.Equal(15, plan.MaxFrameRate);
        Assert.Equal(0.45, plan.ParticleScale);
        Assert.Equal(0.55, plan.MotionSpeedMultiplierScale);
        Assert.False(plan.AllowsAutoCycling);
        Assert.False(plan.AllowsSparkles);
        Assert.True(plan.IsBatteryThrottled);
    }

    [Fact]
    public void StaticBackdropAndDisabledFallback_CarryNoFrameBudget()
    {
        Assert.Null(SwarmBackgroundRenderPlan.StaticBackdrop.MaxFrameRate);
        Assert.Null(SwarmBackgroundRenderPlan.DisabledFallback.MaxFrameRate);
        Assert.True(SwarmBackgroundRenderPlan.StaticBackdrop.IsBatteryThrottled);
        Assert.False(SwarmBackgroundRenderPlan.DisabledFallback.IsBatteryThrottled);
    }

    [Fact]
    public void WireValues_MatchTheSwiftRawStrings()
    {
        Assert.Equal("Disabled", SwarmBackgroundLocation.Disabled.RawValue());
        Assert.Equal("Agents Tab Only", SwarmBackgroundLocation.AgentsTab.RawValue());
        Assert.Equal("Everywhere", SwarmBackgroundLocation.Everywhere.RawValue());
        Assert.Equal("Always", SwarmBackgroundCondition.Always.RawValue());
        Assert.Equal("Power Connected Only", SwarmBackgroundCondition.PowerConnected.RawValue());
        Assert.Equal("Wi-Fi Only", SwarmBackgroundCondition.WifiOnly.RawValue());
        Assert.Null(SwarmGateMetadata.LocationFromRawValue("disabled"));
        Assert.Null(SwarmGateMetadata.ConditionFromRawValue("always"));
    }

    [Theory]
    [InlineData(MobileBackgroundVisibility.Prominent, MobileBackgroundVisibility.Subtle, MobileBackgroundVisibility.Subtle)]
    [InlineData(MobileBackgroundVisibility.Subtle, MobileBackgroundVisibility.Prominent, MobileBackgroundVisibility.Subtle)]
    [InlineData(MobileBackgroundVisibility.Subtle, MobileBackgroundVisibility.Obscured, MobileBackgroundVisibility.Obscured)]
    [InlineData(MobileBackgroundVisibility.Prominent, MobileBackgroundVisibility.Hidden, MobileBackgroundVisibility.Hidden)]
    [InlineData(MobileBackgroundVisibility.Hidden, MobileBackgroundVisibility.Prominent, MobileBackgroundVisibility.Hidden)]
    [InlineData(MobileBackgroundVisibility.Subtle, MobileBackgroundVisibility.Subtle, MobileBackgroundVisibility.Subtle)]
    public void Constrained_KeepsTheMoreRestrictiveVisibility(
        MobileBackgroundVisibility self,
        MobileBackgroundVisibility inherited,
        MobileBackgroundVisibility expected)
    {
        Assert.Equal(expected, self.Constrained(inherited));
    }

    [Theory]
    [InlineData(MobileBackgroundVisibility.Prominent, true, true)]
    [InlineData(MobileBackgroundVisibility.Subtle, true, true)]
    [InlineData(MobileBackgroundVisibility.Obscured, true, false)]
    [InlineData(MobileBackgroundVisibility.Hidden, true, false)]
    [InlineData(MobileBackgroundVisibility.Prominent, false, false)]
    public void AllowsLiveEffects_RequiresActiveSceneAndVisibleBackground(
        MobileBackgroundVisibility visibility,
        bool scenePhaseActive,
        bool expected)
    {
        Assert.Equal(expected, MobileDecorativeRenderPolicy.AllowsLiveEffects(visibility, scenePhaseActive));
    }

    [Theory]
    [InlineData(SwarmBackgroundCondition.Always, false, false, true)]
    [InlineData(SwarmBackgroundCondition.PowerConnected, true, false, true)]
    [InlineData(SwarmBackgroundCondition.PowerConnected, false, true, false)]
    [InlineData(SwarmBackgroundCondition.WifiOnly, false, true, true)]
    [InlineData(SwarmBackgroundCondition.WifiOnly, true, false, false)]
    public void MeetsCondition_FollowsTheSensorTruthTable(
        SwarmBackgroundCondition condition,
        bool isPowerConnected,
        bool isWifiConnected,
        bool expected)
    {
        Assert.Equal(
            expected,
            SwarmEnvironmentConditionEvaluator.MeetsCondition(condition, isPowerConnected, isWifiConnected));
    }

    [Fact]
    public void PreferenceDefaults_MatchSwift()
    {
        var prefs = new SwarmBackgroundPreferences();
        Assert.Equal(SwarmBackgroundLocation.Disabled, prefs.Location);
        Assert.Equal(SwarmBackgroundCondition.Always, prefs.Condition);
        Assert.Equal(SwarmBackgroundPreferences.DefaultGlyphTokens, prefs.SelectedGlyphs);
        Assert.True(prefs.IsAvatarEnabled);
        Assert.True(prefs.IsBrandTextEnabled);
        Assert.False(prefs.ExcludeBrandShapes);
        Assert.Equal("swarmBackgroundPreferencesV2", SwarmBackgroundPreferences.UserDefaultsKey);
    }

    [Fact]
    public void GlyphTokens_MatchSettingsCatalog()
    {
        // The renderer's embedded token table must equal the Settings provider
        // catalog's swarm order (display names) — the cross-platform default.
        string[] catalog = global::OpenBurnBar.App.Settings.SwarmGlyphProviders.Ordered
            .Select(global::OpenBurnBar.App.Settings.AgentProviderMetadata.DisplayName)
            .ToArray();
        Assert.Equal(catalog, SwarmBackgroundPreferences.DefaultGlyphTokens);
        Assert.Equal(37, SwarmBackgroundPreferences.DefaultGlyphTokens.Count);
    }

    [Fact]
    public void Preferences_RoundTripThroughJson()
    {
        var prefs = new SwarmBackgroundPreferences(
            SwarmBackgroundLocation.Everywhere,
            SwarmBackgroundCondition.WifiOnly,
            new[] { "Codex", "xAI" },
            isAvatarEnabled: false,
            isBrandTextEnabled: true,
            excludeBrandShapes: true);
        Assert.Equal(prefs, SwarmBackgroundPreferences.From(prefs.ToJsonString()));
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("not json")]
    [InlineData("[1,2]")]
    [InlineData("")]
    public void EmptyOrMalformedJson_DecodesToDefaults(string json)
    {
        Assert.Equal(new SwarmBackgroundPreferences(), SwarmBackgroundPreferences.From(json));
    }

    [Fact]
    public void MissingKeys_FallBackPerField()
    {
        SwarmBackgroundPreferences prefs = SwarmBackgroundPreferences.From("{\"location\":\"Everywhere\"}");
        Assert.Equal(SwarmBackgroundLocation.Everywhere, prefs.Location);
        Assert.Equal(SwarmBackgroundCondition.Always, prefs.Condition);
        Assert.Equal(SwarmBackgroundPreferences.DefaultGlyphTokens, prefs.SelectedGlyphs);
        Assert.True(prefs.IsAvatarEnabled);
    }

    [Fact]
    public void ExplicitNulls_FallBackPerField()
    {
        SwarmBackgroundPreferences prefs = SwarmBackgroundPreferences.From(
            "{\"location\":null,\"condition\":null,\"selectedGlyphs\":null," +
            "\"isAvatarEnabled\":null,\"isBrandTextEnabled\":null,\"excludeBrandShapes\":null}");
        Assert.Equal(new SwarmBackgroundPreferences(), prefs);
    }

    [Theory]
    [InlineData("{\"location\":\"Yolo\",\"condition\":\"Always\",\"isAvatarEnabled\":false}")]
    [InlineData("{\"location\":\"Everywhere\",\"selectedGlyphs\":[\"Codex\",\"Nope\"]}")]
    [InlineData("{\"isAvatarEnabled\":\"yes\"}")]
    [InlineData("{\"selectedGlyphs\":\"Codex\"}")]
    [InlineData("{\"selectedGlyphs\":[42]}")]
    [InlineData("{\"location\":[\"Everywhere\"]}")]
    public void StructuralFailures_DiscardTheWholePayload(string json)
    {
        Assert.Equal(new SwarmBackgroundPreferences(), SwarmBackgroundPreferences.From(json));
    }

    [Fact]
    public void DefaultJson_ParsesBackToDefaults()
    {
        Assert.Equal(
            new SwarmBackgroundPreferences(),
            SwarmBackgroundPreferences.From(SwarmBackgroundPreferences.DefaultJson));
        Assert.Contains("\"location\":\"Disabled\"", SwarmBackgroundPreferences.DefaultJson);
        Assert.Contains("\"condition\":\"Always\"", SwarmBackgroundPreferences.DefaultJson);
    }

    [Fact]
    public void FrameInterval_HonorsThePlanFpsCap()
    {
        Assert.Equal(
            TimeSpan.FromSeconds(1.0 / 30),
            SwarmHostRenderGate.FrameInterval(SwarmBackgroundRenderPlan.ProminentLive));
        Assert.Equal(
            TimeSpan.FromSeconds(1.0 / 15),
            SwarmHostRenderGate.FrameInterval(SwarmBackgroundRenderPlan.SubtleLive));
    }

    [Fact]
    public void FrameInterval_FallsBackWithoutACap()
    {
        Assert.Equal(
            SwarmHostRenderGate.FallbackFrameInterval,
            SwarmHostRenderGate.FrameInterval(SwarmBackgroundRenderPlan.StaticBackdrop));
        Assert.Equal(
            SwarmHostRenderGate.FallbackFrameInterval,
            SwarmHostRenderGate.FrameInterval(SwarmBackgroundRenderPlan.DisabledFallback));
    }

    [Fact]
    public void LivePlan_ThrottlesInsideTheFrameBudget()
    {
        Assert.Equal(
            SwarmHostFrameAction.SkipThrottled,
            SwarmHostRenderGate.DecideAction(
                SwarmBackgroundRenderPlan.ProminentLive,
                TimeSpan.FromMilliseconds(10),
                staticFrameRendered: false));
        Assert.Equal(
            SwarmHostFrameAction.Render,
            SwarmHostRenderGate.DecideAction(
                SwarmBackgroundRenderPlan.ProminentLive,
                TimeSpan.FromMilliseconds(40),
                staticFrameRendered: false));
    }

    [Fact]
    public void StaticPlan_RendersExactlyOneFrame()
    {
        Assert.Equal(
            SwarmHostFrameAction.Render,
            SwarmHostRenderGate.DecideAction(
                SwarmBackgroundRenderPlan.StaticBackdrop,
                TimeSpan.Zero,
                staticFrameRendered: false));
        Assert.Equal(
            SwarmHostFrameAction.SkipSuppressed,
            SwarmHostRenderGate.DecideAction(
                SwarmBackgroundRenderPlan.StaticBackdrop,
                TimeSpan.FromHours(1),
                staticFrameRendered: true));
    }

    [Fact]
    public void DisabledPlan_NeverRenders()
    {
        Assert.Equal(
            SwarmHostFrameAction.SkipSuppressed,
            SwarmHostRenderGate.DecideAction(
                SwarmBackgroundRenderPlan.DisabledFallback,
                TimeSpan.FromHours(1),
                staticFrameRendered: false));
    }
}
