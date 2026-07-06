using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.MemorySearch.Search;

// PORTED (faithful) from
//   AgentLens/Services/Search/VectorSearch/VectorIndexTypes.swift        (entry/candidate/kind/error)
//   AgentLens/Services/Search/VectorSearch/VectorCandidateBackend.swift  (protocol + ExactVectorCandidateBackend)
//
// THE canonical ranking rule appears verbatim in three Swift sites
// (VectorCandidateBackend.swift:48-53, VectorSemanticProvider.swift:368-373 and 747-752):
//   drop non-finite scores → sort by score DESCENDING, tiebreak chunkID ASCENDING → take(limit).
// It is implemented once here (VectorRanking.RankTopK) and reused by the exact backend and
// the semantic exact-rerank. chunkIDs are ASCII, so `String <` == StringComparer.Ordinal.

/// <summary>Which vector backend to use. Swift: <c>enum VectorBackendKind</c>.</summary>
public enum VectorBackendKind
{
    Ann,
    Exact,
}

/// <summary>An index entry: a chunk id and its vector. Swift: <c>struct VectorIndexEntry</c>.</summary>
public sealed record VectorIndexEntry(string ChunkId, IReadOnlyList<float> Vector);

/// <summary>A scored candidate. Swift: <c>struct VectorIndexCandidate</c>.</summary>
public sealed record VectorIndexCandidate(string ChunkId, double Score);

/// <summary>Vector index error. Swift: <c>enum VectorIndexBackendError</c>.</summary>
public sealed class VectorIndexBackendException : Exception
{
    public int Expected { get; }

    public int Actual { get; }

    public VectorIndexBackendException(int expected, int actual)
        : base($"Vector dimension mismatch. Expected {expected}, got {actual}.")
    {
        Expected = expected;
        Actual = actual;
    }
}

/// <summary>
/// The single canonical top-k ranking rule shared across the Swift search code. Implemented
/// once so every ranking site is bit-identical.
/// </summary>
public static class VectorRanking
{
    /// <summary>
    /// Drop non-finite scores, sort by score DESCENDING with chunkID ASCENDING tiebreak, take
    /// the first <paramref name="limit"/>. Swift comparator: <c>if a.score == b.score { return
    /// a.chunkID &lt; b.chunkID }; return a.score &gt; b.score</c>.
    /// </summary>
    public static List<VectorIndexCandidate> RankTopK(IEnumerable<VectorIndexCandidate> scored, int limit)
    {
        ArgumentNullException.ThrowIfNull(scored);
        var finite = new List<VectorIndexCandidate>();
        foreach (var candidate in scored)
        {
            if (double.IsFinite(candidate.Score))
            {
                finite.Add(candidate);
            }
        }

        finite.Sort(Compare);
        if (limit >= 0 && finite.Count > limit)
        {
            return finite.GetRange(0, limit);
        }

        return finite;
    }

    /// <summary>The canonical comparator: score descending, then chunkID ascending (ordinal).</summary>
    public static int Compare(VectorIndexCandidate a, VectorIndexCandidate b)
    {
        ArgumentNullException.ThrowIfNull(a);
        ArgumentNullException.ThrowIfNull(b);
        if (a.Score == b.Score)
        {
            return string.CompareOrdinal(a.ChunkId, b.ChunkId);
        }

        // Descending: larger score sorts first.
        return b.Score.CompareTo(a.Score);
    }
}

/// <summary>The candidate-backend seam. Swift: <c>protocol VectorCandidateBackend</c>.</summary>
public interface IVectorCandidateBackend
{
    string Id { get; }

    void Rebuild(IReadOnlyList<VectorIndexEntry> entries, EmbeddingDistanceMetric distanceMetric);

    /// <summary>Top-<paramref name="limit"/> candidates for the query vector.</summary>
    IReadOnlyList<VectorIndexCandidate> Candidates(IReadOnlyList<float> queryVector, int limit);
}

/// <summary>
/// Deterministic exact k-NN backend. Swift: <c>ExactVectorCandidateBackend</c>
/// (<c>id = "exact_scan_v1"</c>). Scores every entry with <see cref="VectorMath.Similarity"/>,
/// drops non-finite, ranks with the canonical comparator, truncates to <c>limit</c>.
/// </summary>
public sealed class ExactVectorCandidateBackend : IVectorCandidateBackend
{
    private IReadOnlyList<VectorIndexEntry> _entries = Array.Empty<VectorIndexEntry>();
    private EmbeddingDistanceMetric _distanceMetric = EmbeddingDistanceMetric.Cosine;
    private int _dimensions;

    public string Id => "exact_scan_v1";

    public void Rebuild(IReadOnlyList<VectorIndexEntry> entries, EmbeddingDistanceMetric distanceMetric)
    {
        ArgumentNullException.ThrowIfNull(entries);
        _entries = entries;
        _distanceMetric = distanceMetric;
        _dimensions = entries.Count > 0 ? entries[0].Vector.Count : 0;
    }

    public IReadOnlyList<VectorIndexCandidate> Candidates(IReadOnlyList<float> queryVector, int limit)
    {
        ArgumentNullException.ThrowIfNull(queryVector);
        if (limit <= 0 || _entries.Count == 0)
        {
            return Array.Empty<VectorIndexCandidate>();
        }

        // Dimension guard is only enforced once the index has a known dimension.
        if (_dimensions != 0 && queryVector.Count != _dimensions)
        {
            throw new VectorIndexBackendException(_dimensions, queryVector.Count);
        }

        var scored = _entries.Select(entry =>
            new VectorIndexCandidate(entry.ChunkId, VectorMath.Similarity(queryVector, entry.Vector, _distanceMetric)));
        return VectorRanking.RankTopK(scored, limit);
    }
}
