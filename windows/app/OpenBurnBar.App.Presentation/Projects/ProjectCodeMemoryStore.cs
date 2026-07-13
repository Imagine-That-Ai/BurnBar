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
public sealed class ProjectCodeMemoryStore : IDisposable
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

    private void BuildReferences(
        string projectID,
        IReadOnlyList<StoredArtifact> artifacts,
        IReadOnlyList<StoredSymbol> symbols,
        IReadOnlyDictionary<string, List<(string ID, string RelativePath, int Line)>> symbolsByName,
        string now,
        SqliteTransaction transaction)
    {
        foreach (StoredArtifact artifact in artifacts)
        {
            int lineNumber = 1;
            int lineOffset = 0;
            var symbolsInFile = symbols.Where(symbol => string.Equals(symbol.RelativePath, artifact.RelativePath, StringComparison.OrdinalIgnoreCase))
                .OrderBy(symbol => symbol.Symbol.Line)
                .ToArray();
            foreach (string line in artifact.Text!.Split('\n'))
            {
                foreach (Match match in Token.Matches(line))
                {
                    if (!symbolsByName.TryGetValue(match.Value, out List<(string ID, string RelativePath, int Line)>? targets))
                    {
                        continue;
                    }

                    StoredSymbol? caller = symbolsInFile.LastOrDefault(symbol => symbol.Symbol.Line <= lineNumber);
                    foreach ((string ID, string RelativePath, int Line) target in targets)
                    {
                        if (target.RelativePath.Equals(artifact.RelativePath, StringComparison.OrdinalIgnoreCase)
                            && target.Line == lineNumber)
                        {
                            continue;
                        }

                        string referenceID = Hash($"{projectID}:{artifact.ID}:{target.ID}:{lineOffset + match.Index}").Insert(0, "ref_");
                        using (var reference = _connection.CreateCommand())
                        {
                            reference.Transaction = transaction;
                            reference.CommandText = """
                                INSERT OR IGNORE INTO code_references
                                    (id, project_id, from_artifact_id, to_symbol_id, range_json, blob_sha, confidence_tier, indexed_at)
                                VALUES ($id, $project, $from, $to, $range, $blob, 'lexical_fallback', $now);
                                """;
                            reference.Parameters.AddWithValue("$id", referenceID);
                            reference.Parameters.AddWithValue("$project", projectID);
                            reference.Parameters.AddWithValue("$from", artifact.ID);
                            reference.Parameters.AddWithValue("$to", target.ID);
                            reference.Parameters.AddWithValue("$range", JsonSerializer.Serialize(new ReferenceRange(lineNumber, lineNumber, match.Index, match.Index + match.Length, artifact.RelativePath)));
                            reference.Parameters.AddWithValue("$blob", artifact.BlobSha);
                            reference.Parameters.AddWithValue("$now", now);
                            reference.ExecuteNonQuery();
                        }

                        if (caller is not null && caller.ID != target.ID)
                        {
                            using var edge = _connection.CreateCommand();
                            edge.Transaction = transaction;
                            edge.CommandText = """
                                INSERT OR IGNORE INTO code_call_edges
                                    (id, project_id, caller_symbol_id, callee_symbol_id, confidence_tier, indexed_at)
                                VALUES ($id, $project, $caller, $callee, 'lexical_fallback', $now);
                                """;
                            edge.Parameters.AddWithValue("$id", Hash($"{projectID}:{caller.ID}:{target.ID}").Insert(0, "edge_"));
                            edge.Parameters.AddWithValue("$project", projectID);
                            edge.Parameters.AddWithValue("$caller", caller.ID);
                            edge.Parameters.AddWithValue("$callee", target.ID);
                            edge.Parameters.AddWithValue("$now", now);
                            edge.ExecuteNonQuery();
                        }
                    }
                }

                lineOffset += line.Length + 1;
                lineNumber++;
            }
        }
    }

    private void UpsertCheckpoint(string projectID, string root, ProjectCodeIndexSnapshot snapshot, int artifactCount, int symbolCount, int chunkCount, int rejectedCount, string now, SqliteTransaction transaction)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO code_index_checkpoints
                (project_id, project_root, indexed_at, artifact_count, chunk_count, rejected_count,
                 storage_byte_count, storage_budget_bytes, truncated, parser_mode)
            VALUES ($project, $root, $now, $artifacts, $chunks, $rejected, 0, $budget, $truncated, $parser)
            ON CONFLICT(project_id) DO UPDATE SET project_root = excluded.project_root,
                indexed_at = excluded.indexed_at, artifact_count = excluded.artifact_count,
                chunk_count = excluded.chunk_count, rejected_count = excluded.rejected_count,
                storage_byte_count = excluded.storage_byte_count, storage_budget_bytes = excluded.storage_budget_bytes,
                truncated = excluded.truncated, parser_mode = excluded.parser_mode;
            """;
        command.Parameters.AddWithValue("$project", projectID);
        command.Parameters.AddWithValue("$root", root);
        command.Parameters.AddWithValue("$now", now);
        command.Parameters.AddWithValue("$artifacts", artifactCount);
        command.Parameters.AddWithValue("$chunks", chunkCount);
        command.Parameters.AddWithValue("$rejected", rejectedCount);
        command.Parameters.AddWithValue("$budget", _storageBudgetBytes);
        command.Parameters.AddWithValue("$truncated", snapshot.Truncated ? 1 : 0);
        command.Parameters.AddWithValue("$parser", snapshot.ParserMode);
        command.ExecuteNonQuery();
    }

    private void EnsureColumn(string table, string column, string definition)
    {
        using var check = _connection.CreateCommand();
        check.CommandText = $"PRAGMA table_info({table});";
        using SqliteDataReader reader = check.ExecuteReader();
        while (reader.Read())
        {
            if (string.Equals(reader.GetString(1), column, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }
        }

        using var alter = _connection.CreateCommand();
        alter.CommandText = $"ALTER TABLE {table} ADD COLUMN {column} {definition};";
        alter.ExecuteNonQuery();
    }

    private long ReadScalarLong(string sql, params (string Name, object Value)[] parameters)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = sql;
        foreach ((string name, object value) in parameters)
        {
            command.Parameters.AddWithValue(name, value);
        }

        return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    private string? ReadScalarString(string sql)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = sql;
        return command.ExecuteScalar()?.ToString();
    }

    private long DatabaseSizeBytes()
    {
        try
        {
            long size = new FileInfo(DatabasePath).Length;
            string wal = DatabasePath + "-wal";
            return File.Exists(wal) ? size + new FileInfo(wal).Length : size;
        }
        catch (IOException)
        {
            return 0;
        }
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

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
    {
        int count = 0;
        IEnumerable<string> files;
        try
        {
            files = Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories);
        }
        catch (IOException)
        {
            yield break;
        }
        catch (UnauthorizedAccessException)
        {
            yield break;
        }

        foreach (string path in files)
        {
            if (!ProjectCodeLexicalScanner.IsCodeFile(path))
            {
                continue;
            }

            yield return path;
            if (++count >= maxFiles)
            {
                yield break;
            }
        }
    }

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
