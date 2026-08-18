using System;
using System.IO;
using System.Linq;
using OpenBurnBar.Storage;
using Xunit;

namespace OpenBurnBar.App.TextExpansion.Tests;

/// <summary>
/// The persistence round-trip for <see cref="TextExpansionSnippetWriteSeam"/> — the
/// SQLCipher peer of the Mac GRDB <c>TextExpansionSnippetStore</c>. Opens the SAME
/// committed Mac-produced encrypted fixture the storage byte-compat suite opens,
/// upserts a snippet in a transaction, reopens, and asserts the row round-trips AND
/// the schema hash is unchanged (no accidental migration) — proving a Windows snippet
/// write leaves the file byte-compatible and reopenable on Mac. Mirrors
/// OpenBurnBar.Storage.Tests/TokenUsageWriteRoundTripTests.
/// </summary>
public sealed class SnippetSqlCipherStoreRoundTripTests
{
    private const string FixtureName = "openburnbar-db-compat-v64.sqlcipher";

    private static string FixtureSource => Path.Combine(AppContext.BaseDirectory, "Fixtures", FixtureName);

    private static string CopyFixtureToWorkingFile()
    {
        Assert.True(File.Exists(FixtureSource), $"Committed fixture missing from test output: {FixtureSource}");
        string working = Path.Combine(Path.GetTempPath(), $"obb-textexp-{Guid.NewGuid():N}.sqlcipher");
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

    private static TextExpansionSnippetRow SampleRow(string id, string trigger) => new(
        Id: id,
        Title: "Win Round-trip",
        Trigger: trigger,
        Body: "Windows-written snippet body.",
        Mode: "static",
        IsEnabled: true,
        ScopeJson: "{\"surfaces\":[\"mac_global\"],\"bundleIdentifiers\":[],\"threadIDs\":[]}",
        Revision: 1,
        CreatedAt: new DateTimeOffset(2026, 7, 3, 0, 0, 0, TimeSpan.Zero),
        UpdatedAt: new DateTimeOffset(2026, 7, 3, 0, 1, 0, TimeSpan.Zero),
        DeletedAt: null,
        SyncedAt: null,
        SourceDeviceId: "win-dev-host");

    [Fact]
    public void UpsertSnippet_RoundTripsAcrossReopen_WithStableSchemaHash()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            string id = $"win-textexp-{Guid.NewGuid():N}";
            var row = SampleRow(id, trigger: "&&TXWinRoundtrip"); // non-canonical on purpose

            string beforeHash;
            long countBefore;
            using (var connection = SqlCipherConnection.Open(working, SqlCipherParameters.FixturePassphrase))
            {
                beforeHash = SqlCipherConnection.ComputeSchemaHash(connection);
                countBefore = TextExpansionSnippetWriteSeam.Count(connection);
                Assert.Equal(1, TextExpansionSnippetWriteSeam.Upsert(connection, row));
            }

            using (var connection = SqlCipherConnection.Open(working, SqlCipherParameters.FixturePassphrase))
            {
                var readBack = TextExpansionSnippetWriteSeam.Read(connection, id);
                Assert.NotNull(readBack);
                Assert.Equal("txwinroundtrip", readBack!.Trigger); // canonicalized by the seam
                Assert.Equal(row.Title, readBack.Title);
                Assert.Equal(row.Body, readBack.Body);
                Assert.Equal("static", readBack.Mode);
                Assert.True(readBack.IsEnabled);
                Assert.Equal(row.ScopeJson, readBack.ScopeJson);
                Assert.Equal(row.CreatedAt.UtcDateTime, readBack.CreatedAt.UtcDateTime);
                Assert.Equal(row.UpdatedAt.UtcDateTime, readBack.UpdatedAt.UtcDateTime);
                Assert.Null(readBack.DeletedAt);
                Assert.Null(readBack.SyncedAt); // markUnsynced default
                Assert.Equal("win-dev-host", readBack.SourceDeviceId);

                // A markUnsynced write is pending sync.
                Assert.Contains(TextExpansionSnippetWriteSeam.FetchUnsynced(connection), r => r.Id == id);

                Assert.Equal(countBefore + 1, TextExpansionSnippetWriteSeam.Count(connection));

                // Schema hash UNCHANGED — the write did not migrate or corrupt the schema.
                Assert.Equal(beforeHash, SqlCipherConnection.ComputeSchemaHash(connection));
            }

            Assert.True(SqlCipherConnection.FileIsEncrypted(working), "File lost its encrypted header after the write.");
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void Upsert_IsIdempotentOnId_AndUpdatesInPlace()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            string id = $"win-textexp-{Guid.NewGuid():N}";
            using (var connection = SqlCipherConnection.Open(working, SqlCipherParameters.FixturePassphrase))
            {
                long before = TextExpansionSnippetWriteSeam.Count(connection);
                TextExpansionSnippetWriteSeam.Upsert(connection, SampleRow(id, "trigalpha"));
                var updated = SampleRow(id, "trigalpha") with { Body = "Edited body." };
                TextExpansionSnippetWriteSeam.Upsert(connection, updated);

                Assert.Equal(before + 1, TextExpansionSnippetWriteSeam.Count(connection)); // one row, updated in place
                Assert.Equal("Edited body.", TextExpansionSnippetWriteSeam.Read(connection, id)!.Body);
            }
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void SoftDelete_FiltersFromFetchAll_BumpsRevision_AndNullsSynced()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            string id = $"win-textexp-{Guid.NewGuid():N}";
            using (var connection = SqlCipherConnection.Open(working, SqlCipherParameters.FixturePassphrase))
            {
                TextExpansionSnippetWriteSeam.Upsert(connection, SampleRow(id, "trigdelete"));
                TextExpansionSnippetWriteSeam.MarkSynced(connection, new[] { id }, new DateTimeOffset(2026, 7, 4, 0, 0, 0, TimeSpan.Zero));
                Assert.DoesNotContain(TextExpansionSnippetWriteSeam.FetchUnsynced(connection), r => r.Id == id);

                Assert.Equal(1, TextExpansionSnippetWriteSeam.Delete(connection, id, new DateTimeOffset(2026, 7, 5, 0, 0, 0, TimeSpan.Zero)));

                Assert.DoesNotContain(TextExpansionSnippetWriteSeam.FetchAll(connection), r => r.Id == id);
                Assert.Contains(TextExpansionSnippetWriteSeam.FetchAll(connection, includeDeleted: true), r => r.Id == id);

                var deleted = TextExpansionSnippetWriteSeam.Read(connection, id);
                Assert.NotNull(deleted);
                Assert.NotNull(deleted!.DeletedAt);
                Assert.False(deleted.IsEnabled);
                Assert.Equal(2, deleted.Revision);   // 1 → 2 on soft delete
                Assert.Null(deleted.SyncedAt);        // delete re-marks unsynced
            }
        }
        finally
        {
            Cleanup(working);
        }
    }
}
