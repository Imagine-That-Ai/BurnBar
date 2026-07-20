using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Planning;

/// <summary>Authenticated companion adapter for side-effect-free planning.</summary>
public sealed class CompanionCliPlannerHandler
{
    private readonly BurnBarPlannerService _planner;

    public CompanionCliPlannerHandler(BurnBarPlannerService planner)
    {
        _planner = planner ?? throw new ArgumentNullException(nameof(planner));
    }

    public Task<object?> PlanAsync(JsonElement request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        BurnBarPlannedRun planned;
        if (request.TryGetProperty("input", out JsonElement input))
        {
            planned = _planner.PlanTyped(_planner.ParseTypedInput(input));
        }
        else
        {
            string prompt = request.TryGetProperty("prompt", out JsonElement promptElement)
                && promptElement.ValueKind == JsonValueKind.String
                ? promptElement.GetString() ?? string.Empty
                : string.Empty;
            JsonElement? metadata = request.TryGetProperty("metadata", out JsonElement metadataElement)
                ? metadataElement.Clone()
                : null;
            planned = _planner.PlanRaw(prompt, metadata);
        }

        return Task.FromResult<object?>(BurnBarPlannerWire.PlannedRun(planned));
    }
}
