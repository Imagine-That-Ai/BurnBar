using System;
using System.IO;
using OpenBurnBar.Particles.Policy;
using Xunit;

namespace OpenBurnBar.Particles.Tests;

/// <summary>
/// Tests for the Windows resolve site: <see cref="SwarmPlanResolver"/>
/// (prefs + sensor snapshot → render plan, the
/// <c>ConstellationBackgroundView</c> / <c>SwarmBackground</c> gate block)
/// and <see cref="SwarmPreferencesStore"/> (the file-backed prefs half of
/// the prefs/sensors owner). The guard chain itself is pinned by
/// <see cref="SwarmBackgroundPolicyTests"/>; this suite pins the composition
/// the WinUI owner calls: visibility-constrain → condition-eval → resolve,
/// plus the unset/corrupt default split.
/// </summary>
public sealed class SwarmPlanResolverTests
{
    private static SwarmEnvironmentSnapshot HealthySensors => new(
        IsPowerConnected: true,
        IsWifiConnected: true,
        ScenePhaseActive: true,
        IsLowPowerModeEnabled: false,
        ReduceMotion: false);

    private static SwarmBackgroundPreferences Prefs(
        SwarmBackgroundLocation location = SwarmBackgroundLocation.Everywhere,
        SwarmBackgroundCondition condition = SwarmBackgroundCondition.Always) =>
        new(location, condition);

    private static SwarmBackgroundRenderPlan Resolve(
        SwarmBackgroundPreferences? prefs = null,
        SwarmEnvironmentSnapshot? sensors = null,
        MobileBackgroundVisibility requestedVisibility = MobileBackgroundVisibility.Prominent,
        MobileBackgroundVisibility inheritedVisibility = MobileBackgroundVisibility.Prominent) =>
        SwarmPlanResolver.Resolve(
            prefs ?? Prefs(),
            sensors ?? HealthySensors,
            requestedVisibility,
            inheritedVisibility);

    [Fact]
    public void HealthySnapshot_ResolvesToProminentLive()
    {
        Assert.Equal(SwarmBackgroundRenderPlan.ProminentLive, Resolve());
    }

    [Fact]
    public void DisabledLocation_ResolvesToDisabledFallback()
    {
        Assert.Equal(
            SwarmBackgroundRenderPlan.DisabledFallback,
            Resolve(prefs: Prefs(location: SwarmBackgroundLocation.Disabled)));
    }

    [Theory]
    [InlineData(true, true)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public void PowerCondition_FollowsThePlugSensor(bool isPowerConnected, bool isWifiConnected)
    {
        SwarmEnvironmentSnapshot sensors = HealthySensors with
        {
            IsPowerConnected = isPowerConnected,
            IsWifiConnected = isWifiConnected,
        };
        SwarmBackgroundRenderPlan expected = isPowerConnected
            ? SwarmBackgroundRenderPlan.ProminentLive
            : SwarmBackgroundRenderPlan.StaticBackdrop;
        Assert.Equal(
            expected,
            Resolve(
                prefs: Prefs(condition: SwarmBackgroundCondition.PowerConnected),
                sensors: sensors));
    }

    [Theory]
    [InlineData(true, true)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public void WifiCondition_FollowsTheWifiSensor(bool isPowerConnected, bool isWifiConnected)
    {
        SwarmEnvironmentSnapshot sensors = HealthySensors with
        {
            IsPowerConnected = isPowerConnected,
            IsWifiConnected = isWifiConnected,
        };
        SwarmBackgroundRenderPlan expected = isWifiConnected
            ? SwarmBackgroundRenderPlan.ProminentLive
            : SwarmBackgroundRenderPlan.StaticBackdrop;
        Assert.Equal(
            expected,
            Resolve(
                prefs: Prefs(condition: SwarmBackgroundCondition.WifiOnly),
                sensors: sensors));
    }

    [Fact]
    public void AlwaysCondition_IgnoresBothSensors()
    {
        SwarmEnvironmentSnapshot sensors = HealthySensors with
        {
            IsPowerConnected = false,
            IsWifiConnected = false,
        };
        Assert.Equal(
            SwarmBackgroundRenderPlan.ProminentLive,
            Resolve(prefs: Prefs(condition: SwarmBackgroundCondition.Always), sensors: sensors));
    }

    [Fact]
    public void SceneInactive_ResolvesToStaticBackdrop()
    {
        SwarmEnvironmentSnapshot sensors = HealthySensors with { ScenePhaseActive = false };
        Assert.Equal(SwarmBackgroundRenderPlan.StaticBackdrop, Resolve(sensors: sensors));
    }

    [Fact]
    public void ReduceMotion_ResolvesToStaticBackdrop()
    {
        SwarmEnvironmentSnapshot sensors = HealthySensors with { ReduceMotion = true };
        Assert.Equal(SwarmBackgroundRenderPlan.StaticBackdrop, Resolve(sensors: sensors));
    }

    [Fact]
    public void LowPower_Prominent_ThrottlesToSubtleLive()
    {
        SwarmEnvironmentSnapshot sensors = HealthySensors with { IsLowPowerModeEnabled = true };
        Assert.Equal(SwarmBackgroundRenderPlan.SubtleLive, Resolve(sensors: sensors));
    }

    [Fact]
    public void LowPower_Subtle_DegradesToStaticBackdrop()
    {
        SwarmEnvironmentSnapshot sensors = HealthySensors with { IsLowPowerModeEnabled = true };
        Assert.Equal(
            SwarmBackgroundRenderPlan.StaticBackdrop,
            Resolve(sensors: sensors, requestedVisibility: MobileBackgroundVisibility.Subtle));
    }

    [Fact]
    public void SubtleRequested_ResolvesToSubtleLive()
    {
        Assert.Equal(
            SwarmBackgroundRenderPlan.SubtleLive,
            Resolve(requestedVisibility: MobileBackgroundVisibility.Subtle));
    }

    [Theory]
    [InlineData(
        MobileBackgroundVisibility.Prominent, MobileBackgroundVisibility.Subtle,
        SwarmRenderMode.Live, 15.0)]
    [InlineData(
        MobileBackgroundVisibility.Subtle, MobileBackgroundVisibility.Prominent,
        SwarmRenderMode.Live, 15.0)]
    [InlineData(
        MobileBackgroundVisibility.Subtle, MobileBackgroundVisibility.Subtle,
        SwarmRenderMode.Live, 15.0)]
    public void InheritedVisibility_ConstrainsTheRequest(
        MobileBackgroundVisibility requested,
        MobileBackgroundVisibility inherited,
        SwarmRenderMode expectedMode,
        double expectedFps)
    {
        SwarmBackgroundRenderPlan plan = Resolve(
            requestedVisibility: requested, inheritedVisibility: inherited);
        Assert.Equal(expectedMode, plan.Mode);
        Assert.Equal(expectedFps, plan.MaxFrameRate);
    }

    [Fact]
    public void InheritedHidden_SuppressesToStaticBackdrop()
    {
        Assert.Equal(
            SwarmBackgroundRenderPlan.StaticBackdrop,
            Resolve(inheritedVisibility: MobileBackgroundVisibility.Hidden));
    }

    [Fact]
    public void DefaultSnapshot_IsFailClosed()
    {
        Assert.Equal(
            SwarmBackgroundRenderPlan.StaticBackdrop,
            Resolve(sensors: new SwarmEnvironmentSnapshot()));
    }

    [Fact]
    public void NullPreferences_Throws()
    {
        Assert.Throws<ArgumentNullException>(() =>
            SwarmPlanResolver.Resolve(null!, HealthySensors));
    }

    [Fact]
    public void MissingFile_ResolvesToUnsetDefault()
    {
        string path = NewTempPath();
        try
        {
            var store = new SwarmPreferencesStore(path);
            Assert.Equal(SwarmPreferencesStore.UnsetDefault, store.Preferences);
            Assert.Equal(SwarmBackgroundLocation.Everywhere, store.Preferences.Location);
            Assert.Equal(SwarmBackgroundCondition.Always, store.Preferences.Condition);
            Assert.Equal(
                SwarmBackgroundPreferences.DefaultGlyphTokens,
                store.Preferences.SelectedGlyphs);
        }
        finally
        {
            DeleteTempDir(path);
        }
    }

    [Fact]
    public void RoundTrip_PreservesPrefs()
    {
        string path = NewTempPath();
        try
        {
            var prefs = new SwarmBackgroundPreferences(
                SwarmBackgroundLocation.AgentsTab,
                SwarmBackgroundCondition.WifiOnly,
                new[] { "Codex", "xAI" },
                isAvatarEnabled: false,
                isBrandTextEnabled: true,
                excludeBrandShapes: true);
            var store = new SwarmPreferencesStore(path);
            store.Update(prefs);
            Assert.Equal(prefs, new SwarmPreferencesStore(path).Preferences);
        }
        finally
        {
            DeleteTempDir(path);
        }
    }

    [Fact]
    public void CorruptFile_FallsBackToCodecDefaults()
    {
        string path = NewTempPath();
        try
        {
            File.WriteAllText(path, "not json");
            Assert.Equal(
                new SwarmBackgroundPreferences(),
                new SwarmPreferencesStore(path).Preferences);
        }
        finally
        {
            DeleteTempDir(path);
        }
    }

    [Fact]
    public void PartialFile_DecodesPerField()
    {
        string path = NewTempPath();
        try
        {
            File.WriteAllText(path, "{\"location\":\"Everywhere\"}");
            SwarmBackgroundPreferences prefs = new SwarmPreferencesStore(path).Preferences;
            Assert.Equal(SwarmBackgroundLocation.Everywhere, prefs.Location);
            Assert.Equal(SwarmBackgroundCondition.Always, prefs.Condition);
            Assert.Equal(
                SwarmBackgroundPreferences.DefaultGlyphTokens,
                prefs.SelectedGlyphs);
        }
        finally
        {
            DeleteTempDir(path);
        }
    }

    [Fact]
    public void Update_CreatesMissingDirectories()
    {
        string path = NewTempPath();
        try
        {
            string nested = Path.Combine(
                Path.GetDirectoryName(path)!,
                "nested",
                SwarmPreferencesStore.FileName);
            var store = new SwarmPreferencesStore(nested);
            store.Update(Prefs());
            Assert.Equal(Prefs(), new SwarmPreferencesStore(nested).Preferences);
        }
        finally
        {
            DeleteTempDir(path);
        }
    }

    private static string NewTempPath()
    {
        string dir = Path.Combine(
            Path.GetTempPath(),
            "SwarmPlanResolverTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        return Path.Combine(dir, SwarmPreferencesStore.FileName);
    }

    private static void DeleteTempDir(string path)
    {
        try
        {
            Directory.Delete(Path.GetDirectoryName(path)!, recursive: true);
        }
        catch (Exception)
        {
            // Best-effort test cleanup only.
        }
    }
}
