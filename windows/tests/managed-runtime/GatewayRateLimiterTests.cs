using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class GatewayRateLimiterTests
{
    [Fact]
    public void Configuration_ClampsToMacOsMinimumsAndRejectsNonFiniteRates()
    {
        var configuration = new GatewayRateLimitConfiguration(0, 0);

        Assert.Equal(0.1, configuration.RequestsPerSecond);
        Assert.Equal(1, configuration.BurstCapacity);
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            new GatewayRateLimitConfiguration(double.NaN, 1));
    }

    [Fact]
    public void CheckLimit_AllowsBurstThenReturnsPreciseRetryDelay()
    {
        var time = new ManualTimeProvider();
        var limiter = new GatewayRateLimiter(new GatewayRateLimitConfiguration(2, 2), time);

        Assert.True(limiter.CheckLimit("client-a").IsAllowed);
        Assert.True(limiter.CheckLimit("client-a").IsAllowed);
        GatewayRateLimitDecision throttled = limiter.CheckLimit("client-a");

        Assert.False(throttled.IsAllowed);
        Assert.Equal(0.5, throttled.RetryAfterSeconds, precision: 6);
    }

    [Fact]
    public void CheckLimit_IsolatesClientsAndRefillsFromMonotonicTime()
    {
        var time = new ManualTimeProvider();
        var limiter = new GatewayRateLimiter(new GatewayRateLimitConfiguration(4, 1), time);

        Assert.True(limiter.CheckLimit("client-a").IsAllowed);
        Assert.False(limiter.CheckLimit("client-a").IsAllowed);
        Assert.True(limiter.CheckLimit("client-b").IsAllowed);

        time.Advance(TimeSpan.FromMilliseconds(250));

        Assert.True(limiter.CheckLimit("client-a").IsAllowed);
    }

    [Fact]
    public void CheckLimit_IsThreadSafeAndNeverExceedsBurst()
    {
        var limiter = new GatewayRateLimiter(
            new GatewayRateLimitConfiguration(0.1, 7),
            new ManualTimeProvider());
        int allowed = 0;

        Parallel.For(0, 100, _ =>
        {
            if (limiter.CheckLimit("shared-client").IsAllowed)
            {
                Interlocked.Increment(ref allowed);
            }
        });

        Assert.Equal(7, allowed);
    }

    [Fact]
    public void CheckLimit_PrunesBucketsAfterFiveMinutesIdle()
    {
        var time = new ManualTimeProvider();
        var limiter = new GatewayRateLimiter(new GatewayRateLimitConfiguration(1, 1), time);
        _ = limiter.CheckLimit("old-client");
        Assert.Equal(1, limiter.TrackedClientCount);

        time.Advance(TimeSpan.FromMinutes(5) + TimeSpan.FromTicks(1));
        _ = limiter.CheckLimit("new-client");

        Assert.Equal(1, limiter.TrackedClientCount);
    }

    private sealed class ManualTimeProvider : TimeProvider
    {
        private long _timestamp;

        public override long TimestampFrequency => TimeSpan.TicksPerSecond;

        public override long GetTimestamp() => Interlocked.Read(ref _timestamp);

        public void Advance(TimeSpan duration) => Interlocked.Add(ref _timestamp, duration.Ticks);
    }
}
