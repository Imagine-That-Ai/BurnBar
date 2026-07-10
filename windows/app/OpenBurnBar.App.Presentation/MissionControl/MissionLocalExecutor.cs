using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.MissionControl;

/// <summary>
/// F2 local Mission Control step executor (in-process DAG step runner).
/// Complements Firestore dispatch (F1 client) with local sequential execution.
/// </summary>
public sealed class MissionLocalExecutor
{
    /// <summary>Execute steps in order; fail-closed stops on first step failure.</summary>
    public async Task<MissionLocalExecutionResult> RunAsync(
        IReadOnlyList<MissionLocalStep> steps,
        Func<MissionLocalStep, CancellationToken, Task<MissionLocalStepResult>> handler,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(steps);
        ArgumentNullException.ThrowIfNull(handler);

        var completed = new List<string>();
        foreach (MissionLocalStep step in steps)
        {
            cancellationToken.ThrowIfCancellationRequested();
            MissionLocalStepResult result = await handler(step, cancellationToken).ConfigureAwait(false);
            if (!result.Succeeded)
            {
                return new MissionLocalExecutionResult(
                    Succeeded: false,
                    CompletedStepIds: completed,
                    FailedStepId: step.Id,
                    Error: result.Error ?? "step failed");
            }

            completed.Add(step.Id);
        }

        return new MissionLocalExecutionResult(true, completed, null, null);
    }
}

public sealed record MissionLocalStep(string Id, string Kind, string Payload);

public sealed record MissionLocalStepResult(bool Succeeded, string? Error)
{
    public static MissionLocalStepResult Ok() => new(true, null);

    public static MissionLocalStepResult Fail(string error) => new(false, error);
}

public sealed record MissionLocalExecutionResult(
    bool Succeeded,
    IReadOnlyList<string> CompletedStepIds,
    string? FailedStepId,
    string? Error);
