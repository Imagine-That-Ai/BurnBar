using System;
using OpenBurnBar.Integrations.Cast.Model;
using Xunit;

namespace OpenBurnBar.Integrations.Cast.Tests;

public sealed class CastDeviceTests
{
    private static readonly DateTimeOffset FixedSeenAt = new(2026, 7, 3, 0, 0, 0, TimeSpan.Zero);

    private static CastDevice WithModel(string model) => new()
    {
        ServiceName = "svc",
        FriendlyName = "friendly",
        Host = "10.0.0.1",
        Port = 8009,
        Model = model,
        Identifier = "id",
        LastSeenAt = FixedSeenAt,
    };

    [Theory]
    [InlineData("Google Nest Hub Max", CastIconKind.NestHubMax)]
    [InlineData("Google Nest Hub", CastIconKind.NestHub)]
    [InlineData("Chromecast", CastIconKind.Chromecast)]
    [InlineData("Chromecast Ultra", CastIconKind.Chromecast)]
    [InlineData("Nest Mini", CastIconKind.NestSpeaker)]
    [InlineData("Nest Audio", CastIconKind.NestSpeaker)]
    [InlineData("Some TV", CastIconKind.Generic)]
    public void IconKind_CollapsesModelToBucket(string model, CastIconKind expected)
        => Assert.Equal(expected, WithModel(model).IconKind);

    [Fact]
    public void CastDevice_HasValueEquality()
    {
        var a = WithModel("Google Nest Hub");
        var b = WithModel("Google Nest Hub");
        Assert.Equal(a, b);
        Assert.Equal(a.GetHashCode(), b.GetHashCode());
    }

    [Fact]
    public void CastDevice_DefaultsSupportsDisplayTrue()
        => Assert.True(WithModel("anything").SupportsDisplay);
}
