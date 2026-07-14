using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.ElderWand;

/// <summary>
/// Runs the macOS Elder Wand contract: parallel analysis panel, comparison
/// judge, then synthesis through the originating model. Provider routing and
/// tool execution remain injected so this core never owns credentials.
/// </summary>
public sealed class ElderWandFusionOrchestrator
{
    public const int MaximumPromptCharacters = 64 * 1024;
    private const int MaximumToolResultCharacters = 64 * 1024;

    private readonly Func<FusionToolCall, CancellationToken, Task<FusionToolResult>> _completionHandler;
    private readonly IReadOnlyDictionary<string, FusionTool> _tools;
    private readonly IFusionRunJournal? _journal;

    public ElderWandFusionOrchestrator(
        Func<FusionToolCall, CancellationToken, Task<FusionToolResult>> completionHandler,
        IFusionRunJournal? journal = null,
        IEnumerable<FusionTool>? tools = null)
    {
        _completionHandler = completionHandler ?? throw new ArgumentNullException(nameof(completionHandler));
        _journal = journal;
        _tools = (tools ?? Array.Empty<FusionTool>())
            .GroupBy(static tool => tool.Name, StringComparer.Ordinal)
            .ToDictionary(static group => group.Key, static group => group.First(), StringComparer.Ordinal);
    }

    public async Task<FusionRunResult> RunAsync(
        FusionRunRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        string runId = string.IsNullOrWhiteSpace(request.RunId)
            ? "fusion-" + Guid.NewGuid().ToString("N")
            : request.RunId.Trim();
        if (runId.Length > 128)
        {
            return FusionRunResult.Fail("fusion-invalid", "invalid_run_id");
        }
        string prompt = request.SeedPrompt?.Trim() ?? string.Empty;
        if (prompt.Length is 0 or > MaximumPromptCharacters)
        {
            return FusionRunResult.Fail(runId, "invalid_seed_prompt");
        }

        string[] panelModels = (request.AnalysisModels ?? Array.Empty<string>())
            .Select(static model => model.Trim())
            .Where(static model => model.Length > 0)
            .Distinct(StringComparer.Ordinal)
            .Take(ElderWandPreset.AnalysisPanelRange.Upper)
            .ToArray();
        if (panelModels.Length == 0)
        {
            return FusionRunResult.Fail(runId, "analysis_models_required");
        }
        if (panelModels.Any(static model => model.Length > 256))
        {
            return FusionRunResult.Fail(runId, "invalid_model");
        }
        string judgeModel = string.IsNullOrWhiteSpace(request.JudgeModel)
            ? panelModels[0]
            : request.JudgeModel.Trim();
        string originatingModel = string.IsNullOrWhiteSpace(request.OriginatingModel)
            ? judgeModel
            : request.OriginatingModel.Trim();
        if (judgeModel.Length > 256 || originatingModel.Length > 256)
        {
            return FusionRunResult.Fail(runId, "invalid_model");
        }
        int maxToolCalls = ElderWandPreset.MaxToolCallsRange.Clamp(request.MaxSteps);
        var transcript = new List<FusionStepRecord>();

        await AppendAsync(new FusionJournalEntry(runId, "running", 0, null, null, null), cancellationToken)
            .ConfigureAwait(false);
        try
        {
            Task<PanelAnswer?>[] panelTasks = panelModels
                .Select((model, index) => RunPanelMemberAsync(
                    runId,
                    model,
                    index,
                    prompt,
                    request.Conversation,
                    maxToolCalls,
                    cancellationToken))
                .ToArray();
            PanelAnswer?[] completedPanel = await Task.WhenAll(panelTasks).ConfigureAwait(false);
            PanelAnswer[] panel = completedPanel.Where(static answer => answer is not null).Cast<PanelAnswer>().ToArray();
            foreach (PanelAnswer answer in panel.OrderBy(static answer => answer.Index))
            {
                transcript.Add(answer.Step);
            }
            if (panel.Length == 0)
            {
                return await FinishAsync(
                    runId,
                    false,
                    transcript,
                    "all_analysis_models_failed",
                    null,
                    cancellationToken).ConfigureAwait(false);
            }

            string panelBlock = string.Join(
                "\n\n",
                panel.OrderBy(static answer => answer.Index).Select(answer =>
                    $"### Analysis answer {answer.Index + 1} - model `{answer.Model}`\n{answer.Output}"));
            string judgePrompt = BuildJudgePrompt(prompt, panelBlock);
            FusionStepRecord judge = await RunStageAsync(
                runId,
                transcript.Count + 1,
                "judge",
                judgeModel,
                JudgeSystemPrompt,
                judgePrompt,
                maxToolCalls,
                cancellationToken).ConfigureAwait(false);
            transcript.Add(judge);
            string verdict = judge.Result.Succeeded && !string.IsNullOrWhiteSpace(judge.Result.Output)
                ? judge.Result.Output
                : FallbackVerdict(panelBlock);

            var synthesisMessages = new List<FusionMessage>(
                request.Conversation ?? new[] { new FusionMessage("user", prompt) })
            {
                new("system", SynthesisSystemPrompt),
                new("user", BuildSynthesisPrompt(prompt, verdict)),
            };

            FusionStepRecord synthesis = await RunStageAsync(
                runId,
                transcript.Count + 1,
                "synthesis",
                originatingModel,
                string.Empty,
                BuildSynthesisPrompt(prompt, verdict),
                maxToolCalls: 0,
                cancellationToken,
                request.WantsStream,
                synthesisMessages).ConfigureAwait(false);
            transcript.Add(synthesis);
            if (!synthesis.Result.Succeeded)
            {
                return await FinishAsync(
                    runId,
                    false,
                    transcript,
                    synthesis.Result.Error ?? "synthesis_failed",
                    null,
                    cancellationToken).ConfigureAwait(false);
            }

            return await FinishAsync(
                runId,
                true,
                transcript,
                null,
                synthesis.Result,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            await AppendAsync(
                new FusionJournalEntry(runId, "cancelled", transcript.Count, null, null, "cancelled"),
                CancellationToken.None).ConfigureAwait(false);
            throw;
        }
    }

    private async Task<PanelAnswer?> RunPanelMemberAsync(
        string runId,
        string model,
        int index,
        string prompt,
        IReadOnlyList<FusionMessage>? conversation,
        int maxToolCalls,
        CancellationToken cancellationToken)
    {
        FusionStepRecord step = await RunStageAsync(
            runId,
            index + 1,
            "panel",
            model,
            PanelSystemPrompt,
            prompt,
            maxToolCalls,
            cancellationToken,
            initialMessages: conversation).ConfigureAwait(false);
        return step.Result.Succeeded && !string.IsNullOrWhiteSpace(step.Result.Output)
            ? new PanelAnswer(index, model, step.Result.Output, step)
            : null;
    }

    private async Task<FusionStepRecord> RunStageAsync(
        string runId,
        int step,
        string kind,
        string model,
        string systemPrompt,
        string prompt,
        int maxToolCalls,
        CancellationToken cancellationToken,
        bool stream = false,
        IReadOnlyList<FusionMessage>? initialMessages = null)
    {
        var messages = initialMessages is { Count: > 0 }
            ? new List<FusionMessage>(initialMessages)
            : new List<FusionMessage> { new("user", prompt) };
        int executed = 0;
        FusionToolResult result;
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var call = new FusionToolCall(
                step,
                kind,
                prompt,
                model,
                systemPrompt,
                messages.ToArray(),
                IncludeTools: executed < maxToolCalls && _tools.Count > 0,
                Stream: stream && kind == "synthesis",
                Tools: _tools.Values.Select(static tool => tool.Schema).ToArray(),
                RunId: runId);
            result = await _completionHandler(call, cancellationToken).ConfigureAwait(false);
            if (!result.Succeeded || result.ToolCalls is not { Count: > 0 } || executed >= maxToolCalls)
            {
                break;
            }

            messages.Add(new FusionMessage(
                "assistant",
                result.Output ?? string.Empty,
                ToolCalls: result.ToolCalls));
            foreach (FusionRequestedToolCall requested in result.ToolCalls)
            {
                if (executed >= maxToolCalls) break;
                executed++;
                string output = _tools.TryGetValue(requested.Name, out FusionTool? tool)
                    ? await InvokeToolAsync(tool, requested.ArgumentsJson, cancellationToken).ConfigureAwait(false)
                    : $"Tool '{requested.Name}' is not available.";
                messages.Add(new FusionMessage("tool", output, requested.Id));
            }
            if (executed >= maxToolCalls)
            {
                messages.Add(new FusionMessage(
                    "system",
                    "The tool-call budget is exhausted. Finish using the information already gathered."));
            }
        }

        var record = new FusionStepRecord(
            new FusionToolCall(step, kind, prompt, model, systemPrompt, messages.ToArray(), false, stream, RunId: runId),
            result with { Terminal = kind == "synthesis" });
        await AppendAsync(
            new FusionJournalEntry(
                runId,
                result.Succeeded ? "step_succeeded" : "step_failed",
                step,
                kind,
                string.IsNullOrWhiteSpace(result.Output) ? null : Digest(result.Output),
                result.Error),
            cancellationToken).ConfigureAwait(false);
        return record;
    }

    private static async Task<string> InvokeToolAsync(
        FusionTool tool,
        string argumentsJson,
        CancellationToken cancellationToken)
    {
        try
        {
            string output = await tool.InvokeAsync(argumentsJson, cancellationToken).ConfigureAwait(false);
            return output.Length <= MaximumToolResultCharacters
                ? output
                : output[..MaximumToolResultCharacters];
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return $"Tool '{tool.Name}' failed.";
        }
    }

    private async Task<FusionRunResult> FinishAsync(
        string runId,
        bool succeeded,
        IReadOnlyList<FusionStepRecord> transcript,
        string? error,
        FusionToolResult? synthesis,
        CancellationToken cancellationToken)
    {
        await AppendAsync(
            new FusionJournalEntry(runId, succeeded ? "succeeded" : "failed", transcript.Count, null, null, error),
            cancellationToken).ConfigureAwait(false);
        return new FusionRunResult(
            runId,
            succeeded,
            transcript,
            error,
            synthesis?.Output,
            synthesis?.RawBody,
            synthesis?.ContentType ?? "application/json",
            synthesis?.StatusCode ?? (succeeded ? 200 : 502));
    }

    private Task AppendAsync(FusionJournalEntry entry, CancellationToken cancellationToken) =>
        _journal?.AppendAsync(entry, cancellationToken) ?? Task.CompletedTask;

    private static string Digest(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

    private static string BuildJudgePrompt(string prompt, string panelBlock) =>
        $"Original user request:\n{prompt}\n\nCompare the independent answers below. Return only a JSON object with exactly the string fields consensus, contradictions, partial_coverage, unique_insights, and blind_spots.\n\n{panelBlock}";

    private static string BuildSynthesisPrompt(string prompt, string verdict) =>
        $"Original user request:\n{prompt}\n\nWrite the single best final answer using this comparison verdict. Do not mention the panel, judge, or verdict.\n\nJudge verdict:\n{verdict}";

    private static string FallbackVerdict(string panelBlock) =>
        "{\"consensus\":\"judge unavailable; raw analysis follows\",\"contradictions\":\"\",\"partial_coverage\":\"\",\"unique_insights\":\"\",\"blind_spots\":\"\"}\n\n" + panelBlock;

    private sealed record PanelAnswer(int Index, string Model, string Output, FusionStepRecord Step);

    private const string PanelSystemPrompt =
        "You are one independent expert on a panel. Answer thoroughly and accurately. Use web tools when current evidence is helpful.";
    private const string JudgeSystemPrompt =
        "You are a strict comparison judge. Compare answers; do not merge them or answer the original request. Return only the required five-field JSON object.";
    private const string SynthesisSystemPrompt =
        "Write the final direct answer. Resolve contradictions using the strongest evidence and cover valuable unique insights and blind spots.";
}

public sealed record FusionRunRequest(
    string SeedPrompt,
    int MaxSteps = ElderWandPreset.DefaultMaxToolCalls,
    string? RunId = null,
    IReadOnlyList<string>? AnalysisModels = null,
    string? JudgeModel = null,
    string? OriginatingModel = null,
    bool WantsStream = false,
    IReadOnlyList<FusionMessage>? Conversation = null);

public sealed record FusionMessage(
    string Role,
    string Content,
    string? ToolCallId = null,
    IReadOnlyList<FusionRequestedToolCall>? ToolCalls = null);

public sealed record FusionToolCall(
    int Step,
    string Kind,
    string Payload,
    string? Model = null,
    string? SystemPrompt = null,
    IReadOnlyList<FusionMessage>? Messages = null,
    bool IncludeTools = false,
    bool Stream = false,
    IReadOnlyList<JsonElement>? Tools = null,
    string? RunId = null);

public sealed record FusionRequestedToolCall(string Id, string Name, string ArgumentsJson);

public sealed record FusionUsage(
    int InputTokens,
    int OutputTokens,
    int CacheCreationTokens,
    int CacheReadTokens,
    int ReasoningTokens);

public sealed record FusionToolResult(
    bool Succeeded,
    bool Terminal,
    string? Output,
    string? Error,
    IReadOnlyList<FusionRequestedToolCall>? ToolCalls = null,
    FusionUsage? Usage = null,
    byte[]? RawBody = null,
    string ContentType = "application/json",
    int StatusCode = 200)
{
    public static FusionToolResult Continue(string output) => new(true, false, output, null);

    public static FusionToolResult Done(
        string output,
        byte[]? rawBody = null,
        string contentType = "application/json",
        int statusCode = 200) =>
        new(true, true, output, null, RawBody: rawBody, ContentType: contentType, StatusCode: statusCode);

    public static FusionToolResult Fail(string error, int statusCode = 502) =>
        new(false, true, null, error, StatusCode: statusCode);
}

public sealed record FusionTool(
    string Name,
    JsonElement Schema,
    Func<string, CancellationToken, Task<string>> InvokeAsync);

public sealed record FusionStepRecord(FusionToolCall Call, FusionToolResult Result);

public sealed record FusionRunResult(
    string RunId,
    bool Succeeded,
    IReadOnlyList<FusionStepRecord> Steps,
    string? Error,
    string? Output,
    byte[]? RawBody,
    string ContentType,
    int StatusCode)
{
    public static FusionRunResult Fail(string runId, string error) =>
        new(runId, false, Array.Empty<FusionStepRecord>(), error, null, null, "application/json", 400);
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
        if (!string.IsNullOrWhiteSpace(directory)) Directory.CreateDirectory(directory);
        string line = JsonSerializer.Serialize(entry) + Environment.NewLine;
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using var stream = new FileStream(
                _path,
                FileMode.Append,
                FileAccess.Write,
                FileShare.Read,
                4096,
                FileOptions.Asynchronous | FileOptions.WriteThrough);
            await stream.WriteAsync(Encoding.UTF8.GetBytes(line), cancellationToken).ConfigureAwait(false);
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            stream.Flush(flushToDisk: true);
        }
        finally
        {
            _gate.Release();
        }
    }
}
