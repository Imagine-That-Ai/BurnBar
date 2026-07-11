using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Notifications;

/// <summary>
/// Production Daily Digest composer: builds a day summary from usage events.
/// Notification delivery is OS-adapter level; composition is portable and Real.
/// </summary>
public static class DailyDigestComposer
{
    public static DailyDigest Compose(IReadOnlyList<DailyDigestEvent> events, DateOnly day)
    {
        ArgumentNullException.ThrowIfNull(events);
        List<DailyDigestEvent> dayEvents = events
            .Where(e => DateOnly.FromDateTime(e.Timestamp.UtcDateTime) == day)
            .OrderBy(e => e.Timestamp)
            .ToList();

        if (dayEvents.Count == 0)
        {
            return new DailyDigest(day, 0, 0, 0, Array.Empty<string>(), IsEmpty: true);
        }

        double spend = dayEvents.Sum(e => e.SpendUsd);
        long tokens = dayEvents.Sum(e => e.Tokens);
        int sessions = dayEvents.Select(e => e.SessionId).Distinct(StringComparer.Ordinal).Count();
        var highlights = dayEvents
            .GroupBy(e => e.Provider, StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(g => g.Sum(x => x.SpendUsd))
            .Take(5)
            .Select(g => $"{g.Key}: ${g.Sum(x => x.SpendUsd):0.00} / {g.Sum(x => x.Tokens)} tok")
            .ToList();

        return new DailyDigest(day, spend, tokens, sessions, highlights, IsEmpty: false);
    }
}

public sealed record DailyDigestEvent(
    DateTimeOffset Timestamp,
    string SessionId,
    string Provider,
    double SpendUsd,
    long Tokens);

public sealed record DailyDigest(
    DateOnly Day,
    double SpendUsd,
    long Tokens,
    int Sessions,
    IReadOnlyList<string> Highlights,
    bool IsEmpty);
