using System;
using System.Collections.Generic;
using System.Linq;
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

    public ElderWandFusionOrchestrator(
        Func<FusionToolCall, CancellationToken, Task<FusionToolResult>> toolHandler)
    {
        _toolHandler = toolHandler ?? throw new ArgumentNullException(nameof(toolHandler));
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

        var transcript = new List<FusionStepRecord>();
        int steps = 0;
        string state = request.SeedPrompt;

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

            if (!result.Succeeded)
            {
                return new FusionRunResult(false, transcript, result.Error ?? "tool_failed");
            }

            if (result.Terminal)
            {
                return new FusionRunResult(true, transcript, null);
            }

            state = result.Output ?? state;
        }

        return new FusionRunResult(false, transcript, "max_steps_exceeded");
    }
}

public sealed record FusionRunRequest(string SeedPrompt, int MaxSteps = 8);

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
