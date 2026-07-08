using System;
using System.Collections.Generic;

namespace OpenBurnBar.Integrations.Mercury.Budget;

/// <summary>
/// Fail-closed effective-status state machine ported from
/// <c>AgentLens/Services/Media/MediaBudgetStatusStore.swift</c>. Owns the
/// resolution of the <c>ops/media_budget_status/state/current</c> envelope into
/// the status the capability gate reads, preserving RR-9:
///
/// <list type="bullet">
///   <item>Cold start with nothing to trust resolves to the CONSERVATIVE closed
///     status (hard cap), never the most-permissive <c>initialNormal</c>.</item>
///   <item>A permission-denied error while signed in holds the last-known-good
///     and fails closed.</item>
///   <item>A transient outage promotes any live value into last-known-good so a
///     later reset still resolves to it, otherwise falls to conservative closed.</item>
/// </list>
///
/// The Firestore listener + UserDefaults persistence are injected via
/// <see cref="IMediaBudgetStatusPersistence"/> so the resolution logic is
/// verifiable on any host.
/// </summary>
public sealed class MediaBudgetStatusStore
{
    private readonly IMediaBudgetStatusPersistence _persistence;

    private MediaBudgetStatus? _latestStatus;
    private MediaBudgetStatus? _lastKnownStatus;

    public MediaBudgetStatusStore(IMediaBudgetStatusPersistence? persistence = null)
    {
        _persistence = persistence ?? new InMemoryMediaBudgetStatusPersistence();
        // Rehydrate last-known-good so a cold start after a previous online
        // session reuses the last published envelope instead of failing open.
        _lastKnownStatus = _persistence.Load();
    }

    public bool FailClosedDueToPermissionDenied { get; private set; }

    public MediaBudgetStatus? LatestStatus => _latestStatus;

    public MediaBudgetStatus? LastKnownStatus => _lastKnownStatus;

    /// <summary>Optional callback fired whenever a live envelope is applied.</summary>
    public Action<MediaBudgetStatus>? OnStatusChanged { get; set; }

    /// <summary>The initial-normal preset (parity: initialNormal). NOT a fail-open default.</summary>
    public static readonly MediaBudgetStatus InitialNormal = new(
        MediaBudgetLevel.Normal,
        projectedMonthEndUsd: 0,
        monthToDateUsd: 0,
        lastEvaluatedAt: DateTimeOffset.FromUnixTimeSeconds(0),
        activeEnvelope: MediaBudgetEnvelope.Normal);

    /// <summary>The conservative fail-closed default (parity: conservativeClosed).</summary>
    public static readonly MediaBudgetStatus ConservativeClosed = new(
        MediaBudgetLevel.HardCap,
        projectedMonthEndUsd: 0,
        monthToDateUsd: 0,
        lastEvaluatedAt: DateTimeOffset.FromUnixTimeSeconds(0),
        activeEnvelope: MediaBudgetEnvelope.HardCap);

    /// <summary>Parity: effectiveStatus.</summary>
    public MediaBudgetStatus EffectiveStatus
    {
        get
        {
            if (FailClosedDueToPermissionDenied && _lastKnownStatus is { } held)
            {
                return held;
            }

            return _latestStatus ?? _lastKnownStatus ?? ConservativeClosed;
        }
    }

    /// <summary>Apply a live public envelope (parity: applyPublicEnvelopeData).</summary>
    public void ApplyPublicEnvelope(MediaBudgetStatus status)
    {
        if (status is null)
        {
            throw new ArgumentNullException(nameof(status));
        }

        FailClosedDueToPermissionDenied = false;
        _latestStatus = status;
        _lastKnownStatus = status;
        _persistence.Save(status);
        OnStatusChanged?.Invoke(status);
    }

    /// <summary>
    /// Handle a listener error (parity: handleListenerError). <paramref name="isSignedIn"/>
    /// gates the permission-denied fail-closed branch.
    /// </summary>
    public void HandleListenerError(MediaBudgetListenerError error, bool isSignedIn)
    {
        switch (error)
        {
            case MediaBudgetListenerError.PermissionDenied when isSignedIn:
                FailClosedDueToPermissionDenied = true;
                if (_lastKnownStatus is null)
                {
                    _latestStatus = null;
                }

                break;
            case MediaBudgetListenerError.Unavailable:
            case MediaBudgetListenerError.DeadlineExceeded:
            case MediaBudgetListenerError.ResourceExhausted:
                FailClosedDueToPermissionDenied = false;
                if (_latestStatus is { } live)
                {
                    _lastKnownStatus = live;
                    _persistence.Save(live);
                }

                break;
            default:
                FailClosedDueToPermissionDenied = false;
                break;
        }
    }

    /// <summary>
    /// Parse the public envelope document into a status (parity:
    /// parsePublicEnvelope). Missing / malformed fields default to normal / zero,
    /// matching the Swift.
    /// </summary>
    public static MediaBudgetStatus ParsePublicEnvelope(IReadOnlyDictionary<string, object?> data)
    {
        if (data is null)
        {
            throw new ArgumentNullException(nameof(data));
        }

        var levelRaw = data.TryGetValue("level", out var lv) ? lv as string : null;
        var level = MediaBudgetLevelWire.Parse(levelRaw);

        var envelopeMap = data.TryGetValue("activeEnvelope", out var em)
            ? em as IReadOnlyDictionary<string, object?>
            : null;
        var envelope = new MediaBudgetEnvelope(
            ReadInt(envelopeMap, "screenShareDailyMinutes"),
            ReadInt(envelopeMap, "screenSharePerSessionMinutes"),
            ReadInt(envelopeMap, "videoCallDailyMinutes"),
            ReadInt(envelopeMap, "videoCallPerCallMinutes"),
            ReadInt(envelopeMap, "fileTransferDailyGBIn"),
            ReadInt(envelopeMap, "fileTransferDailyGBOut"));

        var lastEvaluatedAt = data.TryGetValue("lastEvaluatedAt", out var le) && le is DateTimeOffset dto
            ? dto
            : DateTimeOffset.UtcNow;

        return new MediaBudgetStatus(
            level,
            projectedMonthEndUsd: 0,
            monthToDateUsd: 0,
            lastEvaluatedAt: lastEvaluatedAt,
            activeEnvelope: envelope);
    }

    private static int ReadInt(IReadOnlyDictionary<string, object?>? map, string key)
    {
        if (map is null || !map.TryGetValue(key, out var value) || value is null)
        {
            return 0;
        }

        return value switch
        {
            int i => i,
            long l => (int)l,
            double d => (int)d,
            _ => 0,
        };
    }
}

/// <summary>Listener error taxonomy (parity: the FirestoreErrorCode cases the store branches on).</summary>
public enum MediaBudgetListenerError
{
    PermissionDenied,
    Unavailable,
    DeadlineExceeded,
    ResourceExhausted,
    Other,
}

/// <summary>Persistence seam for the last-known-good status (parity: the UserDefaults key).</summary>
public interface IMediaBudgetStatusPersistence
{
    MediaBudgetStatus? Load();

    void Save(MediaBudgetStatus status);
}

/// <summary>Default in-memory persistence used by tests and cold hosts.</summary>
public sealed class InMemoryMediaBudgetStatusPersistence : IMediaBudgetStatusPersistence
{
    private MediaBudgetStatus? _stored;

    public MediaBudgetStatus? Load() => _stored;

    public void Save(MediaBudgetStatus status) => _stored = status;
}
