using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Run;

public enum HeadlessRunState
{
    Queued,
    Running,
    Succeeded,
    Failed,
    Cancelled,
    Recoverable,
}

public sealed record HeadlessRunStep(
    string Id,
    string Kind,
    string Payload,
    IReadOnlyList<string>? DependsOn = null)
{
    public IReadOnlyList<string> Dependencies { get; } =
        DependsOn is null
            ? Array.Empty<string>()
            : new ReadOnlyCollection<string>(DependsOn.ToArray());
}

public sealed record HeadlessRunDefinition(string RunId, IReadOnlyList<HeadlessRunStep> Steps);

public sealed record HeadlessRunStepResult(bool Succeeded, string? Error = null)
{
    public static HeadlessRunStepResult Ok() => new(true);

    public static HeadlessRunStepResult Fail(string error) => new(false, error);
}

public sealed record HeadlessRunResult(
    string RunId,
    HeadlessRunState State,
    IReadOnlyList<string> CompletedStepIds,
    string? FailedStepId,
    string? Error);

public sealed record HeadlessRunJournalEntry(
    string RunId,
    HeadlessRunState State,
    string? StepId,
    string? Error,
    DateTimeOffset RecordedAt);

public sealed record RecoverableHeadlessRun(
    string RunId,
    IReadOnlyList<string> CompletedStepIds,
    string? FailedStepId,
    string? Error);

public interface IHeadlessRunJournal
{
    Task AppendAsync(HeadlessRunJournalEntry entry, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<HeadlessRunJournalEntry>> ReadAllAsync(
        CancellationToken cancellationToken = default);
}

/// <summary>
/// Crash-tolerant append-only journal. Each line contains state metadata only;
/// step payloads and credentials never enter the recovery file.
/// </summary>
public sealed class JsonLinesHeadlessRunJournal : IHeadlessRunJournal
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly string _path;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public JsonLinesHeadlessRunJournal(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new ArgumentException("A journal path is required.", nameof(path));
        }

        _path = Path.GetFullPath(path);
    }

    public async Task AppendAsync(
        HeadlessRunJournalEntry entry,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ValidateEntry(entry);
        string? directory = Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        string line = JsonSerializer.Serialize(entry, JsonOptions) + Environment.NewLine;
        byte[] bytes = System.Text.Encoding.UTF8.GetBytes(line);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using var stream = new FileStream(
                _path,
                FileMode.Append,
                FileAccess.Write,
                FileShare.Read,
                bufferSize: 4096,
                options: FileOptions.WriteThrough | FileOptions.Asynchronous);
            await stream.WriteAsync(bytes.AsMemory(), cancellationToken).ConfigureAwait(false);
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            stream.Flush(flushToDisk: true);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<IReadOnlyList<HeadlessRunJournalEntry>> ReadAllAsync(
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(_path))
        {
            return Array.Empty<HeadlessRunJournalEntry>();
        }

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            string[] lines = await File.ReadAllLinesAsync(_path, cancellationToken).ConfigureAwait(false);
            var entries = new List<HeadlessRunJournalEntry>(lines.Length);
            foreach (string line in lines)
            {
                if (string.IsNullOrWhiteSpace(line))
                {
                    continue;
                }

                HeadlessRunJournalEntry? entry = JsonSerializer.Deserialize<HeadlessRunJournalEntry>(line, JsonOptions);
                if (entry is null)
                {
                    throw new InvalidDataException("The headless-run journal contains a null entry.");
                }

                ValidateEntry(entry);
                entries.Add(entry);
            }

            return entries;
        }
        catch (JsonException error)
        {
            throw new InvalidDataException("The headless-run journal is corrupt.", error);
        }
        finally
        {
            _gate.Release();
        }
    }

    private static void ValidateEntry(HeadlessRunJournalEntry entry)
    {
        if (string.IsNullOrWhiteSpace(entry.RunId))
        {
            throw new InvalidDataException("A headless-run journal entry is missing its run id.");
        }
    }
}

/// <summary>
/// Dependency-aware, resumable headless run engine. It is deliberately
/// sequential at the journal boundary: deterministic ordering makes recovery
/// safe, while each step can still perform its own concurrent work.
/// </summary>
public sealed class HeadlessRunService
{
    private readonly IHeadlessRunJournal _journal;

    public HeadlessRunService(IHeadlessRunJournal journal)
    {
        _journal = journal ?? throw new ArgumentNullException(nameof(journal));
    }

    public Task<HeadlessRunResult> ExecuteAsync(
        HeadlessRunDefinition definition,
        Func<HeadlessRunStep, CancellationToken, Task<HeadlessRunStepResult>> handler,
        CancellationToken cancellationToken = default) =>
        ExecuteCoreAsync(definition, handler, new HashSet<string>(StringComparer.Ordinal), resumed: false, cancellationToken);

    public async Task<HeadlessRunResult> ResumeAsync(
        HeadlessRunDefinition definition,
        Func<HeadlessRunStep, CancellationToken, Task<HeadlessRunStepResult>> handler,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(definition);
        IReadOnlyList<HeadlessRunJournalEntry> entries = await _journal
            .ReadAllAsync(cancellationToken)
            .ConfigureAwait(false);
        HashSet<string> completed = entries
            .Where(entry => entry.RunId == definition.RunId && entry.State == HeadlessRunState.Succeeded && entry.StepId is not null)
            .Select(entry => entry.StepId!)
            .ToHashSet(StringComparer.Ordinal);
        return await ExecuteCoreAsync(definition, handler, completed, resumed: true, cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<RecoverableHeadlessRun>> RecoverAsync(
        CancellationToken cancellationToken = default)
    {
        IReadOnlyList<HeadlessRunJournalEntry> entries = await _journal
            .ReadAllAsync(cancellationToken)
            .ConfigureAwait(false);
        var recovered = new List<RecoverableHeadlessRun>();
        foreach (IGrouping<string, HeadlessRunJournalEntry> group in entries.GroupBy(entry => entry.RunId))
        {
            HeadlessRunJournalEntry[] history = group.ToArray();
            int attemptStart = Array.FindLastIndex(history, entry =>
                entry.State is HeadlessRunState.Queued or HeadlessRunState.Recoverable);
            HeadlessRunJournalEntry[] latestAttempt = attemptStart >= 0
                ? history[attemptStart..]
                : history;
            HeadlessRunJournalEntry? latest = latestAttempt.LastOrDefault();
            bool hasTerminalEntry = latest is not null && (
                (latest.State == HeadlessRunState.Succeeded && latest.StepId is null)
                || latest.State is HeadlessRunState.Failed or HeadlessRunState.Cancelled);
            bool hasActiveEntry = latestAttempt.Any(entry =>
                entry.State is HeadlessRunState.Running or HeadlessRunState.Queued or HeadlessRunState.Recoverable);
            if (hasTerminalEntry || !hasActiveEntry)
            {
                continue;
            }

            recovered.Add(new RecoverableHeadlessRun(
                group.Key,
                group.Where(entry => entry.State == HeadlessRunState.Succeeded && entry.StepId is not null)
                    .Select(entry => entry.StepId!)
                    .Distinct(StringComparer.Ordinal)
                    .ToArray(),
                group.LastOrDefault(entry => entry.State == HeadlessRunState.Failed)?.StepId,
                group.LastOrDefault(entry => entry.State == HeadlessRunState.Failed)?.Error));
        }

        return recovered;
    }

    private async Task<HeadlessRunResult> ExecuteCoreAsync(
        HeadlessRunDefinition definition,
        Func<HeadlessRunStep, CancellationToken, Task<HeadlessRunStepResult>> handler,
        HashSet<string> completed,
        bool resumed,
        CancellationToken cancellationToken)
    {
        ValidateDefinition(definition);
        ArgumentNullException.ThrowIfNull(handler);
        await AppendAsync(definition.RunId, resumed ? HeadlessRunState.Recoverable : HeadlessRunState.Queued, null, null, cancellationToken)
            .ConfigureAwait(false);
        await AppendAsync(definition.RunId, HeadlessRunState.Running, null, null, cancellationToken)
            .ConfigureAwait(false);

        try
        {
            while (completed.Count < definition.Steps.Count)
            {
                cancellationToken.ThrowIfCancellationRequested();
                HeadlessRunStep? next = definition.Steps.FirstOrDefault(step =>
                    !completed.Contains(step.Id)
                    && step.Dependencies.All(completed.Contains));
                if (next is null)
                {
                    return await FinishAsync(
                        definition.RunId,
                        HeadlessRunState.Failed,
                        completed,
                        null,
                        "mission_dependency_cycle_or_missing_dependency",
                        cancellationToken).ConfigureAwait(false);
                }

                HeadlessRunStepResult result;
                try
                {
                    result = await handler(next, cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch (Exception)
                {
                    return await FinishAsync(
                        definition.RunId,
                        HeadlessRunState.Failed,
                        completed,
                        next.Id,
                        "headless_step_handler_failed",
                        CancellationToken.None).ConfigureAwait(false);
                }
                if (!result.Succeeded)
                {
                    return await FinishAsync(
                        definition.RunId,
                        HeadlessRunState.Failed,
                        completed,
                        next.Id,
                        result.Error ?? "headless_step_failed",
                        cancellationToken).ConfigureAwait(false);
                }

                completed.Add(next.Id);
                await AppendAsync(definition.RunId, HeadlessRunState.Succeeded, next.Id, null, cancellationToken)
                    .ConfigureAwait(false);
            }

            return await FinishAsync(
                definition.RunId,
                HeadlessRunState.Succeeded,
                completed,
                null,
                null,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            await AppendAsync(definition.RunId, HeadlessRunState.Cancelled, null, "cancelled", CancellationToken.None)
                .ConfigureAwait(false);
            throw;
        }
    }

    private async Task<HeadlessRunResult> FinishAsync(
        string runId,
        HeadlessRunState state,
        HashSet<string> completed,
        string? failedStepId,
        string? error,
        CancellationToken cancellationToken)
    {
        await AppendAsync(runId, state, failedStepId, error, cancellationToken).ConfigureAwait(false);
        return new HeadlessRunResult(runId, state, completed.ToArray(), failedStepId, error);
    }

    private Task AppendAsync(
        string runId,
        HeadlessRunState state,
        string? stepId,
        string? error,
        CancellationToken cancellationToken) =>
        _journal.AppendAsync(new HeadlessRunJournalEntry(runId, state, stepId, error, DateTimeOffset.UtcNow), cancellationToken);

    private static void ValidateDefinition(HeadlessRunDefinition definition)
    {
        ArgumentNullException.ThrowIfNull(definition);
        if (string.IsNullOrWhiteSpace(definition.RunId))
        {
            throw new ArgumentException("A run id is required.", nameof(definition));
        }

        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (HeadlessRunStep step in definition.Steps)
        {
            if (string.IsNullOrWhiteSpace(step.Id) || !ids.Add(step.Id))
            {
                throw new ArgumentException("Run step ids must be unique and non-empty.", nameof(definition));
            }
        }

        foreach (HeadlessRunStep step in definition.Steps)
        {
            if (step.Dependencies.Any(dependency => !ids.Contains(dependency)))
            {
                throw new ArgumentException($"Run step '{step.Id}' references a missing dependency.", nameof(definition));
            }
        }
    }
}
