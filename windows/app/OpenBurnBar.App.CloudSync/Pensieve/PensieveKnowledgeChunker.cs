using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using OpenBurnBar.CloudSync.Crypto;

namespace OpenBurnBar.App.CloudSync.Pensieve;

public static partial class PensieveKnowledgeChunker
{
    public const int MaxChunkBytes = 6 * 1024;
    public const int MaxBatchVectors = 800;
    private const int ChunkOverlapCharacters = 64;

    private static readonly (Regex Pattern, string Replacement)[] SecretPatterns =
    {
        (OpenAiKeyPattern(), "[REDACTED_API_KEY]"),
        (AwsKeyPattern(), "[REDACTED_AWS_KEY]"),
        (GitHubTokenPattern(), "[REDACTED_GH_TOKEN]"),
        (SlackTokenPattern(), "[REDACTED_SLACK_TOKEN]"),
        (PrivateKeyPattern(), "[REDACTED_PRIVATE_KEY]"),
        (BearerPattern(), "[REDACTED_BEARER]"),
        (AssignedSecretPattern(), "[REDACTED_SECRET]"),
        (JwtPattern(), "[REDACTED_JWT]"),
    };

    public static string RedactSecrets(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        string result = text;
        foreach ((Regex pattern, string replacement) in SecretPatterns)
        {
            result = pattern.Replace(result, replacement);
        }
        return result;
    }

    public static IReadOnlyList<string> Chunk(string text, int maxBytes = MaxChunkBytes)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (maxBytes < 128)
        {
            throw new ArgumentOutOfRangeException(nameof(maxBytes), "Pensieve chunks must allow at least 128 bytes.");
        }

        string trimmed = text.Trim();
        if (trimmed.Length == 0)
        {
            return Array.Empty<string>();
        }
        if (Encoding.UTF8.GetByteCount(trimmed) <= maxBytes)
        {
            return new[] { trimmed };
        }

        var chunks = new List<string>();
        var current = new StringBuilder();
        int currentBytes = 0;
        foreach (string word in WhitespacePattern().Split(trimmed).Where(static value => value.Length > 0))
        {
            AppendByteBoundedWord(chunks, current, ref currentBytes, word, maxBytes);
        }
        FlushChunk(chunks, current, ref currentBytes);
        return chunks;
    }

    public static PensieveKnowledgeBatch PrepareBatch(
        string text,
        PensieveSourceKind sourceKind,
        string sourcePath,
        string sourceSlug,
        byte[] vaultKey,
        string? title = null,
        string? section = null,
        string? category = null,
        string modelVersion = PensieveVectorCloak.DeterministicModelVersion)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceSlug);
        ArgumentNullException.ThrowIfNull(vaultKey);

        string slugHmac = CloudVaultCrypto.PensieveSlugHmac(sourceSlug, vaultKey);
        var vectors = new List<PensieveKnowledgeVector>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        IReadOnlyList<string> chunks = Chunk(RedactSecrets(text));
        for (int index = 0; index < chunks.Count; index++)
        {
            string chunk = chunks[index].Trim();
            if (chunk.Length == 0)
            {
                continue;
            }

            string dedupHash = CloudVaultCrypto.PensieveDedupHash(chunk, vaultKey);
            if (!seen.Add(dedupHash))
            {
                continue;
            }

            var metadata = new SortedDictionary<string, object?>(StringComparer.Ordinal)
            {
                ["source"] = "member-knowledge",
                ["source_path"] = sourcePath,
                ["chunk_index"] = index,
                ["sourceKind"] = sourceKind.WireValue(),
                ["sourceSlug"] = sourceSlug,
            };
            if (!string.IsNullOrWhiteSpace(title)) metadata["page_title"] = LimitCharacters(RedactSecrets(title), 120);
            if (!string.IsNullOrWhiteSpace(section)) metadata["section"] = section;
            if (!string.IsNullOrWhiteSpace(category)) metadata["category"] = category;

            string metadataJson = JsonSerializer.Serialize(metadata, PensieveJson.CompactOptions);
            vectors.Add(new PensieveKnowledgeVector(
                dedupHash,
                PensieveVectorCloak.EmbedAndCloak(chunk, vaultKey, modelVersion: modelVersion),
                CloudVaultCrypto.SealText(chunk, vaultKey),
                CloudVaultCrypto.SealText(metadataJson, vaultKey),
                dedupHash,
                sourceKind.WireValue(),
                index,
                Encoding.UTF8.GetByteCount(chunk)));
        }

        return new PensieveKnowledgeBatch(sourceSlug, slugHmac, modelVersion, vectors);
    }

    public static IReadOnlyList<PensieveKnowledgeBatch> SplitForCommit(PensieveKnowledgeBatch batch)
    {
        ArgumentNullException.ThrowIfNull(batch);
        if (batch.Vectors.Count == 0)
        {
            return Array.Empty<PensieveKnowledgeBatch>();
        }

        return batch.Vectors
            .Chunk(MaxBatchVectors)
            .Select(partition => batch with { Vectors = partition })
            .ToArray();
    }

    public static string Slugify(string raw)
    {
        ArgumentNullException.ThrowIfNull(raw);
        var builder = new StringBuilder(raw.Length);
        bool previousDash = false;
        foreach (Rune rune in raw.ToLowerInvariant().EnumerateRunes())
        {
            if (rune.Value is >= 'a' and <= 'z' or >= '0' and <= '9')
            {
                builder.Append(rune.ToString());
                previousDash = false;
            }
            else if (!previousDash && builder.Length > 0)
            {
                builder.Append('-');
                previousDash = true;
            }
            if (builder.Length >= 120)
            {
                break;
            }
        }

        string result = builder.ToString().Trim('-');
        return result.Length > 0
            ? result
            : CloudVaultCrypto.Sha256Hex(raw)[..16];
    }

    private static void AppendByteBoundedWord(
        List<string> chunks,
        StringBuilder current,
        ref int currentBytes,
        string word,
        int maxBytes)
    {
        int separatorBytes = current.Length == 0 ? 0 : 1;
        int wordBytes = Encoding.UTF8.GetByteCount(word);
        if (currentBytes + separatorBytes + wordBytes <= maxBytes)
        {
            if (current.Length > 0) current.Append(' ');
            current.Append(word);
            currentBytes += separatorBytes + wordBytes;
            return;
        }

        FlushChunk(chunks, current, ref currentBytes);
        if (chunks.Count > 0)
        {
            string overlap = LimitUtf8Tail(chunks[^1], ChunkOverlapCharacters, maxBytes);
            current.Append(overlap);
            currentBytes = Encoding.UTF8.GetByteCount(overlap);
        }

        separatorBytes = current.Length == 0 ? 0 : 1;
        if (currentBytes + separatorBytes + wordBytes <= maxBytes)
        {
            if (current.Length > 0) current.Append(' ');
            current.Append(word);
            currentBytes += separatorBytes + wordBytes;
            return;
        }

        foreach (Rune rune in word.EnumerateRunes())
        {
            string value = rune.ToString();
            int runeBytes = Encoding.UTF8.GetByteCount(value);
            if (currentBytes + runeBytes > maxBytes)
            {
                FlushChunk(chunks, current, ref currentBytes);
            }
            current.Append(value);
            currentBytes += runeBytes;
        }
    }

    private static void FlushChunk(List<string> chunks, StringBuilder current, ref int currentBytes)
    {
        string value = current.ToString().Trim();
        if (value.Length > 0)
        {
            chunks.Add(value);
        }
        current.Clear();
        currentBytes = 0;
    }

    private static string LimitUtf8Tail(string value, int maxCharacters, int maxBytes)
    {
        string tail = value.Length <= maxCharacters ? value : value[^maxCharacters..];
        while (tail.Length > 0 && Encoding.UTF8.GetByteCount(tail) > maxBytes / 4)
        {
            tail = tail[1..];
        }
        return tail;
    }

    private static string LimitCharacters(string value, int limit) =>
        value.Length <= limit ? value : value[..limit];

    [GeneratedRegex(@"sk-[A-Za-z0-9]{20,}", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)]
    private static partial Regex OpenAiKeyPattern();

    [GeneratedRegex(@"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)]
    private static partial Regex AwsKeyPattern();

    [GeneratedRegex(@"ghp_[A-Za-z0-9]{30,}", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)]
    private static partial Regex GitHubTokenPattern();

    [GeneratedRegex(@"xox[baprs]-[A-Za-z0-9-]{10,}", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)]
    private static partial Regex SlackTokenPattern();

    [GeneratedRegex(@"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)]
    private static partial Regex PrivateKeyPattern();

    [GeneratedRegex(@"\b[Bb]earer\s+[A-Za-z0-9._-]{20,}", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)]
    private static partial Regex BearerPattern();

    [GeneratedRegex(@"\b(?:password|passwd|secret|api[_-]?key|token)\s*[:=]\s*\S+", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)]
    private static partial Regex AssignedSecretPattern();

    [GeneratedRegex(@"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)]
    private static partial Regex JwtPattern();

    [GeneratedRegex(@"\s+", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)]
    private static partial Regex WhitespacePattern();
}

internal static class PensieveJson
{
    public static readonly JsonSerializerOptions CompactOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public static readonly JsonSerializerOptions QueueOptions = new(CompactOptions)
    {
        WriteIndented = true,
    };
}
