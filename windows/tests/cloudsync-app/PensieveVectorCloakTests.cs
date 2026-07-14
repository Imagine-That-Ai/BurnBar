using OpenBurnBar.App.CloudSync.Pensieve;
using Xunit;

namespace OpenBurnBar.App.CloudSync.Tests;

public sealed class PensieveVectorCloakTests
{
    private static readonly byte[] Key = Enumerable.Repeat((byte)0x42, 32).ToArray();

    [Fact]
    public void Cloak_MatchesTypeScriptAndSwiftGoldenHeads()
    {
        var basis = new double[PensieveVectorCloak.EmbeddingDimensions];
        basis[5] = 1;
        double[] result = PensieveVectorCloak.Cloak(basis, Key, "hashing-bow-v1");
        double[] expected =
        {
            0.024962057620774702,
            -0.0012100986493098734,
            0.01970170194431331,
            -0.01876288243402278,
            0.050834395709711204,
            0.8367944634995997,
        };

        for (int index = 0; index < expected.Length; index++)
        {
            Assert.Equal(expected[index], result[index], precision: 12);
        }
    }

    [Fact]
    public void EmbedAndCloak_MatchesTypeScriptAndSwiftGoldenHead()
    {
        double[] result = PensieveVectorCloak.EmbedAndCloak(
            "hosted minimax encrypted session search",
            Key);
        double[] expected =
        {
            -0.06038318803677569,
            0.015806595688146123,
            -0.01819074005506563,
            -0.013937252354238351,
            -0.005114345741968682,
            0.03677180389002842,
        };

        for (int index = 0; index < expected.Length; index++)
        {
            Assert.Equal(expected[index], result[index], precision: 12);
        }
    }

    [Fact]
    public void Cloak_IsKeySpecificAndPreservesNormAndInnerProduct()
    {
        double[] first = PensieveVectorCloak.DeterministicEmbed("pensieve repo docs and notes");
        double[] second = PensieveVectorCloak.DeterministicEmbed("repo documentation knowledge memory");
        double[] cloakedFirst = PensieveVectorCloak.Cloak(first, Key);
        double[] cloakedSecond = PensieveVectorCloak.Cloak(second, Key);
        byte[] otherKey = Enumerable.Repeat((byte)0x24, 32).ToArray();

        Assert.Equal(PensieveVectorCloak.EmbeddingDimensions, first.Length);
        Assert.Equal(Norm(first), Norm(cloakedFirst), precision: 9);
        Assert.Equal(Dot(first, second), Dot(cloakedFirst, cloakedSecond), precision: 9);
        Assert.NotEqual(cloakedFirst, PensieveVectorCloak.Cloak(first, otherKey));

        double[] unicode = PensieveVectorCloak.DeterministicEmbed("naïve café résumé");
        Assert.Equal(0.5, unicode[31], precision: 12);  // na
        Assert.Equal(0.5, unicode[185], precision: 12); // caf
        Assert.Equal(0.5, unicode[210], precision: 12); // ve
        Assert.Equal(-0.5, unicode[245], precision: 12); // sum
        Assert.Equal(4, unicode.Count(value => value != 0));
    }

    private static double Dot(IReadOnlyList<double> left, IReadOnlyList<double> right) =>
        left.Zip(right, static (a, b) => a * b).Sum();

    private static double Norm(IReadOnlyList<double> vector) => Math.Sqrt(Dot(vector, vector));
}
