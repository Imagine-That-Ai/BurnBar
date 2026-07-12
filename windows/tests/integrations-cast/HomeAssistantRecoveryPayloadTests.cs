using System;
using System.Text.Json;
using OpenBurnBar.Integrations.Cast.Model;
using OpenBurnBar.Integrations.Cast.Recovery;
using Xunit;

namespace OpenBurnBar.Integrations.Cast.Tests;

public sealed class HomeAssistantRecoveryPayloadTests
{
    private static CastDevice Device() => new()
    {
        ServiceName = "Google-Nest-Hub-1234",
        FriendlyName = "Living Room Hub",
        Host = "192.168.1.42",
        Port = 8009,
        Model = "Google Nest Hub",
        Identifier = "uuid-1",
    };

    [Fact]
    public void Build_ProducesTheRecoveryWebhookBody()
    {
        var when = new DateTimeOffset(2026, 7, 3, 12, 34, 56, TimeSpan.Zero);
        var json = HomeAssistantRecoveryPayload.BuildJson(
            Device(),
            "https://bridge.test/dashboard",
            "Hub didn't respond in time",
            when);

        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        Assert.Equal("openburnbar", root.GetProperty("source").GetString());
        Assert.Equal("cast_recovery", root.GetProperty("action").GetString());
        Assert.Equal("https://bridge.test/dashboard", root.GetProperty("dashboardURL").GetString());
        Assert.Equal("Hub didn't respond in time", root.GetProperty("reason").GetString());
        Assert.Equal("2026-07-03T12:34:56Z", root.GetProperty("requestedAt").GetString());

        var device = root.GetProperty("device");
        Assert.Equal("Google-Nest-Hub-1234", device.GetProperty("serviceName").GetString());
        Assert.Equal("Living Room Hub", device.GetProperty("friendlyName").GetString());
        Assert.Equal("192.168.1.42", device.GetProperty("host").GetString());
        Assert.Equal(8009, device.GetProperty("port").GetInt32());
        Assert.Equal("Google Nest Hub", device.GetProperty("model").GetString());
    }

    [Fact]
    public void Build_NormalizesTimestampToUtcZ()
    {
        var localish = new DateTimeOffset(2026, 7, 3, 14, 0, 0, TimeSpan.FromHours(2));
        var json = HomeAssistantRecoveryPayload.BuildJson(Device(), "https://x/", "reason", localish);
        using var doc = JsonDocument.Parse(json);
        Assert.Equal("2026-07-03T12:00:00Z", doc.RootElement.GetProperty("requestedAt").GetString());
    }
}
