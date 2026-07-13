using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Run;

/// <summary>
/// JSON command adapter for the companion CLI. The wire surface is bounded and
/// delegates execution to an injected step handler; no command text is shelled
/// out by this adapter.
/// </summary>
public sealed class CompanionCliHeadlessRunHandler
{
    private const int MaxSteps = 128;
    private const int MaxPayloadCharacters = 64 * 1024;
    private readonly HeadlessRunService _runs;
    private readonly Func<HeadlessRunStep, CancellationToken, Task<HeadlessRunStepResult>> _stepHandler;

    public CompanionCliHeadlessRunHandler(
        HeadlessRunService runs,
        Func<HeadlessRunStep, CancellationToken, Task<HeadlessRunStepResult>> stepHandler)
    {
        _runs = runs ?? throw new ArgumentNullException(nameof(runs));
        _stepHandler = stepHandler ?? throw new ArgumentNullException(nameof(stepHandler));
    }

    public async Task<object?> SubmitAsync(JsonElement request, CancellationToken cancellationToken)
    {
        HeadlessRunDefinition definition = ParseDefinition(request);
        HeadlessRunResult result = await _runs
            .ExecuteAsync(definition, _stepHandler, cancellationToken)
            .ConfigureAwait(false);
        return ToWireResult(result);
    }

    public async Task<object?> ResumeAsync(JsonElement request, CancellationToken cancellationToken)
    {
        HeadlessRunDefinition definition = ParseDefinition(request);
        HeadlessRunResult result = await _runs
            .ResumeAsync(definition, _stepHandler, cancellationToken)
            .ConfigureAwait(false);
        return ToWireResult(result);
    }

    /// <summary>Lists interrupted runs without re-executing any step.</summary>
    public async Task<object?> RecoverAsync(JsonElement request, CancellationToken cancellationToken)
    {
        IReadOnlyList<RecoverableHeadlessRun> runs = await _runs
            .RecoverAsync(cancellationToken)
            .ConfigureAwait(false);
        return runs
            .Select(run => new
            {
                runId = run.RunId,
                completedStepIds = run.CompletedStepIds,
                failedStepId = run.FailedStepId,
                error = run.Error,
            })
            .ToArray();
    }

    private static HeadlessRunDefinition ParseDefinition(JsonElement request)
    {
        if (!request.TryGetProperty("runId", out JsonElement runIdElement)
            || runIdElement.ValueKind != JsonValueKind.String
            || string.IsNullOrWhiteSpace(runIdElement.GetString()))
        {
            throw new ArgumentException("runId is required.", nameof(request));
        }

        if (!request.TryGetProperty("steps", out JsonElement stepsElement)
            || stepsElement.ValueKind != JsonValueKind.Array
            || stepsElement.GetArrayLength() > MaxSteps)
        {
            throw new ArgumentException("steps must be an array of at most 128 items.", nameof(request));
        }

        var steps = new List<HeadlessRunStep>();
        foreach (JsonElement item in stepsElement.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object
                || !TryString(item, "id", out string? id)
                || !TryString(item, "kind", out string? kind))
            {
                throw new ArgumentException("Each step requires non-empty id and kind.", nameof(request));
            }

            string payload = item.TryGetProperty("payload", out JsonElement payloadElement)
                && payloadElement.ValueKind == JsonValueKind.String
                ? payloadElement.GetString() ?? string.Empty
                : string.Empty;
            if (payload.Length > MaxPayloadCharacters)
            {
                throw new ArgumentException("A step payload exceeds the safety limit.", nameof(request));
            }

            var dependencies = new List<string>();
            if (item.TryGetProperty("dependsOn", out JsonElement dependencyElement))
            {
                if (dependencyElement.ValueKind != JsonValueKind.Array)
                {
                    throw new ArgumentException("dependsOn must be an array.", nameof(request));
                }

                foreach (JsonElement dependency in dependencyElement.EnumerateArray())
                {
                    if (dependency.ValueKind != JsonValueKind.String
                        || string.IsNullOrWhiteSpace(dependency.GetString()))
                    {
                        throw new ArgumentException("dependsOn entries must be non-empty strings.", nameof(request));
                    }

                    dependencies.Add(dependency.GetString()!);
                }
            }

            steps.Add(new HeadlessRunStep(id!, kind!, payload, dependencies));
        }

        return new HeadlessRunDefinition(runIdElement.GetString()!, steps);
    }

    private static object ToWireResult(HeadlessRunResult result) => new
    {
        runId = result.RunId,
        state = result.State.ToString(),
        completedStepIds = result.CompletedStepIds,
        failedStepId = result.FailedStepId,
        error = result.Error,
    };

    private static bool TryString(JsonElement item, string property, out string? value)
    {
        value = null;
        if (!item.TryGetProperty(property, out JsonElement element)
            || element.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = element.GetString();
        return !string.IsNullOrWhiteSpace(value);
    }
}

/// <summary>
/// Safe built-in step set used by the desktop composition. Agent/provider work
/// must be supplied through an explicit handler; arbitrary shell execution is
/// never a default capability.
/// </summary>
public static class BuiltInHeadlessRunSteps
{
    public static async Task<HeadlessRunStepResult> ExecuteAsync(
        HeadlessRunStep step,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(step);
        switch (step.Kind.Trim().ToLowerInvariant())
        {
            case "noop":
            case "health":
                return HeadlessRunStepResult.Ok();
            case "delay":
                if (!int.TryParse(step.Payload, out int milliseconds) || milliseconds is < 0 or > 30_000)
                {
                    return HeadlessRunStepResult.Fail("delay_milliseconds_must_be_0_to_30000");
                }

                await Task.Delay(milliseconds, cancellationToken).ConfigureAwait(false);
                return HeadlessRunStepResult.Ok();
            default:
                return HeadlessRunStepResult.Fail("step_kind_unavailable_without_explicit_provider");
        }
    }
}
