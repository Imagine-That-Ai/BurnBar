using System.Text.Json.Serialization;
using OpenBurnBar.App.Presentation.Quota;

namespace OpenBurnBar.App.CloudSync;

internal static class DomainCoreShadowEvidenceUploader
{
    private sealed record SubmitResponse(
        [property: JsonPropertyName("accepted")] int Accepted,
        [property: JsonPropertyName("duplicates")] int Duplicates);

    internal static void Configure(CloudSyncCompositionRoot root)
    {
        ArgumentNullException.ThrowIfNull(root);
        DomainCoreQuotaShadowEvidence.ConfigureUploader(async (samples, cancellationToken) =>
        {
            SubmitResponse response = await root.Callable
                .InvokeAsync<object, SubmitResponse>(
                    "submitDomainCoreShadowSamples",
                    new { samples },
                    cancellationToken)
                .ConfigureAwait(false);
            if (response.Accepted + response.Duplicates != samples.Count)
            {
                throw new InvalidDataException("Domain-core shadow sample acknowledgement count is invalid.");
            }
        });
    }
}
