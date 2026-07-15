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
}
