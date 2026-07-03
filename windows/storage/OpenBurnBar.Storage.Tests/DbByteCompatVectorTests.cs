using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using Xunit;
using Xunit.Abstractions;

namespace OpenBurnBar.Storage.Tests;

/// <summary>
/// The headline R2 proof (VAL-P0-DB-010): open the committed <b>Mac-produced</b>
/// SQLCipher database with the pinned compatibility-4 profile + the non-secret
/// fixture key, and reproduce the committed schema hash + FTS5 <c>bm25()</c>/
/// <c>snippet()</c> vector byte-for-byte. If this passes, the Windows storage
/// layer genuinely reads the same encrypted file the Mac writes.
/// </summary>
public sealed class DbByteCompatVectorTests
{
    private readonly ITestOutputHelper _output;

    public DbByteCompatVectorTests(ITestOutputHelper output)
    {
        _output = output;
    }

    [Fact]
    public void CommittedFixture_IsGenuinelyEncrypted()
    {
        // The fixture must NOT start with the plaintext SQLite magic header,
        // proving we are opening a real SQLCipher-encrypted file (mirrors the
        // macOS assertFileIsEncrypted guard).
        using var handle = File.OpenRead(RepoFixtures.FixturePath);
        var header = new byte[16];
        var read = handle.Read(header, 0, header.Length);
        Assert.Equal(16, read);

        var plaintextMagic = System.Text.Encoding.ASCII.GetBytes("SQLite format 3\0");
        Assert.False(
            header.SequenceEqual(plaintextMagic),
            "Fixture starts with the plaintext SQLite magic header — it is NOT encrypted.");
    }

    [Fact]
    public void OpensMacFixture_WithPinnedCipherProfile_Active()
    {
        using var storage = OpenBurnBarStorage.OpenReadOnly(
            RepoFixtures.FixturePath, SqlCipherParameters.FixturePassphrase);

        var observed = storage.ReadObservedCipherParams();
        _output.WriteLine($"cipher_version         = {observed.CipherVersion}");
        _output.WriteLine($"cipher_provider        = {observed.CipherProvider}");
        _output.WriteLine($"cipher_page_size       = {observed.CipherPageSize}");
        _output.WriteLine($"kdf_iter               = {observed.KdfIter}");
        _output.WriteLine($"cipher_hmac_algorithm  = {observed.HmacAlgorithm}");
        _output.WriteLine($"cipher_kdf_algorithm   = {observed.KdfAlgorithm}");

        Assert.StartsWith("4.", observed.CipherVersion, StringComparison.Ordinal);
        Assert.Equal(SqlCipherParameters.CipherPageSize, observed.CipherPageSize);
        Assert.Equal(SqlCipherParameters.KdfIter, observed.KdfIter);
        Assert.Equal(SqlCipherParameters.HmacAlgorithm, observed.HmacAlgorithm);
        Assert.Equal(SqlCipherParameters.KdfAlgorithm, observed.KdfAlgorithm);
    }

    [Fact]
    public void ByteCompatParams_MatchMacObservation_AcrossProviders()
    {
        // The committed params-observed.json is the readback from the Mac's
        // SQLCipher 4.16.0 / commoncrypto build. The Windows stack links a
        // DIFFERENT SQLCipher (bundle_e_sqlcipher, e.g. 4.5.x / libtomcrypt).
        // Byte-compat is defined by the KDF/HMAC/page parameters, NOT the crypto
        // provider — so those four MUST agree across the two builds, while
        // cipher_version / cipher_provider legitimately differ. This is the core
        // R2 invariant from decisions/sqlcipher-params.md, proven empirically.
        var macParams = ParseObservedParams(RepoFixtures.ParamsPath);

        using var storage = OpenBurnBarStorage.OpenReadOnly(
            RepoFixtures.FixturePath, SqlCipherParameters.FixturePassphrase);
        var win = storage.ReadObservedCipherParams();

        _output.WriteLine($"Mac cipher_version={macParams["cipher_version"]} provider={macParams["cipher_provider"]}");
        _output.WriteLine($"Win cipher_version={win.CipherVersion} provider={win.CipherProvider}");

        Assert.Equal(macParams["cipher_page_size"], win.CipherPageSize.ToString());
        Assert.Equal(macParams["kdf_iter"], win.KdfIter.ToString());
        Assert.Equal(macParams["cipher_hmac_algorithm"], win.HmacAlgorithm);
        Assert.Equal(macParams["cipher_kdf_algorithm"], win.KdfAlgorithm);

        // Both must be a SQLCipher 4.x family build (major-version byte-compat window).
        Assert.StartsWith("4.", macParams["cipher_version"], StringComparison.Ordinal);
        Assert.StartsWith("4.", win.CipherVersion, StringComparison.Ordinal);
    }

    private static Dictionary<string, string> ParseObservedParams(string path)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var element in doc.RootElement.EnumerateArray())
        {
            map[element.GetProperty("name").GetString()!] = element.GetProperty("value").GetString()!;
        }

        return map;
    }

    [Fact]
    public void ReproducesCommittedVector_SchemaHash_And_FtsRowSet()
    {
        var expected = DbCompatVector.LoadVector(RepoFixtures.VectorPath);

        using var storage = OpenBurnBarStorage.OpenReadOnly(
            RepoFixtures.FixturePath, SqlCipherParameters.FixturePassphrase);

        var report = DbCompatVector.Verify(storage, expected);

        _output.WriteLine($"sqlcipherPin (vector)  = {expected.SqlcipherPin}");
        _output.WriteLine($"schemaEndpoint (vector)= {expected.SchemaEndpoint}");
        _output.WriteLine($"migrationCount (vector)= {expected.MigrationCount}");
        _output.WriteLine($"sqlite_master objects  = {report.ObjectCount}");
        _output.WriteLine($"expected schemaHash    = {report.ExpectedSchemaHash}");
        _output.WriteLine($"actual   schemaHash    = {report.ActualSchemaHash}");
        _output.WriteLine($"schemaHash matches     = {report.SchemaHashMatches}");
        _output.WriteLine($"FTS row set matches    = {report.FtsRowSetMatches}");
        foreach (var q in report.ActualFtsQueries)
        {
            var rows = string.Join(" | ", q.OrderedRows.Select(r => $"{r.ConversationId}::{r.Snippet}"));
            _output.WriteLine($"  [{q.Label}] MATCH '{q.Match}' => {rows}");
        }

        Assert.True(report.ObjectCount > 0, "Opened database exposed zero schema objects — it did not decrypt.");
        Assert.Equal(expected.SchemaHashSha256, report.ActualSchemaHash);
        Assert.True(report.SchemaHashMatches, "Schema hash diverged from the committed vector.");
        Assert.True(report.FtsRowSetMatches, "FTS5 bm25()/snippet() row set diverged from the committed vector.");
        Assert.True(report.Passed, "Byte-compat verification did not pass.");
    }

    [Fact]
    public void FtsVector_HasExpectedSemantics()
    {
        var expected = DbCompatVector.LoadVector(RepoFixtures.VectorPath);
        using var storage = OpenBurnBarStorage.OpenReadOnly(
            RepoFixtures.FixturePath, SqlCipherParameters.FixturePassphrase);

        var actual = DbCompatVector.RunFtsVector(storage.Connection);

        // Porter stemming: "run" matches beta (4×, best bm25) then alpha (1×); gamma absent.
        var run = actual.Single(q => q.Label == "porter-stem-run");
        Assert.Equal(new[] { "conv-beta-run", "conv-alpha-fox" }, run.OrderedRows.Select(r => r.ConversationId));

        // Case-folding on the title column (col 0): uppercase "GAMMA" matches "Gamma Crypto".
        var gamma = actual.Single(q => q.Label == "case-fold-title");
        Assert.Equal(new[] { "conv-gamma-db" }, gamma.OrderedRows.Select(r => r.ConversationId));

        // Full-text column match + snippet markup on the matched term.
        var db = actual.Single(q => q.Label == "fulltext-database");
        Assert.Equal(new[] { "conv-gamma-db" }, db.OrderedRows.Select(r => r.ConversationId));
        Assert.Equal("<b>database</b> encryption keeps your data safe at rest", db.OrderedRows[0].Snippet);

        // Porter stemming: "shoe" matches beta (shoes → shoe) only.
        var shoe = actual.Single(q => q.Label == "porter-stem-shoe");
        Assert.Equal(new[] { "conv-beta-run" }, shoe.OrderedRows.Select(r => r.ConversationId));

        // And the whole observed vector equals what the committed file already asserted.
        Assert.True(DbCompatVector.Verify(storage, expected).FtsRowSetMatches);
    }
}
