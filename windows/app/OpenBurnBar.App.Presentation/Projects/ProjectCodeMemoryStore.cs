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
using OpenBurnBar.Storage;

namespace OpenBurnBar.App.Presentation.Projects;

/// <summary>
/// Durable, source-free project-code metadata storage. The schema mirrors the
/// macOS Pensieve project-code tables, persisting paths, hashes, symbols,
/// references, checkpoints, chunk offsets, and versioned vectors. Source is read
/// while an index is built and is never inserted into this database.
/// </summary>
public sealed partial class ProjectCodeMemoryStore : IDisposable
{
    public const long DefaultStorageBudgetBytes = 512L * 1024 * 1024;
    public const long MaximumStorageBudgetBytes = 10L * 1024 * 1024 * 1024;
    public const int CodeChunkMaxCharacters = 2_400;
    public const int CodeChunkOverlapCharacters = 240;
    public const int CodeEmbeddingDimensions = 96;
    public const string CodeEmbeddingVersion = "openburnbar-deterministic-code-ast-v1";
    public const int MaxSemanticCandidates = 100_000;
    private const string CodeEmbeddingSeed = "openburnbar-deterministic-embedding-seed-v1";

    private static readonly Regex Token = new(
        "\\b[A-Za-z_][A-Za-z0-9_]{2,}\\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private readonly SqliteConnection _connection;
    private readonly object _gate = new();
    private readonly long _storageBudgetBytes;
    private readonly IProjectCodeEmbeddingProvider? _embeddingProvider;
    private readonly int _embeddingDimensions;
    private readonly string _embeddingVersion;
    private bool _disposed;

    public ProjectCodeMemoryStore(
        string databasePath,
        long storageBudgetBytes = DefaultStorageBudgetBytes,
        string? encryptionPassphrase = null,
        IProjectCodeEmbeddingProvider? embeddingProvider = null)
    {
        if (string.IsNullOrWhiteSpace(databasePath))
        {
            throw new ArgumentException("A project-code memory database path is required.", nameof(databasePath));
        }

        if (storageBudgetBytes is < 1 or > MaximumStorageBudgetBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(storageBudgetBytes));
        }

        if (embeddingProvider is not null
            && (embeddingProvider.Dimensions is < 1 or > 16_384
                || string.IsNullOrWhiteSpace(embeddingProvider.Version)))
        {
            throw new ArgumentException("The embedding provider descriptor is invalid.", nameof(embeddingProvider));
        }

        DatabasePath = Path.GetFullPath(databasePath);
        string? directory = Path.GetDirectoryName(DatabasePath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        _storageBudgetBytes = storageBudgetBytes;
        _embeddingProvider = embeddingProvider;
        _embeddingDimensions = embeddingProvider?.Dimensions ?? CodeEmbeddingDimensions;
        _embeddingVersion = embeddingProvider?.Version ?? CodeEmbeddingVersion;
        SqlCipherParameters.EnsureProviderInitialized();
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
        };
        _connection = new SqliteConnection(builder.ConnectionString);
        _connection.Open();
        try
        {
            if (!string.IsNullOrWhiteSpace(encryptionPassphrase))
            {
                SqlCipherParameters.KeyAndPin(_connection, encryptionPassphrase);
            }

            BootstrapSchema();
        }
        catch
        {
            _connection.Dispose();
            throw;
        }
    }

    public string DatabasePath { get; }

    public ProjectCodeMemoryStoreStats ReadStats()
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            string projectID = ReadScalarString("SELECT project_id FROM code_index_checkpoints ORDER BY indexed_at DESC LIMIT 1") ?? string.Empty;
            return new ProjectCodeMemoryStoreStats(
                ProjectID: projectID,
                ArtifactCount: ReadScalarLong("SELECT COUNT(*) FROM code_artifacts WHERE project_id = $project", ("$project", projectID)),
                SymbolCount: ReadScalarLong("SELECT COUNT(*) FROM code_symbols WHERE project_id = $project", ("$project", projectID)),
                ReferenceCount: ReadScalarLong("SELECT COUNT(*) FROM code_references WHERE project_id = $project", ("$project", projectID)),
                CallEdgeCount: ReadScalarLong("SELECT COUNT(*) FROM code_call_edges WHERE project_id = $project", ("$project", projectID)),
                ManifestCount: ReadScalarLong("SELECT COUNT(*) FROM pcm_file_manifest WHERE project_id = $project", ("$project", projectID)),
                ChunkCount: ReadScalarLong("SELECT COUNT(*) FROM code_chunks WHERE project_id = $project", ("$project", projectID)),
                EmbeddingCount: ReadScalarLong(
                    "SELECT COUNT(*) FROM code_chunks WHERE project_id = $project AND embedding_version = $version",
                    ("$project", projectID), ("$version", _embeddingVersion)),
                EmbeddingDimensions: ReadScalarLong(
                    "SELECT COALESCE(MAX(embedding_dimension), 0) FROM code_chunks WHERE project_id = $project AND embedding_version = $version",
                    ("$project", projectID), ("$version", _embeddingVersion)),
                StorageBytes: DatabaseSizeBytes(),
                StorageBudgetBytes: _storageBudgetBytes,
                SemanticAvailable: ReadScalarLong(
                    "SELECT COUNT(*) FROM code_chunks WHERE project_id = $project AND embedding_version = $version AND embedding_dimension = $dimensions",
                    ("$project", projectID), ("$version", _embeddingVersion),
                    ("$dimensions", _embeddingDimensions)) > 0,
                EmbeddingVersion: _embeddingVersion);
        }
    }

    public ProjectCodeSemanticSearchResult ReadSemanticSearch(string query, int limit = 20)
    {
        string normalized = (query ?? string.Empty).Trim();
        if (normalized.Length == 0 || normalized.Length > 256)
        {
            throw new ArgumentException("A semantic search query between 1 and 256 characters is required.", nameof(query));
        }

        if (limit is < 1 or > 100)
        {
            throw new ArgumentOutOfRangeException(nameof(limit));
        }

        float[] queryVector = Embed(normalized);
        lock (_gate)
        {
            ThrowIfDisposed();
            string projectID = ReadScalarString("SELECT project_id FROM code_index_checkpoints ORDER BY indexed_at DESC LIMIT 1") ?? string.Empty;
            if (projectID.Length == 0)
            {
                return new ProjectCodeSemanticSearchResult(
                    normalized,
                    Array.Empty<ProjectCodeSemanticSearchHit>(),
                    false,
                    false,
                    _embeddingVersion,
                    _embeddingDimensions);
            }

            using var command = _connection.CreateCommand();
            command.CommandText = """
                SELECT id, file_path, start_offset, end_offset, content_hash,
                       embedding_version, embedding_dimension, embedding
                FROM code_chunks
                WHERE project_id = $project AND embedding_version = $version AND embedding_dimension = $dimensions
                ORDER BY file_path COLLATE NOCASE, start_offset, id
                LIMIT $maxCandidates;
                """;
            command.Parameters.AddWithValue("$project", projectID);
            command.Parameters.AddWithValue("$version", _embeddingVersion);
            command.Parameters.AddWithValue("$dimensions", _embeddingDimensions);
            command.Parameters.AddWithValue("$maxCandidates", MaxSemanticCandidates);
            using SqliteDataReader reader = command.ExecuteReader();
            var ranked = new List<ProjectCodeSemanticSearchHit>();
            while (reader.Read())
            {
                byte[] vectorBytes = (byte[])reader[7];
                float[] vector = DecodeEmbedding(vectorBytes, reader.GetInt32(6));
                if (vector.Length == 0)
                {
                    continue;
                }

                ranked.Add(new ProjectCodeSemanticSearchHit(
                    reader.GetString(0),
                    reader.GetString(1),
                    reader.GetInt32(2),
                    reader.GetInt32(3),
                    reader.GetString(4),
                    Cosine(queryVector, vector),
                    reader.GetString(5)));
            }

            bool truncated = ranked.Count > limit;
            return new ProjectCodeSemanticSearchResult(
                normalized,
                ranked.OrderByDescending(hit => hit.Score)
                    .ThenBy(hit => hit.FilePath, StringComparer.OrdinalIgnoreCase)
                    .ThenBy(hit => hit.StartOffset)
                    .ThenBy(hit => hit.ChunkID, StringComparer.Ordinal)
                    .Take(limit)
                    .ToArray(),
                ranked.Count > 0,
                truncated || ranked.Count >= MaxSemanticCandidates,
                _embeddingVersion,
                _embeddingDimensions);
        }
    }

    public ProjectCodeCallGraphResult ReadCallGraph(string name, int limit = 200, int depth = 1)
    {
        string normalized = (name ?? string.Empty).Trim();
        if (normalized.Length == 0 || normalized.Length > 256)
        {
            throw new ArgumentException("A call-graph symbol name between 1 and 256 characters is required.", nameof(name));
        }

        if (limit is < 1 or > 200)
        {
            throw new ArgumentOutOfRangeException(nameof(limit));
        }

        if (depth is < 1 or > 3)
        {
            throw new ArgumentOutOfRangeException(nameof(depth));
        }

        lock (_gate)
        {
            ThrowIfDisposed();
            var queue = new Queue<(string Name, int Depth)>();
            var visitedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { normalized };
            var edges = new List<ProjectCodeCallGraphEdge>();
            var seenEdges = new HashSet<string>(StringComparer.Ordinal);
            queue.Enqueue((normalized, 0));
            while (queue.Count > 0 && edges.Count < limit)
            {
                (string current, int currentDepth) = queue.Dequeue();
                IReadOnlyList<ProjectCodeCallGraphEdge> outgoing = ReadOutgoingEdges(current);
                foreach (ProjectCodeCallGraphEdge edge in outgoing)
                {
                    if (seenEdges.Add(edge.EdgeID))
                    {
                        edges.Add(edge);
                    }

                    if (currentDepth + 1 < depth && visitedNames.Add(edge.Callee.Name))
                    {
                        queue.Enqueue((edge.Callee.Name, currentDepth + 1));
                    }

                    if (edges.Count >= limit)
                    {
                        break;
                    }
                }
            }

            return new ProjectCodeCallGraphResult(normalized, edges, edges.Count >= limit);
        }
    }

    public bool TryLoad(string root, out ProjectCodeIndexSnapshot snapshot)
    {
        snapshot = default!;
        string canonicalRoot = CanonicalRoot(root);
        lock (_gate)
        {
            ThrowIfDisposed();
            using var command = _connection.CreateCommand();
            command.CommandText =
                "SELECT indexed_at, truncated, parser_mode FROM code_index_checkpoints "
                + "WHERE project_root = $root LIMIT 1;";
            command.Parameters.AddWithValue("$root", canonicalRoot);
            using SqliteDataReader reader = command.ExecuteReader();
            if (!reader.Read())
            {
                return false;
            }

            DateTimeOffset refreshedAt = ParseTimestamp(reader.GetString(0));
            bool truncated = reader.GetInt64(1) != 0;
            string parserMode = reader.IsDBNull(2) ? "lexical" : reader.GetString(2);
            var symbols = new List<ProjectCodeSymbol>();
            using var symbolsCommand = _connection.CreateCommand();
            symbolsCommand.CommandText =
                "SELECT a.file_path, s.name, s.kind, s.range_json, s.confidence_tier "
                + "FROM code_symbols AS s JOIN code_artifacts AS a ON a.id = s.artifact_id "
                + "WHERE s.project_id = $project ORDER BY a.file_path, s.range_json, s.name;";
            symbolsCommand.Parameters.AddWithValue("$project", ProjectID(canonicalRoot));
            using SqliteDataReader symbolReader = symbolsCommand.ExecuteReader();
            while (symbolReader.Read())
            {
                string relativePath = symbolReader.GetString(0);
                SymbolRange range = DeserializeRange(symbolReader.GetString(3));
                symbols.Add(new ProjectCodeSymbol(
                    symbolReader.GetString(1),
                    symbolReader.GetString(2),
                    Path.Combine(canonicalRoot, relativePath.Replace('/', Path.DirectorySeparatorChar)),
                    range.StartLine,
                    symbolReader.IsDBNull(4) ? "lexical_fallback" : symbolReader.GetString(4),
                    parserMode == "tree-sitter" ? "tree-sitter" : "lexical",
                    range.EndLine));
            }

            snapshot = new ProjectCodeIndexSnapshot(canonicalRoot, refreshedAt, symbols, truncated, parserMode);
            return true;
        }
    }

    /// <summary>Atomically replaces the project metadata for one completed index pass.</summary>
    public void SaveIndex(string root, ProjectCodeIndexSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        string canonicalRoot = CanonicalRoot(root);
        if (!string.Equals(canonicalRoot, CanonicalRoot(snapshot.Root), StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("The snapshot root must match the store root argument.", nameof(snapshot));
        }

        lock (_gate)
        {
            ThrowIfDisposed();
            using SqliteTransaction transaction = _connection.BeginTransaction();
            try
            {
                string projectID = ProjectID(canonicalRoot);
                string now = snapshot.RefreshedAt.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);
                UpsertProject(projectID, canonicalRoot, now, transaction);
                DeleteProjectRows(projectID, transaction);

                var artifacts = new List<StoredArtifact>();
                var rejected = 0;
                var chunkCount = 0;
                foreach (string path in EnumerateCodeFiles(canonicalRoot, 500))
                {
                    FileReadResult file = ReadFile(path);
                    string relativePath = RelativePath(canonicalRoot, path);
                    if (!file.Readable)
                    {
                        rejected++;
                        InsertManifest(projectID, relativePath, null, file.ByteCount, file.Language, file.Reason, now, transaction);
                        continue;
                    }

                    string artifactID = ArtifactID(projectID, relativePath);
                    artifacts.Add(new StoredArtifact(artifactID, relativePath, file.BlobSha!, file.Text!));
                    InsertArtifact(artifactID, projectID, relativePath, file, now, transaction);
                    InsertManifest(projectID, relativePath, artifactID, file.ByteCount, file.Language, null, now, transaction);
                    IReadOnlyList<ProjectCodeSymbol> fileSymbols = snapshot.Symbols
                        .Where(symbol => string.Equals(
                            TryRelativePath(canonicalRoot, symbol.FilePath),
                            relativePath,
                            StringComparison.OrdinalIgnoreCase))
                        .ToArray();
                    chunkCount += InsertCodeChunks(projectID, artifacts[^1], fileSymbols, now, transaction);
                }

                var symbolIDsByName = new Dictionary<string, List<(string ID, string RelativePath, int Line)>>(StringComparer.OrdinalIgnoreCase);
                var symbolRows = new List<StoredSymbol>();
                var ordinalByArtifact = new Dictionary<string, int>(StringComparer.Ordinal);
                foreach (ProjectCodeSymbol symbol in snapshot.Symbols)
                {
                    string? relativePath = TryRelativePath(canonicalRoot, symbol.FilePath);
                    if (relativePath is null)
                    {
                        continue;
                    }

                    StoredArtifact? artifact = artifacts.FirstOrDefault(item =>
                        string.Equals(item.RelativePath, relativePath, StringComparison.OrdinalIgnoreCase));
                    if (artifact is null)
                    {
                        continue;
                    }

                    int ordinal = ordinalByArtifact.TryGetValue(artifact.ID, out int current) ? current : 0;
                    ordinalByArtifact[artifact.ID] = ordinal + 1;
                    string symbolID = SymbolID(projectID, artifact.ID, symbol, ordinal);
                    var stored = new StoredSymbol(symbolID, artifact.ID, relativePath, symbol, artifact.BlobSha);
                    symbolRows.Add(stored);
                    if (!symbolIDsByName.TryGetValue(symbol.Name, out List<(string ID, string RelativePath, int Line)>? targets))
                    {
                        targets = new List<(string ID, string RelativePath, int Line)>();
                        symbolIDsByName[symbol.Name] = targets;
                    }

                    targets.Add((symbolID, relativePath, symbol.Line));
                    InsertSymbol(projectID, stored, now, transaction);
                }

                BuildReferences(projectID, artifacts, symbolRows, symbolIDsByName, now, transaction);
                UpsertCheckpoint(
                    projectID,
                    canonicalRoot,
                    snapshot,
                    artifacts.Count,
                    symbolRows.Count,
                    chunkCount,
                    rejected,
                    now,
                    transaction);
                transaction.Commit();
            }
            catch
            {
                transaction.Rollback();
                throw;
            }

            if (DatabaseSizeBytes() > _storageBudgetBytes)
            {
                using var vacuum = _connection.CreateCommand();
                vacuum.CommandText = "PRAGMA incremental_vacuum(1024);";
                vacuum.ExecuteNonQuery();
            }
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _connection.Dispose();
        }
    }

    private void BootstrapSchema()
    {
        using var command = _connection.CreateCommand();
        command.CommandText = "PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA auto_vacuum = INCREMENTAL;";
        command.ExecuteNonQuery();
        command.CommandText = """
            CREATE TABLE IF NOT EXISTS pcm_projects (
                project_id TEXT PRIMARY KEY,
                identity_version INTEGER NOT NULL,
                identity_fingerprint TEXT NOT NULL,
                project_name TEXT NOT NULL,
                primary_path TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS pcm_projects_fingerprint_idx ON pcm_projects(identity_fingerprint);
            CREATE TABLE IF NOT EXISTS pcm_file_manifest (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                artifact_id TEXT,
                blob_sha TEXT,
                content_hash TEXT,
                byte_count INTEGER NOT NULL DEFAULT 0,
                mtime REAL NOT NULL DEFAULT 0,
                lang TEXT,
                ignored_reason TEXT,
                secret_labels_json TEXT NOT NULL DEFAULT '[]',
                parser_tier TEXT,
                indexed_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS pcm_file_manifest_project_path_idx ON pcm_file_manifest(project_id, file_path);
            CREATE TABLE IF NOT EXISTS code_artifacts (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                blob_sha TEXT NOT NULL,
                content_hash TEXT,
                commit_sha TEXT,
                lang TEXT,
                byte_count INTEGER NOT NULL,
                mtime REAL NOT NULL,
                indexed_at TEXT NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS code_artifacts_project_path_idx ON code_artifacts(project_id, file_path);
            CREATE TABLE IF NOT EXISTS code_symbols (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                artifact_id TEXT NOT NULL,
                blob_sha TEXT NOT NULL,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                range_json TEXT NOT NULL,
                confidence_tier TEXT NOT NULL,
                tier_evidence_json TEXT,
                indexed_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS code_symbols_project_name_idx ON code_symbols(project_id, name);
            CREATE TABLE IF NOT EXISTS code_references (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                from_artifact_id TEXT NOT NULL,
                to_symbol_id TEXT NOT NULL,
                range_json TEXT NOT NULL,
                blob_sha TEXT NOT NULL,
                confidence_tier TEXT NOT NULL,
                indexed_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS code_references_symbol_idx ON code_references(project_id, to_symbol_id);
            CREATE TABLE IF NOT EXISTS code_call_edges (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                caller_symbol_id TEXT NOT NULL,
                callee_symbol_id TEXT NOT NULL,
                confidence_tier TEXT NOT NULL,
                indexed_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS code_call_edges_project_idx ON code_call_edges(project_id, caller_symbol_id);
            CREATE TABLE IF NOT EXISTS code_index_checkpoints (
                project_id TEXT PRIMARY KEY,
                project_root TEXT NOT NULL,
                last_commit_sha TEXT,
                indexed_at TEXT NOT NULL,
                artifact_count INTEGER NOT NULL,
                chunk_count INTEGER NOT NULL,
                rejected_count INTEGER NOT NULL,
                storage_byte_count INTEGER NOT NULL DEFAULT 0,
                storage_budget_bytes INTEGER NOT NULL DEFAULT 0,
                vacuumed_at TEXT,
                truncated INTEGER NOT NULL DEFAULT 0,
                parser_mode TEXT NOT NULL DEFAULT 'lexical'
            );
            CREATE TABLE IF NOT EXISTS code_chunks (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                artifact_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                start_offset INTEGER NOT NULL,
                end_offset INTEGER NOT NULL,
                content_hash TEXT NOT NULL,
                embedding_version TEXT NOT NULL,
                embedding_dimension INTEGER NOT NULL,
                embedding BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS code_chunks_project_idx ON code_chunks(project_id, embedding_version, file_path, start_offset);
            """;
        command.ExecuteNonQuery();
        EnsureColumn("code_index_checkpoints", "truncated", "INTEGER NOT NULL DEFAULT 0");
        EnsureColumn("code_index_checkpoints", "parser_mode", "TEXT NOT NULL DEFAULT 'lexical'");
    }

    private IReadOnlyList<ProjectCodeCallGraphEdge> ReadOutgoingEdges(string callerName)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = """
            SELECT e.id,
                   caller.id, caller.name, caller.kind, caller.range_json, caller.confidence_tier,
                   caller_art.file_path,
                   callee.id, callee.name, callee.kind, callee.range_json, callee.confidence_tier,
                   callee_art.file_path, e.confidence_tier
            FROM code_call_edges AS e
            JOIN code_symbols AS caller ON caller.id = e.caller_symbol_id
            JOIN code_symbols AS callee ON callee.id = e.callee_symbol_id
            JOIN code_artifacts AS caller_art ON caller_art.id = caller.artifact_id
            JOIN code_artifacts AS callee_art ON callee_art.id = callee.artifact_id
            WHERE caller.name = $name
            ORDER BY callee.name COLLATE NOCASE, caller_art.file_path COLLATE NOCASE, e.id;
            """;
        command.Parameters.AddWithValue("$name", callerName);
        using SqliteDataReader reader = command.ExecuteReader();
        var edges = new List<ProjectCodeCallGraphEdge>();
        while (reader.Read())
        {
            edges.Add(new ProjectCodeCallGraphEdge(
                reader.GetString(0),
                ReadCallGraphSymbol(reader, 1, 2, 3, 4, 5, 6),
                ReadCallGraphSymbol(reader, 7, 8, 9, 10, 11, 12),
                reader.GetString(13)));
        }

        return edges;
    }

    private static ProjectCodeCallGraphSymbol ReadCallGraphSymbol(
        SqliteDataReader reader,
        int idColumn,
        int nameColumn,
        int kindColumn,
        int rangeColumn,
        int confidenceColumn,
        int pathColumn)
    {
        SymbolRange range = DeserializeRange(reader.GetString(rangeColumn));
        return new ProjectCodeCallGraphSymbol(
            reader.GetString(idColumn),
            reader.GetString(nameColumn),
            reader.GetString(kindColumn),
            reader.GetString(pathColumn),
            range.StartLine,
            reader.GetString(confidenceColumn));
    }

    private void UpsertProject(string projectID, string root, string now, SqliteTransaction transaction)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO pcm_projects (project_id, identity_version, identity_fingerprint, project_name, primary_path, created_at, updated_at)
            VALUES ($id, 1, $fingerprint, $name, $path, $now, $now)
            ON CONFLICT(project_id) DO UPDATE SET identity_fingerprint = excluded.identity_fingerprint,
                project_name = excluded.project_name, primary_path = excluded.primary_path, updated_at = excluded.updated_at;
            """;
        command.Parameters.AddWithValue("$id", projectID);
        command.Parameters.AddWithValue("$fingerprint", Hash(root));
        command.Parameters.AddWithValue("$name", new DirectoryInfo(root).Name);
        command.Parameters.AddWithValue("$path", root);
        command.Parameters.AddWithValue("$now", now);
        command.ExecuteNonQuery();
    }

    private void DeleteProjectRows(string projectID, SqliteTransaction transaction)
    {
        foreach (string sql in new[]
        {
            "DELETE FROM code_call_edges WHERE project_id = $project",
            "DELETE FROM code_references WHERE project_id = $project",
            "DELETE FROM code_symbols WHERE project_id = $project",
            "DELETE FROM code_chunks WHERE project_id = $project",
            "DELETE FROM code_artifacts WHERE project_id = $project",
            "DELETE FROM pcm_file_manifest WHERE project_id = $project",
        })
        {
            using var command = _connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = sql;
            command.Parameters.AddWithValue("$project", projectID);
            command.ExecuteNonQuery();
        }
    }

    private void InsertArtifact(string id, string projectID, string relativePath, FileReadResult file, string now, SqliteTransaction transaction)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO code_artifacts (id, project_id, file_path, blob_sha, content_hash, lang, byte_count, mtime, indexed_at)
            VALUES ($id, $project, $path, $blob, $content, $lang, $bytes, $mtime, $now);
            """;
        command.Parameters.AddWithValue("$id", id);
        command.Parameters.AddWithValue("$project", projectID);
        command.Parameters.AddWithValue("$path", relativePath);
        command.Parameters.AddWithValue("$blob", file.BlobSha!);
        command.Parameters.AddWithValue("$content", file.ContentHash!);
        command.Parameters.AddWithValue("$lang", file.Language);
        command.Parameters.AddWithValue("$bytes", file.ByteCount);
        command.Parameters.AddWithValue("$mtime", file.LastWriteUtc.ToUnixTimeMilliseconds() / 1000d);
        command.Parameters.AddWithValue("$now", now);
        command.ExecuteNonQuery();
    }

    private void InsertManifest(string projectID, string relativePath, string? artifactID, long byteCount, string language, string? reason, string now, SqliteTransaction transaction)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO pcm_file_manifest
                (id, project_id, file_path, artifact_id, byte_count, lang, ignored_reason, indexed_at, last_seen_at)
            VALUES ($id, $project, $path, $artifact, $bytes, $lang, $reason, $now, $now);
            """;
        command.Parameters.AddWithValue("$id", ManifestID(projectID, relativePath));
        command.Parameters.AddWithValue("$project", projectID);
        command.Parameters.AddWithValue("$path", relativePath);
        command.Parameters.AddWithValue("$artifact", (object?)artifactID ?? DBNull.Value);
        command.Parameters.AddWithValue("$bytes", byteCount);
        command.Parameters.AddWithValue("$lang", language);
        command.Parameters.AddWithValue("$reason", (object?)reason ?? DBNull.Value);
        command.Parameters.AddWithValue("$now", now);
        command.ExecuteNonQuery();
    }

    private int InsertCodeChunks(
        string projectID,
        StoredArtifact artifact,
        IReadOnlyList<ProjectCodeSymbol> symbols,
        string now,
        SqliteTransaction transaction)
    {
        IReadOnlyList<CodeChunk> chunks = BuildChunks(artifact.Text, symbols);
        for (int ordinal = 0; ordinal < chunks.Count; ordinal++)
        {
            CodeChunk chunk = chunks[ordinal];
            float[] vector = Embed(chunk.Text);
            using var command = _connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = """
                INSERT INTO code_chunks
                    (id, project_id, artifact_id, file_path, ordinal, start_offset, end_offset,
                     content_hash, embedding_version, embedding_dimension, embedding)
                VALUES ($id, $project, $artifact, $path, $ordinal, $start, $end, $hash, $version, $dimensions, $embedding);
                """;
            command.Parameters.AddWithValue("$id", "chunk_" + Hash($"{artifact.ID}:{ordinal}:{chunk.ContentHash}"));
            command.Parameters.AddWithValue("$project", projectID);
            command.Parameters.AddWithValue("$artifact", artifact.ID);
            command.Parameters.AddWithValue("$path", artifact.RelativePath);
            command.Parameters.AddWithValue("$ordinal", ordinal);
            command.Parameters.AddWithValue("$start", chunk.StartOffset);
            command.Parameters.AddWithValue("$end", chunk.EndOffset);
            command.Parameters.AddWithValue("$hash", chunk.ContentHash);
            command.Parameters.AddWithValue("$version", _embeddingVersion);
            command.Parameters.AddWithValue("$dimensions", _embeddingDimensions);
            command.Parameters.AddWithValue("$embedding", EncodeEmbedding(vector));
            command.ExecuteNonQuery();
        }

        return chunks.Count;
    }

    private void InsertSymbol(string projectID, StoredSymbol stored, string now, SqliteTransaction transaction)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO code_symbols
                (id, project_id, artifact_id, blob_sha, name, kind, range_json, confidence_tier, indexed_at)
            VALUES ($id, $project, $artifact, $blob, $name, $kind, $range, $confidence, $now);
            """;
        command.Parameters.AddWithValue("$id", stored.ID);
        command.Parameters.AddWithValue("$project", projectID);
        command.Parameters.AddWithValue("$artifact", stored.ArtifactID);
        command.Parameters.AddWithValue("$blob", stored.BlobSha);
        command.Parameters.AddWithValue("$name", stored.Symbol.Name);
        command.Parameters.AddWithValue("$kind", stored.Symbol.Kind);
        command.Parameters.AddWithValue(
            "$range",
            JsonSerializer.Serialize(new SymbolRange(
                stored.Symbol.Line,
                stored.Symbol.EndLine ?? stored.Symbol.Line,
                stored.RelativePath)));
        command.Parameters.AddWithValue("$confidence", stored.Symbol.ConfidenceTier);
        command.Parameters.AddWithValue("$now", now);
        command.ExecuteNonQuery();
    }


}

public sealed record ProjectCodeMemoryStoreStats(
    string ProjectID,
    long ArtifactCount,
    long SymbolCount,
    long ReferenceCount,
    long CallEdgeCount,
    long ManifestCount,
    long ChunkCount,
    long EmbeddingCount,
    long EmbeddingDimensions,
    long StorageBytes,
    long StorageBudgetBytes,
    bool SemanticAvailable,
    string EmbeddingVersion);

public sealed record ProjectCodeSemanticSearchHit(
    string ChunkID,
    string FilePath,
    int StartOffset,
    int EndOffset,
    string ContentHash,
    double Score,
    string EmbeddingVersion);

public sealed record ProjectCodeSemanticSearchResult(
    string Query,
    IReadOnlyList<ProjectCodeSemanticSearchHit> Hits,
    bool SemanticAvailable,
    bool Truncated,
    string EmbeddingVersion,
    int EmbeddingDimensions);

public sealed record ProjectCodeCallGraphSymbol(
    string SymbolID,
    string Name,
    string Kind,
    string FilePath,
    int Line,
    string ConfidenceTier);

public sealed record ProjectCodeCallGraphEdge(
    string EdgeID,
    ProjectCodeCallGraphSymbol Caller,
    ProjectCodeCallGraphSymbol Callee,
    string ConfidenceTier);

public sealed record ProjectCodeCallGraphResult(
    string Symbol,
    IReadOnlyList<ProjectCodeCallGraphEdge> Edges,
    bool Truncated);
