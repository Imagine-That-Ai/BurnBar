using System.Text.Json.Serialization;
using OpenBurnBar.App.Presentation.Quota;
using OpenBurnBar.CloudSync.Crypto;

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
            if (!DomainCoreQuotaShadowEvidence.ValidAcknowledgementCounts(
                    response.Accepted,
                    response.Duplicates,
                    samples.Count))
            {
                throw new InvalidDataException("Domain-core shadow sample acknowledgement count is invalid.");
            }
        });
        DomainCoreCloudVaultShadowEvidence.Configure(comparison =>
            DomainCoreQuotaShadowEvidence.RecordComparison(
                comparison.Domain,
                comparison.Slice,
                comparison.Operation,
                comparison.LoadedCoreVersion,
                comparison.LoadedCoreAbiVersion,
                comparison.LoadedCoreSourceSha256,
                comparison.Outcome == "match",
                comparison.MismatchCategory,
                comparison.LegacyMicros,
                comparison.RustMicros));
    }
}
