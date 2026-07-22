using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>
/// Sustained and burst limits for one gateway token bucket.
/// </summary>
public sealed record GatewayRateLimitConfiguration
{
    public static GatewayRateLimitConfiguration Default { get; } = new(30, 50);

    public static GatewayRateLimitConfiguration UnauthenticatedLoopbackDefault { get; } = new(5, 30);

    public GatewayRateLimitConfiguration(double requestsPerSecond, int burstCapacity)
    {
        if (!double.IsFinite(requestsPerSecond))
        {
            throw new ArgumentOutOfRangeException(
                nameof(requestsPerSecond),
                "Requests per second must be finite.");
        }

        RequestsPerSecond = Math.Max(requestsPerSecond, 0.1);
        BurstCapacity = Math.Max(burstCapacity, 1);
    }

    public double RequestsPerSecond { get; }

    public int BurstCapacity { get; }
}

public readonly record struct GatewayRateLimitDecision(bool IsAllowed, double RetryAfterSeconds)
{
    public static GatewayRateLimitDecision Allowed { get; } = new(true, 0);

    public static GatewayRateLimitDecision Throttled(double retryAfterSeconds) =>
        new(false, retryAfterSeconds);
}

/// <summary>
/// Thread-safe per-client token bucket used at the local gateway boundary.
/// Uses a monotonic clock so wall-clock changes cannot create or consume tokens.
/// </summary>
public sealed class GatewayRateLimiter
{
    private static readonly TimeSpan PruneInterval = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan BucketIdleTimeout = TimeSpan.FromMinutes(5);

    private readonly object _gate = new();
    private readonly GatewayRateLimitConfiguration _configuration;
    private readonly TimeProvider _timeProvider;
    private readonly Dictionary<string, TokenBucket> _buckets = new(StringComparer.Ordinal);
    private long? _lastPruned;

    public GatewayRateLimiter(
        GatewayRateLimitConfiguration configuration,
        TimeProvider? timeProvider = null)
    {
        _configuration = configuration ?? throw new ArgumentNullException(nameof(configuration));
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    internal int TrackedClientCount
    {
        get
        {
            lock (_gate)
            {
                return _buckets.Count;
            }
        }
    }

    public GatewayRateLimitDecision CheckLimit(string clientKey)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(clientKey);
        if (clientKey.Length > 256)
        {
            throw new ArgumentException("The gateway client key exceeds 256 characters.", nameof(clientKey));
        }

        lock (_gate)
        {
            long now = _timeProvider.GetTimestamp();
            PruneIfNeeded(now);

            if (!_buckets.TryGetValue(clientKey, out TokenBucket? bucket))
            {
                bucket = new TokenBucket(_configuration.BurstCapacity, now);
            }

            double elapsedSeconds = Math.Max(
                _timeProvider.GetElapsedTime(bucket.LastUpdated, now).TotalSeconds,
                0);
            bucket.Tokens = Math.Min(
                _configuration.BurstCapacity,
                bucket.Tokens + (elapsedSeconds * _configuration.RequestsPerSecond));
            bucket.LastUpdated = now;

            if (bucket.Tokens >= 1)
            {
                bucket.Tokens -= 1;
                _buckets[clientKey] = bucket;
                return GatewayRateLimitDecision.Allowed;
            }

            _buckets[clientKey] = bucket;
            double retryAfter = (1 - bucket.Tokens) / _configuration.RequestsPerSecond;
            return GatewayRateLimitDecision.Throttled(Math.Max(retryAfter, 0.1));
        }
    }

    private void PruneIfNeeded(long now)
    {
        if (_lastPruned is long lastPruned
            && _timeProvider.GetElapsedTime(lastPruned, now) < PruneInterval)
        {
            return;
        }

        List<string>? staleKeys = null;
        foreach ((string key, TokenBucket bucket) in _buckets)
        {
            if (_timeProvider.GetElapsedTime(bucket.LastUpdated, now) > BucketIdleTimeout)
            {
                (staleKeys ??= new List<string>()).Add(key);
            }
        }

        if (staleKeys is not null)
        {
            foreach (string key in staleKeys)
            {
                _buckets.Remove(key);
            }
        }

        _lastPruned = now;
    }

    private sealed class TokenBucket(double tokens, long lastUpdated)
    {
        public double Tokens { get; set; } = tokens;

        public long LastUpdated { get; set; } = lastUpdated;
    }
}
