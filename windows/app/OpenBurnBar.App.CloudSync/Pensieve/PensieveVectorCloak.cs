using OpenBurnBar.CloudSync.Crypto;

namespace OpenBurnBar.App.CloudSync.Pensieve;

/// <summary>Stable facade for legacy, shadow, and Rust-authoritative Pensieve vectors.</summary>
public static class PensieveVectorCloak
{
    public const string EmbeddingModelVersion = "bge-small-en-v1.5-vault-dedup-v1";
    public const string DeterministicModelVersion = "hashing-bow-v1";
    public const int EmbeddingDimensions = 384;
    public const string BgeQueryInstruction = "Represent this sentence for searching relevant passages: ";

    public static double[] DeterministicEmbed(string text, bool isQuery = false) =>
        DomainCorePensieveVectorBridge.DeterministicEmbed(
            text,
            EmbeddingDimensions,
            isQuery,
            () => PensieveVectorLegacy.DeterministicEmbed(text, isQuery));

    public static double[] EmbedAndCloak(
        string text,
        byte[] vaultKey,
        bool isQuery = false,
        string modelVersion = DeterministicModelVersion) =>
        DomainCorePensieveVectorBridge.DeterministicEmbedAndCloak(
            text,
            EmbeddingDimensions,
            isQuery,
            vaultKey,
            modelVersion,
            () => PensieveVectorLegacy.EmbedAndCloak(text, vaultKey, isQuery, modelVersion));

    public static double[] Cloak(
        IReadOnlyList<double> vector,
        byte[] vaultKey,
        string modelVersion = EmbeddingModelVersion) =>
        DomainCorePensieveVectorBridge.Cloak(
            vector,
            vaultKey,
            modelVersion,
            () => PensieveVectorLegacy.Cloak(vector, vaultKey, modelVersion));

    public static double[] Normalize(IReadOnlyList<double> vector) =>
        DomainCorePensieveVectorBridge.Normalize(
            vector,
            () => PensieveVectorLegacy.Normalize(vector));
}
