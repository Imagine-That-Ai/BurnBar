using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.ElderWand;

/// <summary>
/// F2 Elder Wand fusion orchestrator: runs judge/analysis/tool steps in a
/// fail-closed loop with budget caps. Presets-only UI remains F1; this is the
/// live fusion tool loop core.
/// </summary>
public sealed class ElderWandFusionOrchestrator
{
    private readonly Func<FusionToolCall, CancellationToken, Task<FusionToolResult>> _toolHandler;
    private readonly IFusionRunJournal? _journal;

    public ElderWandFusionOrchestrator(
        Func<FusionToolCall, CancellationToken, Task<FusionToolResult>> toolHandler,
        IFusionRunJournal? journal = null)
    {
        _toolHandler = toolHandler ?? throw new ArgumentNullException(nameof(toolHandler));
        _journal = journal;
    }

    public async Task<FusionRunResult> RunAsync(
        FusionRunRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.MaxSteps <= 0)
        {
            return FusionRunResult.Fail("max_steps_must_be_positive");
        }

        string runId = string.IsNullOrWhiteSpace(request.RunId)
            ? "fusion-" + Guid.NewGuid().ToString("N")
            : request.RunId;
        var transcript = new List<FusionStepRecord>();
        int steps = 0;
        string state = request.SeedPrompt;
        await AppendAsync(new FusionJournalEntry(runId, "running", 0, null, null, null), cancellationToken)
            .ConfigureAwait(false);

        try
        {
            while (steps < request.MaxSteps)
            {
                cancellationToken.ThrowIfCancellationRequested();
                steps++;

                var call = new FusionToolCall(
                    Step: steps,
                    Kind: steps == 1 ? "judge" : "analyze",
                    Payload: state);
                FusionToolResult result = await _toolHandler(call, cancellationToken).ConfigureAwait(false);
                transcript.Add(new FusionStepRecord(call, result));
                await AppendAsync(
                    new FusionJournalEntry(
                        runId,
                        result.Succeeded ? "step_succeeded" : "failed",
                        steps,
                        call.Kind,
                        Digest(result.Output ?? state),
                        result.Error),
                    cancellationToken).ConfigureAwait(false);

                if (!result.Succeeded)
                {
                    return await FinishAsync(runId, false, transcript, result.Error ?? "tool_failed", cancellationToken)
                        .ConfigureAwait(false);
                }

                if (result.Terminal)
                {
                    return await FinishAsync(runId, true, transcript, null, cancellationToken).ConfigureAwait(false);
                }

                state = result.Output ?? state;
            }

            return await FinishAsync(runId, false, transcript, "max_steps_exceeded", cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            await AppendAsync(new FusionJournalEntry(runId, "cancelled", steps, null, null, "cancelled"), CancellationToken.None)
                .ConfigureAwait(false);
            throw;
        }
    }

    private async Task<FusionRunResult> FinishAsync(
        string runId,
        bool succeeded,
        IReadOnlyList<FusionStepRecord> transcript,
        string? error,
        CancellationToken cancellationToken)
    {
        await AppendAsync(
            new FusionJournalEntry(runId, succeeded ? "succeeded" : "failed", transcript.Count, null, null, error),
            cancellationToken).ConfigureAwait(false);
        return new FusionRunResult(succeeded, transcript, error);
    }

    private Task AppendAsync(FusionJournalEntry entry, CancellationToken cancellationToken) =>
        _journal?.AppendAsync(entry, cancellationToken) ?? Task.CompletedTask;

    private static string Digest(string value) =>
        Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(value)));
}

public sealed record FusionRunRequest(string SeedPrompt, int MaxSteps = 8, string? RunId = null);

public sealed record FusionToolCall(int Step, string Kind, string Payload);

public sealed record FusionToolResult(bool Succeeded, bool Terminal, string? Output, string? Error)
{
    public static FusionToolResult Continue(string output) => new(true, false, output, null);

    public static FusionToolResult Done(string output) => new(true, true, output, null);

    public static FusionToolResult Fail(string error) => new(false, true, null, error);
}

public sealed record FusionStepRecord(FusionToolCall Call, FusionToolResult Result);

public sealed record FusionRunResult(
    bool Succeeded,
    IReadOnlyList<FusionStepRecord> Steps,
    string? Error)
{
    public static FusionRunResult Fail(string error) =>
        new(false, Array.Empty<FusionStepRecord>(), error);
}

public sealed record FusionJournalEntry(
    string RunId,
    string State,
    int Step,
    string? Kind,
    string? OutputSha256,
    string? Error);

public interface IFusionRunJournal
{
    Task AppendAsync(FusionJournalEntry entry, CancellationToken cancellationToken = default);
}

/// <summary>Append-only fusion journal containing metadata and output digests, never payloads.</summary>
public sealed class JsonLinesFusionRunJournal : IFusionRunJournal
{
    private readonly string _path;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public JsonLinesFusionRunJournal(string path)
    {
        _path = string.IsNullOrWhiteSpace(path)
            ? throw new ArgumentException("A journal path is required.", nameof(path))
            : Path.GetFullPath(path);
    }

    public async Task AppendAsync(FusionJournalEntry entry, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(entry.RunId) || string.IsNullOrWhiteSpace(entry.State))
        {
            throw new ArgumentException("Fusion journal entries require run id and state.", nameof(entry));
        }

        string? directory = Path.GetDirectoryName(_path);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        string line = JsonSerializer.Serialize(entry) + Environment.NewLine;
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using var stream = new FileStream(
                _path,
                FileMode.Append,
                FileAccess.Write,
                FileShare.Read,
                bufferSize: 4096,
                options: FileOptions.Asynchronous | FileOptions.WriteThrough);
            await using var writer = new StreamWriter(stream, System.Text.Encoding.UTF8, 4096, leaveOpen: true);
            await writer.WriteAsync(line.AsMemory(), cancellationToken).ConfigureAwait(false);
            await writer.FlushAsync(cancellationToken).ConfigureAwait(false);
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }
}
