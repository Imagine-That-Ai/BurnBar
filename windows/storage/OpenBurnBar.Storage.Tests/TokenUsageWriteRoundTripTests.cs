using System;
using System.IO;
using Microsoft.Data.Sqlite;
using OpenBurnBar.Storage;
using Xunit;

namespace OpenBurnBar.Storage.Tests;

/// <summary>
/// VAL-P0-DB-011 — the WRITE + MIGRATION round-trip proof.
///
/// Opens the committed Mac-produced SQLCipher fixture with the pinned params +
/// non-secret key, WRITES a <c>token_usage</c> row in a transaction, REOPENS the
/// file, and asserts the row round-trips AND the schema hash + migration marker +
/// <c>user_version</c> are unchanged — proving a Windows write leaves the file
/// byte-compatible and reopenable on Mac (the read-WRITE extension of the Wave-1
/// read seam #1198).
/// </summary>
public sealed class TokenUsageWriteRoundTripTests
{
    // Ground-truth invariants of the committed v58 fixture, observed by opening it
    // and reproducing DatabaseByteCompatVector.computeSchemaHash byte-for-byte.
    // Pinned as literals so corruption or an accidental migration is caught, not
    // merely self-consistency.
    private const string FixtureName = "openburnbar-db-compat-v59.sqlcipher";
    private const string ExpectedSchemaHash =
        "90baa98a7e1dbe2c0afc39962ab80383b555e003193c470798fb1c0f9c3160c0";
    private const string ExpectedMigrationEndpoint = "v59_founder_lens";
    private const long ExpectedMigrationCount = 60;
    private const long ExpectedUserVersion = 0;

    private static string FixtureSource =>
        Path.Combine(AppContext.BaseDirectory, "Fixtures", FixtureName);

    /// <summary>Copy the committed fixture to a fresh temp file so the committed bytes are never mutated.</summary>
    private static string CopyFixtureToWorkingFile()
    {
        Assert.True(File.Exists(FixtureSource), $"Committed fixture missing from test output: {FixtureSource}");
        string working = Path.Combine(
            Path.GetTempPath(),
            $"obb-writeseam-{Guid.NewGuid():N}.sqlcipher");
        File.Copy(FixtureSource, working, overwrite: true);
        return working;
    }

    private static void Cleanup(string path)
    {
        foreach (string suffix in new[] { "", "-wal", "-shm", "-journal" })
        {
            try { File.Delete(path + suffix); } catch { /* best-effort */ }
        }
    }

    [Fact]
    public void CommittedFixture_IsGenuinelyEncrypted_AndKeysToPinnedSqlCipher4Params()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            Assert.True(
                SqlCipherConnection.FileIsEncrypted(working),
                "Fixture starts with the plaintext SQLite magic header — it is NOT encrypted.");

            using var connection = SqlCipherConnection.Open(working, SqlCipherParameters.FixturePassphrase);
            SqlCipherConnection.AssertPinnedParams(connection, out string cipherVersion);
            Assert.StartsWith("4.", cipherVersion, StringComparison.Ordinal);
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void WrongKey_CannotOpenEncryptedFixture()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            // A wrong (but charset-valid) passphrase must fail the codec/HMAC check
            // in Open() — proving the file is genuinely encrypted and we are really
            // keying it, not silently reading plaintext.
            Assert.ThrowsAny<Exception>(() =>
            {
                using var _ = SqlCipherConnection.Open(working, "OBB-WinPort-WRONG-KEY-000000000000000000000=");
            });
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void WriteTokenUsage_RoundTripsAcrossReopen_WithStableSchemaAndPreservedMigrationMarker()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            // ── (1) Baseline snapshot of the pristine fixture ───────────────────
            string beforeHash;
            string beforeEndpoint;
            long beforeCount;
            long beforeUserVersion;
            using (var connection = SqlCipherConnection.Open(working, SqlCipherParameters.FixturePassphrase))
            {
                SqlCipherConnection.AssertPinnedParams(connection, out _);
                beforeHash = SqlCipherConnection.ComputeSchemaHash(connection);
                beforeEndpoint = SqlCipherConnection.ReadMigrationEndpoint(connection);
                beforeCount = SqlCipherConnection.ReadMigrationCount(connection);
                beforeUserVersion = SqlCipherConnection.ReadUserVersion(connection);
            }

            Assert.Equal(ExpectedSchemaHash, beforeHash);
            Assert.Equal(ExpectedMigrationEndpoint, beforeEndpoint);
            Assert.Equal(ExpectedMigrationCount, beforeCount);
            Assert.Equal(ExpectedUserVersion, beforeUserVersion);

            // ── (2) WRITE a row inside a transaction, then release the handle ────
            var record = new TokenUsageRecord
            {
                Id = "win-writeseam-roundtrip-0001",
                Provider = "WindowsPeer",
                SessionId = "s-win-roundtrip",
                ProjectName = "WinWriteSeam",
                Model = "opus-4.8",
                InputTokens = 111,
                OutputTokens = 222,
                CacheCreationTokens = 0,
                CacheReadTokens = 0,
                ReasoningTokens = 7,
                TotalTokens = 333,
                Cost = 0.42,
                StartTime = "2026-07-03 00:00:00.000",
                EndTime = "2026-07-03 00:01:00.000",
                CreatedAt = "2026-07-03 00:02:00.000",
                UsageSource = "measured",
                ExecutionSourceID = "visual-studio-code",
                ExecutionSourceName = "Visual Studio Code",
                ExecutionSourceKind = "ide",
                ExecutionSourceConfidence = "exact",
                IsRemote = false,
                ProvenanceMethod = "api",
                ProvenanceConfidence = "exact",
                EstimatorVersion = "win-writeseam-1",
            };

            using (var connection = SqlCipherConnection.Open(working, SqlCipherParameters.FixturePassphrase))
            {
                int affected = TokenUsageWriteSeam.WriteTokenUsage(connection, record);
                Assert.Equal(1, affected);
            }

            // ── (3) REOPEN a fresh connection and read the row back ─────────────
            using (var connection = SqlCipherConnection.Open(working, SqlCipherParameters.FixturePassphrase))
            {
                TokenUsageRecord? readBack = TokenUsageWriteSeam.ReadTokenUsage(connection, record.Id);
                Assert.NotNull(readBack);
                Assert.Equal(record.Provider, readBack!.Provider);
                Assert.Equal(record.SessionId, readBack.SessionId);
                Assert.Equal(record.Model, readBack.Model);
                Assert.Equal(record.InputTokens, readBack.InputTokens);
                Assert.Equal(record.OutputTokens, readBack.OutputTokens);
                Assert.Equal(record.ReasoningTokens, readBack.ReasoningTokens);
                Assert.Equal(record.TotalTokens, readBack.TotalTokens);
                Assert.Equal(record.Cost, readBack.Cost, precision: 9);
                Assert.Equal(record.StartTime, readBack.StartTime);
                Assert.Equal(record.EndTime, readBack.EndTime);
                Assert.Equal(record.ProvenanceConfidence, readBack.ProvenanceConfidence);
                Assert.Equal(record.ExecutionSourceID, readBack.ExecutionSourceID);
                Assert.Equal(record.ExecutionSourceName, readBack.ExecutionSourceName);
                Assert.Equal(record.ExecutionSourceKind, readBack.ExecutionSourceKind);
                Assert.Equal(record.ExecutionSourceConfidence, readBack.ExecutionSourceConfidence);

                // ── (4) Schema hash UNCHANGED — no accidental migration/corruption
                string afterHash = SqlCipherConnection.ComputeSchemaHash(connection);
                Assert.Equal(beforeHash, afterHash);
                Assert.Equal(ExpectedSchemaHash, afterHash);

                // ── (5) Migration marker + user_version PRESERVED (reopenable on Mac)
                Assert.Equal(ExpectedMigrationEndpoint, SqlCipherConnection.ReadMigrationEndpoint(connection));
                Assert.Equal(ExpectedMigrationCount, SqlCipherConnection.ReadMigrationCount(connection));
                Assert.Equal(ExpectedUserVersion, SqlCipherConnection.ReadUserVersion(connection));

                // Still genuinely encrypted after the write.
                Assert.StartsWith("4.", (ReadPragma(connection, "cipher_version") ?? string.Empty), StringComparison.Ordinal);
            }

            Assert.True(
                SqlCipherConnection.FileIsEncrypted(working),
                "File lost its encrypted header after the write — a plaintext leak.");
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void WriteTokenUsage_UpsertIsIdempotent_OnProductionNaturalKey()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            var record = new TokenUsageRecord
            {
                Id = "win-writeseam-upsert-A",
                Provider = "WindowsPeer",
                SessionId = "s-win-upsert",
                ProjectName = "WinWriteSeam",
                Model = "opus-4.8",
                TotalTokens = 100,
                Cost = 1.0,
                StartTime = "2026-07-03 00:00:00.000",
                EndTime = "2026-07-03 00:01:00.000",
                CreatedAt = "2026-07-03 00:02:00.000",
                ExecutionSourceID = "cursor",
                ExecutionSourceName = "Cursor",
                ExecutionSourceKind = "ide",
                ExecutionSourceConfidence = "exact",
            };

            long countBefore;
            string hashBefore;
            using (var connection = SqlCipherConnection.Open(working, SqlCipherParameters.FixturePassphrase))
            {
                countBefore = ScalarLong(connection, "SELECT count(*) FROM token_usage");
                hashBefore = SqlCipherConnection.ComputeSchemaHash(connection);
                Assert.Equal(1, TokenUsageWriteSeam.WriteTokenUsage(connection, record));
            }

            // Second write with the SAME natural key (provider, sessionId, model,
            // sourceDeviceId, providerAccountID) but new totals → upsert, not a new row.
            using (var connection = SqlCipherConnection.Open(working, SqlCipherParameters.FixturePassphrase))
            {
                TokenUsageWriteSeam.WriteTokenUsage(connection, record with { Id = "win-writeseam-upsert-B", TotalTokens = 999, Cost = 9.0 });
            }

            using (var connection = SqlCipherConnection.Open(working, SqlCipherParameters.FixturePassphrase))
            {
                long countAfter = ScalarLong(connection, "SELECT count(*) FROM token_usage");
                Assert.Equal(countBefore + 1, countAfter); // exactly one new row, upserted in place

                long totals = ScalarLong(
                    connection,
                    "SELECT totalTokens FROM token_usage WHERE provider='WindowsPeer' AND sessionId='s-win-upsert' AND model='opus-4.8'");
                Assert.Equal(999, totals); // the upsert updated totals

                TokenUsageRecord? readBack = TokenUsageWriteSeam.ReadTokenUsage(connection, record.Id);
                Assert.NotNull(readBack);
                Assert.Equal("cursor", readBack!.ExecutionSourceID);
                Assert.Equal("Cursor", readBack.ExecutionSourceName);
                Assert.Equal("ide", readBack.ExecutionSourceKind);
                Assert.Equal("exact", readBack.ExecutionSourceConfidence);

                Assert.Equal(hashBefore, SqlCipherConnection.ComputeSchemaHash(connection));
            }
        }
        finally
        {
            Cleanup(working);
        }
    }

    private static string? ReadPragma(SqliteConnection connection, string pragma)
    {
        using var command = connection.CreateCommand();
        command.CommandText = $"PRAGMA {pragma};";
        return command.ExecuteScalar()?.ToString();
    }

    private static long ScalarLong(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return Convert.ToInt64(command.ExecuteScalar());
    }
}
