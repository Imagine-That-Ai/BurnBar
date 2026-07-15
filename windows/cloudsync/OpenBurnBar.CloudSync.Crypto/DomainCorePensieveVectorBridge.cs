using System;
using System.Collections.Generic;
using System.Linq;
using DomainCore = uniffi.openburnbar_domain_ffi.OpenburnbarDomainFfiMethods;

namespace OpenBurnBar.CloudSync.Crypto;

public static class DomainCorePensieveVectorBridge
{
    public static double[] Cloak(
        IReadOnlyList<double> vector,
        byte[] vaultKey,
        string modelVersion,
        Func<double[]> legacy) =>
        DomainCoreCloudVaultBridge.Apply(
            "pensieve_vector_cloak",
            () => DomainCore.PensieveVectorCloak(vector.ToList(), vaultKey, modelVersion).ToArray(),
            legacy,
            Equivalent);

    public static double[] Normalize(
        IReadOnlyList<double> vector,
        Func<double[]> legacy)
    {
        ArgumentNullException.ThrowIfNull(vector);
        return DomainCoreCloudVaultBridge.Apply(
            "pensieve_l2_normalize",
            () => DomainCore.PensieveL2Normalize(vector.ToList()).ToArray(),
            legacy,
            Equivalent);
    }

    public static double[] DeterministicEmbed(
        string text,
        uint dimensions,
        bool isQuery,
        Func<double[]> legacy) =>
        DomainCoreCloudVaultBridge.Apply(
            "pensieve_deterministic_embed",
            () => DomainCore.PensieveDeterministicEmbed(text, dimensions, isQuery).ToArray(),
            legacy,
            Equivalent);

    public static double[] DeterministicEmbedAndCloak(
        string text,
        uint dimensions,
        bool isQuery,
        byte[] vaultKey,
        string modelVersion,
        Func<double[]> legacy) =>
        DomainCoreCloudVaultBridge.Apply(
            "pensieve_deterministic_embed_and_cloak",
            () => DomainCore.PensieveDeterministicEmbedAndCloak(
                text, dimensions, isQuery, vaultKey, modelVersion).ToArray(),
            legacy,
            Equivalent);

    private static bool Equivalent(IReadOnlyList<double> left, IReadOnlyList<double> right) =>
        left.Count == right.Count && left.Zip(right, static (a, b) => Math.Abs(a - b) < 1e-12).All(static value => value);
}
