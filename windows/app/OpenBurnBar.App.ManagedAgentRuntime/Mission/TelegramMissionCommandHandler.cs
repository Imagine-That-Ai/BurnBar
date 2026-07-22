using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Mission;

public sealed record TelegramFollowup(
    string Id,
    string ProjectSlug,
    string Title,
    string Summary,
    bool IsDone = false,
    DateTimeOffset? SnoozeUntil = null,
    DateTimeOffset? NextNudgeAt = null);

public sealed record TelegramQuestion(
    string Id,
    string ProjectSlug,
    string Title,
    string? Answer = null,
    string? AnsweredBy = null);

public sealed record TelegramMissionState(
    IReadOnlyList<TelegramFollowup> Followups,
    IReadOnlyList<TelegramQuestion> Questions)
{
    public static TelegramMissionState Empty { get; } =
        new(Array.Empty<TelegramFollowup>(), Array.Empty<TelegramQuestion>());
}

public interface ITelegramMissionStateStore
{
    ValueTask<TelegramMissionState> LoadAsync(CancellationToken cancellationToken = default);

    ValueTask SaveAsync(TelegramMissionState state, CancellationToken cancellationToken = default);
}

public sealed class InMemoryTelegramMissionStateStore : ITelegramMissionStateStore
{
    private readonly object _gate = new();
    private TelegramMissionState _state;

    public InMemoryTelegramMissionStateStore(TelegramMissionState? state = null)
    {
        _state = state ?? TelegramMissionState.Empty;
    }

    public ValueTask<TelegramMissionState> LoadAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        lock (_gate)
        {
            return ValueTask.FromResult(_state);
        }
    }

    public ValueTask SaveAsync(
        TelegramMissionState state,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        lock (_gate)
        {
            _state = state ?? throw new ArgumentNullException(nameof(state));
            return ValueTask.CompletedTask;
        }
    }
}

/// <summary>
/// Implements the macOS Telegram notification-command contract over the Windows
/// local Mission Control substitute. Followup/question state is abstracted so
/// production can keep it in the current-user protected store.
/// </summary>
public sealed class TelegramMissionCommandHandler
{
    private const int MaximumStateItems = 500;
    private const int MaximumSnoozeMinutes = 7 * 24 * 60;
    private readonly ITelegramMissionStateStore _stateStore;
    private readonly Func<CancellationToken, Task<string>> _statusProvider;
    private readonly Func<string, bool, CancellationToken, Task<string>> _reviewLauncher;
    private readonly Func<DateTimeOffset> _now;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public TelegramMissionCommandHandler(
        ITelegramMissionStateStore stateStore,
        Func<CancellationToken, Task<string>> statusProvider,
        Func<string, bool, CancellationToken, Task<string>> reviewLauncher,
        Func<DateTimeOffset>? now = null)
    {
        _stateStore = stateStore ?? throw new ArgumentNullException(nameof(stateStore));
        _statusProvider = statusProvider ?? throw new ArgumentNullException(nameof(statusProvider));
        _reviewLauncher = reviewLauncher ?? throw new ArgumentNullException(nameof(reviewLauncher));
        _now = now ?? (() => DateTimeOffset.UtcNow);
    }

    public async Task<TelegramCommandResponse> HandleAsync(
        TelegramCommandRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            TelegramMissionState state = Normalize(
                await _stateStore.LoadAsync(cancellationToken).ConfigureAwait(false));
            return request.Command switch
            {
                TelegramCommand.Help => Ok(
                    "Commands: help, pending, followups, done <id>, snooze <id> [minutes], "
                    + "calendar <id> <ISO8601>, answer <id> <text>, latest, status, "
                    + "run_daily <project>, run_weekly <project>."),
                TelegramCommand.Pending or TelegramCommand.Followups => Pending(request, state),
                TelegramCommand.Done => await DoneAsync(request, state, cancellationToken).ConfigureAwait(false),
                TelegramCommand.Snooze => await SnoozeAsync(request, state, cancellationToken).ConfigureAwait(false),
                TelegramCommand.Calendar => new TelegramCommandResponse(
                    false,
                    "Calendar commands are unavailable on Windows because EventKit has no Windows equivalent."),
                TelegramCommand.Answer => await AnswerAsync(request, state, cancellationToken).ConfigureAwait(false),
                TelegramCommand.Latest or TelegramCommand.Status =>
                    await StatusAsync(state, cancellationToken).ConfigureAwait(false),
                TelegramCommand.RunDaily => await LaunchReviewAsync(request, weekly: false, cancellationToken)
                    .ConfigureAwait(false),
                TelegramCommand.RunWeekly => await LaunchReviewAsync(request, weekly: true, cancellationToken)
                    .ConfigureAwait(false),
                _ => new TelegramCommandResponse(false, "Unsupported Telegram command."),
            };
        }
        finally
        {
            _gate.Release();
        }
    }

    public Task RecordFollowupAsync(
        TelegramFollowup followup,
        CancellationToken cancellationToken = default) =>
        MutateAsync(
            state => state with
            {
                Followups = Upsert(state.Followups, followup, item => item.Id),
            },
            cancellationToken);

    public Task RecordQuestionAsync(
        TelegramQuestion question,
        CancellationToken cancellationToken = default) =>
        MutateAsync(
            state => state with
            {
                Questions = Upsert(state.Questions, question, item => item.Id),
            },
            cancellationToken);

    public async Task<IReadOnlyList<string>> TakeDueFollowupMessagesAsync(
        int defaultSnoozeMinutes,
        CancellationToken cancellationToken = default)
    {
        int minutes = Math.Clamp(defaultSnoozeMinutes, 15, MaximumSnoozeMinutes);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            TelegramMissionState state = Normalize(
                await _stateStore.LoadAsync(cancellationToken).ConfigureAwait(false));
            DateTimeOffset now = _now();
            var due = state.Followups
                .Select((item, index) => (item, index))
                .Where(pair =>
                    !pair.item.IsDone
                    && (!pair.item.SnoozeUntil.HasValue || pair.item.SnoozeUntil <= now)
                    && (!pair.item.NextNudgeAt.HasValue || pair.item.NextNudgeAt <= now))
                .Take(100)
                .ToArray();
            if (due.Length == 0)
            {
                return Array.Empty<string>();
            }

            TelegramFollowup[] updated = state.Followups.ToArray();
            foreach ((TelegramFollowup item, int index) in due)
            {
                updated[index] = item with { NextNudgeAt = now.AddMinutes(minutes) };
            }
            await _stateStore.SaveAsync(
                state with { Followups = updated },
                cancellationToken).ConfigureAwait(false);
            return due.Select(pair =>
                $"[{pair.item.ProjectSlug}] Followup due\n{pair.item.Title}\n{pair.item.Summary}")
                .ToArray();
        }
        finally
        {
            _gate.Release();
        }
    }

    private TelegramCommandResponse Pending(
        TelegramCommandRequest request,
        TelegramMissionState state)
    {
        DateTimeOffset now = _now();
        TelegramFollowup[] open = state.Followups
            .Where(item => !item.IsDone && (!item.SnoozeUntil.HasValue || item.SnoozeUntil <= now))
            .Take(5)
            .ToArray();
        if (open.Length == 0)
        {
            return Ok("No unresolved followups.");
        }

        string preview = string.Join('\n', open.Select(item => $"{item.Id}: {item.Title}"));
        return Ok(preview);
    }

    private async Task<TelegramCommandResponse> DoneAsync(
        TelegramCommandRequest request,
        TelegramMissionState state,
        CancellationToken cancellationToken)
    {
        if (request.Arguments.Count == 0)
        {
            return new TelegramCommandResponse(false, "Usage: done <followupID>");
        }

        int index = FindFollowup(state, request.Arguments[0]);
        if (index < 0)
        {
            return new TelegramCommandResponse(false, "Followup not found.");
        }

        TelegramFollowup followup = state.Followups[index] with
        {
            IsDone = true,
            SnoozeUntil = null,
            NextNudgeAt = null,
        };
        await _stateStore.SaveAsync(
            state with { Followups = ReplaceAt(state.Followups, index, followup) },
            cancellationToken).ConfigureAwait(false);
        return Ok($"Marked {followup.Title} done.");
    }

    private async Task<TelegramCommandResponse> SnoozeAsync(
        TelegramCommandRequest request,
        TelegramMissionState state,
        CancellationToken cancellationToken)
    {
        if (request.Arguments.Count == 0)
        {
            return new TelegramCommandResponse(false, "Usage: snooze <followupID> [minutes]");
        }

        int minutes = 60;
        if (request.Arguments.Count > 1
            && (!int.TryParse(request.Arguments[1], NumberStyles.None, CultureInfo.InvariantCulture, out minutes)
                || minutes is < 1 or > MaximumSnoozeMinutes))
        {
            return new TelegramCommandResponse(false, $"Snooze minutes must be between 1 and {MaximumSnoozeMinutes}.");
        }

        int index = FindFollowup(state, request.Arguments[0]);
        if (index < 0)
        {
            return new TelegramCommandResponse(false, "Followup not found.");
        }

        TelegramFollowup followup = state.Followups[index] with
        {
            IsDone = false,
            SnoozeUntil = _now().AddMinutes(minutes),
            NextNudgeAt = null,
        };
        await _stateStore.SaveAsync(
            state with { Followups = ReplaceAt(state.Followups, index, followup) },
            cancellationToken).ConfigureAwait(false);
        return Ok($"Snoozed {followup.Title} for {minutes}m.");
    }

    private async Task<TelegramCommandResponse> AnswerAsync(
        TelegramCommandRequest request,
        TelegramMissionState state,
        CancellationToken cancellationToken)
    {
        if (request.Arguments.Count < 2)
        {
            return new TelegramCommandResponse(false, "Usage: answer <questionID> <text>");
        }

        int index = FindQuestion(state, request.Arguments[0]);
        if (index < 0)
        {
            return new TelegramCommandResponse(false, "Question not found.");
        }

        string answer = string.Join(' ', request.Arguments.Skip(1)).Trim();
        TelegramQuestion question = state.Questions[index] with
        {
            Answer = answer,
            AnsweredBy = request.Actor,
        };
        await _stateStore.SaveAsync(
            state with { Questions = ReplaceAt(state.Questions, index, question) },
            cancellationToken).ConfigureAwait(false);
        return Ok($"Answered {question.Title}.");
    }

    private async Task<TelegramCommandResponse> LaunchReviewAsync(
        TelegramCommandRequest request,
        bool weekly,
        CancellationToken cancellationToken)
    {
        string project = request.Arguments.FirstOrDefault()?.Trim() ?? "openburnbar";
        if (project.Length is 0 or > 128)
        {
            return new TelegramCommandResponse(false, "Project must contain 1 to 128 characters.");
        }

        string runId = await _reviewLauncher(project, weekly, cancellationToken).ConfigureAwait(false);
        string cadence = weekly ? "weekly" : "daily";
        return Ok($"Launched {cadence} review for {project} (run {runId}).");
    }

    private async Task<TelegramCommandResponse> StatusAsync(
        TelegramMissionState state,
        CancellationToken cancellationToken)
    {
        DateTimeOffset now = _now();
        int openFollowups = state.Followups.Count(item =>
            !item.IsDone && (!item.SnoozeUntil.HasValue || item.SnoozeUntil <= now));
        int pendingQuestions = state.Questions.Count(item => string.IsNullOrWhiteSpace(item.Answer));
        int projects = state.Followups.Select(item => item.ProjectSlug)
            .Concat(state.Questions.Select(item => item.ProjectSlug))
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Count();
        string runtime = await _statusProvider(cancellationToken).ConfigureAwait(false);
        return Ok(
            $"Projects: {projects}, pending questions: {pendingQuestions}, "
            + $"open followups: {openFollowups}. {runtime}");
    }

    private async Task MutateAsync(
        Func<TelegramMissionState, TelegramMissionState> mutation,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            TelegramMissionState state = Normalize(
                await _stateStore.LoadAsync(cancellationToken).ConfigureAwait(false));
            await _stateStore.SaveAsync(Normalize(mutation(state)), cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private static TelegramMissionState Normalize(TelegramMissionState? state)
    {
        state ??= TelegramMissionState.Empty;
        return new TelegramMissionState(
            (state.Followups ?? Array.Empty<TelegramFollowup>())
                .Where(item => !string.IsNullOrWhiteSpace(item.Id))
                .TakeLast(MaximumStateItems)
                .Select(item => item with
                {
                    Id = Bound(item.Id, 128),
                    ProjectSlug = Bound(item.ProjectSlug, 128),
                    Title = Bound(item.Title, 512),
                    Summary = Bound(item.Summary, 4096),
                })
                .ToArray(),
            (state.Questions ?? Array.Empty<TelegramQuestion>())
                .Where(item => !string.IsNullOrWhiteSpace(item.Id))
                .TakeLast(MaximumStateItems)
                .Select(item => item with
                {
                    Id = Bound(item.Id, 128),
                    ProjectSlug = Bound(item.ProjectSlug, 128),
                    Title = Bound(item.Title, 512),
                    Answer = item.Answer is null ? null : Bound(item.Answer, 4096),
                    AnsweredBy = item.AnsweredBy is null ? null : Bound(item.AnsweredBy, 128),
                })
                .ToArray());
    }

    private static IReadOnlyList<T> Upsert<T>(
        IReadOnlyList<T> items,
        T item,
        Func<T, string> id)
    {
        var updated = items
            .Where(existing => !string.Equals(id(existing), id(item), StringComparison.Ordinal))
            .Append(item)
            .TakeLast(MaximumStateItems)
            .ToArray();
        return updated;
    }

    private static IReadOnlyList<T> ReplaceAt<T>(IReadOnlyList<T> items, int index, T value)
    {
        T[] updated = items.ToArray();
        updated[index] = value;
        return updated;
    }

    private static int FindFollowup(TelegramMissionState state, string id) =>
        FindById(state.Followups, id, item => item.Id);

    private static int FindQuestion(TelegramMissionState state, string id) =>
        FindById(state.Questions, id, item => item.Id);

    private static int FindById<T>(IReadOnlyList<T> items, string id, Func<T, string> selector)
    {
        for (int index = 0; index < items.Count; index++)
        {
            if (string.Equals(selector(items[index]), id, StringComparison.Ordinal))
            {
                return index;
            }
        }

        return -1;
    }

    private static TelegramCommandResponse Ok(string message) => new(true, message);

    private static string Bound(string? value, int maximumCharacters)
    {
        string normalized = (value ?? string.Empty).Trim();
        return normalized.Length <= maximumCharacters
            ? normalized
            : normalized[..maximumCharacters];
    }
}
