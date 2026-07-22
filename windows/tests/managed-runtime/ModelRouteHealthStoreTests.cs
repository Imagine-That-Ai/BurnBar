using System;
using System.IO;
using System.Text;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class ModelRouteHealthStoreTests
{
    private static readonly DateTimeOffset InitialNow = new(2026, 7, 13, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void TransientFailureBlocksForOneMinuteThenExpires()
    {
        DateTimeOffset now = InitialNow;
        var store = new ModelRouteHealthStore(clock: () => now);
        ModelRoute route = Route();

        store.RecordFailure(route, Failure(503));

        ModelRouteHealthRecord blocked = Assert.IsType<ModelRouteHealthRecord>(store.ActiveFailure(route));
        Assert.Equal(ModelRouteHealthFailureKind.TransientCapacity, blocked.FailureKind);
        Assert.Equal(now.AddMinutes(1), blocked.BlockedUntil);

        now = now.AddMinutes(1);
        Assert.Null(store.ActiveFailure(route));
        Assert.Empty(store.Snapshot());
    }

    [Fact]
    public void AnthropicOAuthRateLimitUsesFifteenMinuteCooldown()
    {
        var store = new ModelRouteHealthStore(clock: () => InitialNow);
        ModelRoute route = Route(
            vendor: "anthropic",
            token: "sk-ant-oat-test",
            slot: "claude-max");

        store.RecordFailure(route, Failure(429));

        ModelRouteHealthRecord blocked = Assert.IsType<ModelRouteHealthRecord>(store.ActiveFailure(route));
        Assert.Equal(ModelRouteHealthFailureKind.RateLimit, blocked.FailureKind);
        Assert.Equal(InitialNow.AddMinutes(15), blocked.BlockedUntil);
    }

    [Fact]
    public void CurrentClaudeCodeAuthFailureDoesNotPoisonHealth()
    {
        var store = new ModelRouteHealthStore(clock: () => InitialNow);
        ModelRoute route = Route(vendor: "anthropic", slot: "current-claude-code-login");

        store.RecordFailure(route, Failure(401));

        Assert.Null(store.ActiveFailure(route));
    }

    [Fact]
    public void QuotaBodyCreatesMetadataOnlyBlockAndSuccessClearsIt()
    {
        var store = new ModelRouteHealthStore(clock: () => InitialNow);
        ModelRoute route = Route();
        byte[] sensitiveBody = Encoding.UTF8.GetBytes("quota exhausted secret-canary");

        store.RecordFailure(route, new ModelCompletionResult(400, sensitiveBody, "application/json", false));

        ModelRouteHealthRecord blocked = Assert.IsType<ModelRouteHealthRecord>(store.ActiveFailure(route));
        Assert.Equal(ModelRouteHealthFailureKind.QuotaExhaustion, blocked.FailureKind);
        Assert.DoesNotContain("secret-canary", blocked.ToString(), StringComparison.Ordinal);

        store.RecordSuccess(route);
        Assert.Null(store.ActiveFailure(route));
    }

    [Fact]
    public void OrdinaryClientFailureDoesNotBlockRoute()
    {
        var store = new ModelRouteHealthStore(clock: () => InitialNow);
        ModelRoute route = Route();

        store.RecordFailure(route, Failure(400));

        Assert.Null(store.ActiveFailure(route));
    }

    [Fact]
    public void HealthRecordsPersistWithoutProviderBodiesOrCredentials()
    {
        string directory = Path.Combine(Path.GetTempPath(), "openburnbar-health-" + Guid.NewGuid().ToString("N"));
        string path = Path.Combine(directory, "health.json");
        try
        {
            var writer = new ModelRouteHealthStore(path, () => InitialNow);
            ModelRoute route = Route(token: "secret-token", slot: "work");
            writer.RecordFailure(
                route,
                new ModelCompletionResult(
                    429,
                    Encoding.UTF8.GetBytes("provider-body-secret"),
                    "application/json",
                    false));

            string persisted = File.ReadAllText(path);
            Assert.DoesNotContain("secret-token", persisted, StringComparison.Ordinal);
            Assert.DoesNotContain("provider-body-secret", persisted, StringComparison.Ordinal);

            var reader = new ModelRouteHealthStore(path, () => InitialNow);
            Assert.Equal(429, Assert.IsType<ModelRouteHealthRecord>(reader.ActiveFailure(route)).StatusCode);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void CorruptAndOversizedFilesFailOpenAsEmptyHealthHints()
    {
        string directory = Path.Combine(Path.GetTempPath(), "openburnbar-health-" + Guid.NewGuid().ToString("N"));
        string path = Path.Combine(directory, "health.json");
        try
        {
            Directory.CreateDirectory(directory);
            File.WriteAllText(path, "not-json");
            Assert.Empty(new ModelRouteHealthStore(path, () => InitialNow).Snapshot());

            File.WriteAllBytes(path, new byte[ModelRouteHealthStore.MaximumFileBytes + 1]);
            Assert.Empty(new ModelRouteHealthStore(path, () => InitialNow).Snapshot());
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void RouterFailsOverAroundActiveHealthBlockAndRecoversOnSuccess()
    {
        var store = new ModelRouteHealthStore(clock: () => InitialNow);
        ModelRoute preferred = Route(id: "preferred", vendor: "openai", slot: "primary");
        ModelRoute fallback = Route(id: "fallback", vendor: "anthropic", slot: "backup");
        var router = new ModelProxyRouter(new[] { preferred, fallback }, store);

        router.RecordOutcome(preferred, Failure(503), degraded: false);

        Assert.Equal("fallback", router.Select("openai").Route.Id);
        Assert.True(router.Select("openai").Degraded);
        Assert.Single(router.SnapshotHealth());

        router.RecordOutcome(preferred, new ModelCompletionResult(200, Array.Empty<byte>(), "application/json", true), false);
        Assert.Equal("preferred", router.Select("openai").Route.Id);
        Assert.Empty(router.SnapshotHealth());
    }

    private static ModelCompletionResult Failure(int status) =>
        new(status, Array.Empty<byte>(), "application/json", false);

    private static ModelRoute Route(
        string id = "route",
        string vendor = "openai",
        string? token = null,
        string? slot = null) => new(
            id,
            vendor,
            "shared-model",
            0,
            true,
            new Uri("https://provider.example/v1/chat/completions"),
            token,
            new ModelRouteRoutingMetadata(
                CredentialSlotId: slot,
                FormatFamily: "openai-compatible",
                TrustStatus: ModelRouteTrustStatus.Ready));
}
