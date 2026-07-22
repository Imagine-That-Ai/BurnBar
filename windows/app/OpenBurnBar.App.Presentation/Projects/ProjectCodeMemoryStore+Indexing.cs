using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.App.Presentation.Projects;

public sealed partial class ProjectCodeMemoryStore
{
    private static string CanonicalRoot(string root)
    {
        string fullPath = Path.GetFullPath(root ?? throw new ArgumentNullException(nameof(root)));
        string pathRoot = Path.GetPathRoot(fullPath) ?? string.Empty;
        return string.Equals(fullPath, pathRoot, StringComparison.OrdinalIgnoreCase)
            ? fullPath
            : fullPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }

    private static string ProjectID(string root) => "project_" + Hash(root);

    private static string ArtifactID(string projectID, string relativePath) => "artifact_" + Hash($"{projectID}:{relativePath}");

    private static string ManifestID(string projectID, string relativePath) => "manifest_" + Hash($"{projectID}:{relativePath}");

    private static string SymbolID(string projectID, string artifactID, ProjectCodeSymbol symbol, int ordinal) =>
        "symbol_" + Hash($"{projectID}:{artifactID}:{symbol.Name}:{symbol.Kind}:{symbol.Line}:{ordinal}");

    private static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant()[..32];

    private static string Sha256Hex(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

    private static IReadOnlyList<CodeChunk> BuildChunks(
        string text,
        IReadOnlyList<ProjectCodeSymbol>? symbols = null)
    {
        if (string.IsNullOrEmpty(text))
        {
            return Array.Empty<CodeChunk>();
        }

        var chunks = new List<CodeChunk>();
        IReadOnlyList<(int Start, int End)> astRanges = BuildAstRanges(text, symbols ?? Array.Empty<ProjectCodeSymbol>());
        if (astRanges.Count == 0)
        {
            AppendBoundedChunks(text, 0, text.Length, chunks);
            return chunks;
        }

        int cursor = 0;
        foreach ((int start, int end) in astRanges)
        {
            if (start > cursor)
            {
                AppendBoundedChunks(text, cursor, start, chunks);
            }

            if (end - start <= CodeChunkMaxCharacters)
            {
                AddChunk(text, start, end, chunks);
            }
            else
            {
                AppendBoundedChunks(text, start, end, chunks);
            }

            cursor = Math.Max(cursor, end);
        }

        if (cursor < text.Length)
        {
            AppendBoundedChunks(text, cursor, text.Length, chunks);
        }

        return chunks;
    }

    private static IReadOnlyList<(int Start, int End)> BuildAstRanges(
        string text,
        IReadOnlyList<ProjectCodeSymbol> symbols)
    {
        if (symbols.Count == 0)
        {
            return Array.Empty<(int Start, int End)>();
        }

        int[] lineStarts = BuildLineStarts(text);
        var ranges = symbols
            .Where(symbol => symbol.EndLine is not null && symbol.Line > 0)
            .Select(symbol =>
            {
                int start = OffsetForLine(lineStarts, symbol.Line);
                int end = OffsetForLine(lineStarts, Math.Max(symbol.Line, symbol.EndLine!.Value) + 1);
                return (Start: start, End: Math.Max(start, end));
            })
            .Where(range => range.End > range.Start)
            .OrderBy(range => range.Start)
            .ThenByDescending(range => range.End)
            .ToArray();
        if (ranges.Length == 0)
        {
            return Array.Empty<(int Start, int End)>();
        }

        var merged = new List<(int Start, int End)>();
        foreach ((int start, int end) in ranges)
        {
            if (merged.Count == 0 || start > merged[^1].End)
            {
                merged.Add((start, end));
                continue;
            }

            (int previousStart, int previousEnd) = merged[^1];
            merged[^1] = (previousStart, Math.Max(previousEnd, end));
        }

        return merged;
    }

    private static int[] BuildLineStarts(string text)
    {
        var starts = new List<int> { 0 };
        for (int index = 0; index < text.Length; index++)
        {
            if (text[index] == '\n' && index + 1 < text.Length)
            {
                starts.Add(index + 1);
            }
        }

        return starts.ToArray();
    }

    private static int OffsetForLine(IReadOnlyList<int> lineStarts, int oneBasedLine)
    {
        int index = Math.Clamp(oneBasedLine - 1, 0, lineStarts.Count - 1);
        return lineStarts[index];
    }

    private static void AppendBoundedChunks(string text, int start, int end, ICollection<CodeChunk> chunks)
    {
        int cursor = Math.Clamp(start, 0, text.Length);
        int boundedEnd = Math.Clamp(end, cursor, text.Length);
        while (cursor < boundedEnd)
        {
            int chunkEnd = Math.Min(boundedEnd, cursor + CodeChunkMaxCharacters);
            if (chunkEnd < boundedEnd)
            {
                int searchStart = Math.Min(boundedEnd, cursor + CodeChunkMaxCharacters / 2);
                int newline = text.LastIndexOf('\n', chunkEnd - 1, chunkEnd - searchStart);
                if (newline >= cursor)
                {
                    chunkEnd = newline + 1;
                }
            }

            if (chunkEnd <= cursor)
            {
                chunkEnd = Math.Min(boundedEnd, cursor + CodeChunkMaxCharacters);
            }

            AddChunk(text, cursor, chunkEnd, chunks);
            if (chunkEnd >= boundedEnd)
            {
                break;
            }

            cursor = Math.Min(boundedEnd, Math.Max(cursor + 1, chunkEnd - CodeChunkOverlapCharacters));
        }
    }

    private static void AddChunk(string text, int start, int end, ICollection<CodeChunk> chunks)
    {
        if (end <= start)
        {
            return;
        }

        string slice = text[start..end];
        chunks.Add(new CodeChunk(start, end, Sha256Hex(slice), slice));
    }

    private float[] Embed(string text)
    {
        if (_embeddingProvider is not null)
        {
            float[] providerVector = _embeddingProvider.Embed(text);
            if (providerVector.Length != _embeddingDimensions || providerVector.Any(static value => !float.IsFinite(value)))
            {
                throw new InvalidOperationException("The configured embedding provider returned an invalid vector.");
            }

            return providerVector;
        }

        string normalized = (text ?? string.Empty).Replace("\r\n", "\n", StringComparison.Ordinal).Trim().ToLowerInvariant();
        var vector = new float[CodeEmbeddingDimensions];
        var tokens = new List<string>();
        var token = new StringBuilder();
        foreach (char character in normalized)
        {
            if (char.IsWhiteSpace(character) || char.IsPunctuation(character))
            {
                if (token.Length > 0)
                {
                    tokens.Add(token.ToString());
                    token.Clear();
                }
            }
            else
            {
                token.Append(character);
            }
        }

        if (token.Length > 0)
        {
            tokens.Add(token.ToString());
        }

        if (tokens.Count == 0)
        {
            tokens.Add(normalized);
        }

        for (int position = 0; position < tokens.Count; position++)
        {
            string digest = Sha256Hex($"{CodeEmbeddingSeed}|{position.ToString(CultureInfo.InvariantCulture)}|{tokens[position]}");
            byte[] bytes = Encoding.ASCII.GetBytes(digest);
            float weight = 1f / Math.Max(1, position + 1);
            int width = Math.Min(16, bytes.Length);
            for (int lane = 0; lane < width; lane++)
            {
                int index = (bytes[lane] + (lane * 131)) % vector.Length;
                float sign = lane % 2 == 0 ? 1f : -1f;
                float magnitude = (bytes[lane] % 31) / 30f + 0.15f;
                vector[index] += sign * magnitude * weight;
            }
        }

        double norm = Math.Sqrt(vector.Sum(value => (double)value * value));
        if (norm <= double.Epsilon)
        {
            return vector;
        }

        for (int index = 0; index < vector.Length; index++)
        {
            vector[index] = (float)(vector[index] / norm);
        }

        return vector;
    }

    private static byte[] EncodeEmbedding(float[] vector)
    {
        byte[] bytes = new byte[vector.Length * sizeof(float)];
        Buffer.BlockCopy(vector, 0, bytes, 0, bytes.Length);
        return bytes;
    }

    private static float[] DecodeEmbedding(byte[] bytes, int dimensions)
    {
        if (dimensions <= 0 || bytes.Length != dimensions * sizeof(float))
        {
            return Array.Empty<float>();
        }

        var vector = new float[dimensions];
        Buffer.BlockCopy(bytes, 0, vector, 0, bytes.Length);
        return vector;
    }

    private static double Cosine(float[] lhs, float[] rhs)
    {
        if (lhs.Length != rhs.Length || lhs.Length == 0)
        {
            return -1;
        }

        double dot = 0;
        double leftNorm = 0;
        double rightNorm = 0;
        for (int index = 0; index < lhs.Length; index++)
        {
            dot += lhs[index] * rhs[index];
            leftNorm += lhs[index] * lhs[index];
            rightNorm += rhs[index] * rhs[index];
        }

        return leftNorm <= double.Epsilon || rightNorm <= double.Epsilon
            ? -1
            : dot / Math.Sqrt(leftNorm * rightNorm);
    }

    private static string RelativePath(string root, string path) => TryRelativePath(root, path) ?? throw new ArgumentException("Path is outside the project root.", nameof(path));

    private static string? TryRelativePath(string root, string path)
    {
        string fullPath = Path.GetFullPath(Path.IsPathRooted(path) ? path : Path.Combine(root, path));
        string prefix = root + Path.DirectorySeparatorChar;
        if (!fullPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        return Path.GetRelativePath(root, fullPath).Replace('\\', '/');
    }

    private static DateTimeOffset ParseTimestamp(string value) =>
        DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out DateTimeOffset parsed)
            ? parsed
            : DateTimeOffset.MinValue;

    private static IEnumerable<string> EnumerateCodeFiles(string root, int maxFiles)
        => ProjectCodeFileEnumerator.EnumerateCodeFiles(root, maxFiles);

    private static FileReadResult ReadFile(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (info.Length > 8 * 1024 * 1024)
            {
                return FileReadResult.Rejected(info.Length, Language(path), "max_file_bytes", info.LastWriteTimeUtc);
            }

            byte[] bytes = File.ReadAllBytes(path);
            if (bytes.AsSpan(0, Math.Min(bytes.Length, 4096)).IndexOf((byte)0) >= 0)
            {
                return FileReadResult.Rejected(bytes.Length, Language(path), "binary", info.LastWriteTimeUtc);
            }

            string text = Encoding.UTF8.GetString(bytes);
            return new FileReadResult(
                true,
                bytes.Length,
                Language(path),
                null,
                JsonLinesProjectCodeStaticParserClient.ComputeGitBlobSha(text),
                Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
                text,
                info.LastWriteTimeUtc);
        }
        catch (UnauthorizedAccessException)
        {
            return FileReadResult.Rejected(0, Language(path), "unreadable", DateTimeOffset.UtcNow);
        }
        catch (IOException)
        {
            return FileReadResult.Rejected(0, Language(path), "unreadable", DateTimeOffset.UtcNow);
        }
    }

    private static string Language(string path) => Path.GetExtension(path).TrimStart('.').ToLowerInvariant();

    private sealed record FileReadResult(
        bool Readable,
        long ByteCount,
        string Language,
        string? Reason,
        string? BlobSha,
        string? ContentHash,
        string? Text,
        DateTimeOffset LastWriteUtc)
    {
        public static FileReadResult Rejected(long bytes, string language, string reason, DateTimeOffset lastWriteUtc) =>
            new(false, bytes, language, reason, null, null, null, lastWriteUtc);
    }

    private sealed record StoredArtifact(string ID, string RelativePath, string BlobSha, string Text);

    private sealed record CodeChunk(int StartOffset, int EndOffset, string ContentHash, string Text);

    private sealed record StoredSymbol(string ID, string ArtifactID, string RelativePath, ProjectCodeSymbol Symbol, string BlobSha);

    private sealed record SymbolRange(int StartLine, int EndLine, string FilePath);

    private sealed record ReferenceRange(int StartLine, int EndLine, int StartCharacter, int EndCharacter, string FilePath);

    private static SymbolRange DeserializeRange(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<SymbolRange>(json) ?? new SymbolRange(1, 1, string.Empty);
        }
        catch (JsonException)
        {
            return new SymbolRange(1, 1, string.Empty);
        }
    }
}
