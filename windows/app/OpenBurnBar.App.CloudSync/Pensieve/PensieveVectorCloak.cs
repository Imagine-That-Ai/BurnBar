using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;

namespace OpenBurnBar.App.CloudSync.Pensieve;

/// <summary>
/// Byte-compatible port of the Pensieve deterministic embedder and per-vault
/// Householder cloak used by Swift and the published TypeScript shim.
/// </summary>
public static class PensieveVectorCloak
{
    public const string EmbeddingModelVersion = "bge-small-en-v1.5-vault-dedup-v1";
    public const string DeterministicModelVersion = "hashing-bow-v1";
    public const int EmbeddingDimensions = 384;
    public const string BgeQueryInstruction = "Represent this sentence for searching relevant passages: ";

    private const int ReflectionCount = 24;
    private static readonly byte[] CloakSalt = Encoding.UTF8.GetBytes("OpenBurnBar-Pensieve-Cloak-Salt-v1");
    private static readonly ConcurrentDictionary<ReflectionCacheKey, double[][]> ReflectionCache = new();

    public static double[] DeterministicEmbed(string text, bool isQuery = false)
    {
        ArgumentNullException.ThrowIfNull(text);
        var accumulator = new double[EmbeddingDimensions];
        string prepared = ((isQuery ? BgeQueryInstruction : string.Empty) + text).ToLowerInvariant();
        var token = new StringBuilder();

        void AddToken()
        {
            if (token.Length < 2)
            {
                token.Clear();
                return;
            }

            byte[] digest = SHA256.HashData(Encoding.UTF8.GetBytes(token.ToString()));
            int index = ((digest[0] << 8) | digest[1]) % EmbeddingDimensions;
            accumulator[index] += (digest[2] & 1) == 0 ? 1 : -1;
            token.Clear();
        }

        foreach (Rune rune in prepared.EnumerateRunes())
        {
            if (IsAsciiLetterOrDigit(rune))
            {
                token.Append(rune.ToString());
            }
            else
            {
                AddToken();
            }
        }
        AddToken();
        return Normalize(accumulator);
    }

    public static double[] EmbedAndCloak(
        string text,
        byte[] vaultKey,
        bool isQuery = false,
        string modelVersion = DeterministicModelVersion) =>
        Cloak(DeterministicEmbed(text, isQuery), vaultKey, modelVersion);

    public static double[] Cloak(
        IReadOnlyList<double> vector,
        byte[] vaultKey,
        string modelVersion = EmbeddingModelVersion)
    {
        ArgumentNullException.ThrowIfNull(vector);
        ArgumentNullException.ThrowIfNull(vaultKey);
        if (vaultKey.Length != 32)
        {
            throw new ArgumentException("A Pensieve vault key must contain 32 bytes.", nameof(vaultKey));
        }
        if (string.IsNullOrWhiteSpace(modelVersion))
        {
            throw new ArgumentException("A Pensieve model version is required.", nameof(modelVersion));
        }
        if (vector.Count == 0 || vector.Any(static value => !double.IsFinite(value)))
        {
            throw new ArgumentException("A finite, non-empty vector is required.", nameof(vector));
        }

        string keyHash = Convert.ToHexString(SHA256.HashData(vaultKey)).ToLowerInvariant()[..32];
        var cacheKey = new ReflectionCacheKey(keyHash, modelVersion, vector.Count);
        double[][] reflections = ReflectionCache.GetOrAdd(
            cacheKey,
            _ => DeriveReflections(vaultKey, modelVersion, vector.Count));
        double[] result = vector.ToArray();
        foreach (double[] reflection in reflections)
        {
            double dot = 0;
            for (int index = 0; index < result.Length; index++)
            {
                dot += reflection[index] * result[index];
            }

            double coefficient = 2 * dot;
            for (int index = 0; index < result.Length; index++)
            {
                result[index] -= coefficient * reflection[index];
            }
        }

        return result;
    }

    public static double[] Normalize(IReadOnlyList<double> vector)
    {
        ArgumentNullException.ThrowIfNull(vector);
        double normSquared = 0;
        for (int index = 0; index < vector.Count; index++)
        {
            normSquared += vector[index] * vector[index];
        }

        double norm = Math.Sqrt(normSquared);
        if (norm == 0)
        {
            return vector.ToArray();
        }

        var result = new double[vector.Count];
        for (int index = 0; index < vector.Count; index++)
        {
            result[index] = vector[index] / norm;
        }
        return result;
    }

    private static double[][] DeriveReflections(byte[] vaultKey, string modelVersion, int dimensions)
    {
        byte[] info = Encoding.UTF8.GetBytes($"OpenBurnBar-Pensieve-Cloak-{modelVersion}-v1");
        int byteLength = checked(ReflectionCount * dimensions * 2 * 4 + 64);
        byte[] keyStream = HkdfKeyStream(vaultKey, CloakSalt, info, byteLength);
        try
        {
            var uniform = new UniformStream(keyStream);
            var vectors = new double[ReflectionCount][];

            for (int reflectionIndex = 0; reflectionIndex < ReflectionCount; reflectionIndex++)
            {
                var vector = new double[dimensions];
                double normSquared = 0;
                for (int index = 0; index < dimensions; index++)
                {
                    double gaussian = NextGaussian(uniform);
                    vector[index] = gaussian;
                    normSquared += gaussian * gaussian;
                }

                double norm = Math.Sqrt(normSquared);
                if (norm == 0)
                {
                    vector[0] = 1;
                }
                else
                {
                    for (int index = 0; index < dimensions; index++)
                    {
                        vector[index] /= norm;
                    }
                }
                vectors[reflectionIndex] = vector;
            }

            return vectors;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(keyStream);
        }
    }

    private static byte[] HkdfKeyStream(byte[] input, byte[] salt, byte[] info, int length)
    {
        byte[] actualSalt = salt.Length == 0 ? new byte[32] : salt;
        byte[] pseudoRandomKey = HMACSHA256.HashData(actualSalt, input);
        var output = new byte[length];
        byte[] previous = Array.Empty<byte>();
        int written = 0;
        byte counter = 1;
        while (written < output.Length)
        {
            var blockInput = new byte[previous.Length + info.Length + 1];
            previous.CopyTo(blockInput, 0);
            info.CopyTo(blockInput, previous.Length);
            blockInput[^1] = counter;
            previous = HMACSHA256.HashData(pseudoRandomKey, blockInput);
            int count = Math.Min(previous.Length, output.Length - written);
            previous.AsSpan(0, count).CopyTo(output.AsSpan(written));
            written += count;
            counter = unchecked((byte)(counter + 1));
        }
        CryptographicOperations.ZeroMemory(pseudoRandomKey);
        CryptographicOperations.ZeroMemory(previous);
        return output;
    }

    private static double NextGaussian(UniformStream stream)
    {
        double first = stream.Next();
        double second = stream.Next();
        return Math.Sqrt(-2 * Math.Log(first)) * Math.Cos(2 * Math.PI * second);
    }

    private static bool IsAsciiLetterOrDigit(Rune rune) =>
        rune.Value is >= 'a' and <= 'z' or >= '0' and <= '9';

    private sealed class UniformStream(byte[] bytes)
    {
        private int _offset;

        public double Next()
        {
            if (_offset + 4 > bytes.Length)
            {
                _offset = 0;
            }
            uint value = BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(_offset, 4));
            _offset += 4;
            return (value + 0.5) / 4_294_967_296.0;
        }
    }

    private sealed record ReflectionCacheKey(string KeyHash, string ModelVersion, int Dimensions);
}
