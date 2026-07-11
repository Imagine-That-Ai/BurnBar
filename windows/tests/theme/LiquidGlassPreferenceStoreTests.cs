using OpenBurnBar.App.Theme;
using Xunit;

namespace OpenBurnBar.App.Theme.Tests;

/// <summary>
/// Drives the shipped <see cref="InMemoryPreferenceStore"/> (the production
/// <see cref="ILiquidGlassPreferenceStore"/> contract used by
/// <c>LiquidGlassEnvironment</c>). Asserts the real entry points — not a reimplementation.
/// </summary>
public sealed class LiquidGlassPreferenceStoreTests
{
    [Fact]
    public void Double_RoundTrips_ThroughShippedStore()
    {
        var store = new InMemoryPreferenceStore();
        Assert.Equal(0, store.GetDouble(LiquidGlassTransparency.StorageKey, 0));

        store.SetDouble(LiquidGlassTransparency.StorageKey, 0.42);
        Assert.Equal(0.42, store.GetDouble(LiquidGlassTransparency.StorageKey, 0), 10);
        Assert.True(store.Contains(LiquidGlassTransparency.StorageKey));
    }

    [Fact]
    public void Bool_RoundTrips_ContentSurfacesKey()
    {
        var store = new InMemoryPreferenceStore();
        Assert.False(store.GetBool(LiquidGlassTransparency.ContentSurfacesEnabledKey, false));

        store.SetBool(LiquidGlassTransparency.ContentSurfacesEnabledKey, true);
        Assert.True(store.GetBool(LiquidGlassTransparency.ContentSurfacesEnabledKey, false));
    }

    [Fact]
    public void String_RoundTrips_KernelKey()
    {
        var store = new InMemoryPreferenceStore();
        const string key = "backdropKernel";
        Assert.Equal("fluid-aurora", store.GetString(key, "fluid-aurora"));

        store.SetString(key, "aurora");
        Assert.Equal("aurora", store.GetString(key, "fluid-aurora"));
    }

    [Fact]
    public void MissingKeys_ReturnProvidedDefaults()
    {
        var store = new InMemoryPreferenceStore();
        Assert.Equal(-0.5, store.GetDouble("missing-d", -0.5), 10);
        Assert.True(store.GetBool("missing-b", true));
        Assert.Equal("fallback", store.GetString("missing-s", "fallback"));
    }
}
