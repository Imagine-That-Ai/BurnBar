using System;
using System.IO;
using System.Text;
using Microsoft.Data.Sqlite;
using OpenBurnBar.App.Quota.Acquisition;
using OpenBurnBar.Storage;
using Xunit;

namespace OpenBurnBar.App.Quota.Acquisition.Tests;

/// <summary>
/// Mechanism 2 state.vscdb read — parity with CursorCookieExtractor. The fixture
/// database is CONSTRUCTED IN-TEST via Microsoft.Data.Sqlite (ItemTable key/value,
/// the real Cursor schema) so the tree stays text-only.
/// </summary>
public sealed class CursorStateDbReaderTests : IDisposable
{
    private readonly string _dir = AcquisitionTestSupport.CreateTempDirectory();

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    /// <summary>An unsigned JWT whose payload is <c>{"sub":"auth0|user_2abc123"}</c>.</summary>
    internal static string MakeJwt(string sub)
    {
        static string B64Url(string json) =>
            Convert.ToBase64String(Encoding.UTF8.GetBytes(json))
                .TrimEnd('=')
                .Replace('+', '-')
                .Replace('/', '_');

        return $"{B64Url("{\"alg\":\"HS256\",\"typ\":\"JWT\"}")}.{B64Url($"{{\"sub\":\"{sub}\"}}")}.sig";
    }

    private string BuildStateDb(params (string Key, object Value)[] items)
    {
        SqlCipherParameters.EnsureProviderInitialized();
        var path = Path.Combine(_dir, "state.vscdb");
        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
        }.ToString();

        using var connection = new SqliteConnection(connectionString);
        connection.Open();
        using (var create = connection.CreateCommand())
        {
            // The VS Code / Cursor ItemTable schema.
            create.CommandText = "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);";
            create.ExecuteNonQuery();
        }

        foreach (var (key, value) in items)
        {
            using var insert = connection.CreateCommand();
            insert.CommandText = "INSERT INTO ItemTable (key, value) VALUES ($key, $value);";
            insert.Parameters.AddWithValue("$key", key);
            insert.Parameters.AddWithValue("$value", value);
            insert.ExecuteNonQuery();
        }

        return path;
    }

    [Fact]
    public void TryRead_ExtractsCookieEmailAndMembership()
    {
        var jwt = MakeJwt("auth0|user_2abc123");
        var path = BuildStateDb(
            (CursorStateDbReader.AccessTokenKey, jwt),
            (CursorStateDbReader.CachedEmailKey, "alberto@example.com"),
            (CursorStateDbReader.MembershipTypeKey, "pro"));

        CursorStateCredentials? credentials = CursorStateDbReader.TryRead(path);

        Assert.NotNull(credentials);
        Assert.Equal($"WorkosCursorSessionToken=user_2abc123::{jwt}", credentials!.CookieHeader);
        Assert.Equal("alberto@example.com", credentials.CachedEmail);
        Assert.Equal("pro", credentials.MembershipType);
    }

    [Fact]
    public void TryRead_BlobStoredValues_AreDecodedAsUtf8()
    {
        var jwt = MakeJwt("google-oauth2|118");
        var path = BuildStateDb(
            (CursorStateDbReader.AccessTokenKey, Encoding.UTF8.GetBytes(jwt)),
            (CursorStateDbReader.CachedEmailKey, Encoding.UTF8.GetBytes("\"blob@example.com\"")));

        CursorStateCredentials? credentials = CursorStateDbReader.TryRead(path);

        Assert.NotNull(credentials);
        Assert.Equal("118", credentials!.UserId);
        // JSON-encoded string values are unwrapped.
        Assert.Equal("blob@example.com", credentials.CachedEmail);
    }

    [Fact]
    public void TryRead_SubWithoutPipe_UsesWholeSub()
    {
        var path = BuildStateDb((CursorStateDbReader.AccessTokenKey, MakeJwt("plainuser")));

        Assert.Equal("plainuser", CursorStateDbReader.TryRead(path)!.UserId);
    }

    [Fact]
    public void TryRead_MissingDatabase_YieldsNull()
    {
        Assert.Null(CursorStateDbReader.TryRead(Path.Combine(_dir, "absent.vscdb")));
    }

    [Fact]
    public void TryRead_MissingTokenRow_YieldsNull()
    {
        var path = BuildStateDb((CursorStateDbReader.CachedEmailKey, "x@example.com"));

        Assert.Null(CursorStateDbReader.TryRead(path));
    }

    [Fact]
    public void TryRead_MalformedJwt_YieldsNull()
    {
        var path = BuildStateDb((CursorStateDbReader.AccessTokenKey, "not-a-jwt"));

        Assert.Null(CursorStateDbReader.TryRead(path));
    }

    [Fact]
    public void TryRead_OpensReadOnly_SourceDbIsNotModified()
    {
        var jwt = MakeJwt("auth0|u1");
        var path = BuildStateDb((CursorStateDbReader.AccessTokenKey, jwt));
        var before = File.GetLastWriteTimeUtc(path);
        var bytes = File.ReadAllBytes(path);

        _ = CursorStateDbReader.TryRead(path);

        Assert.Equal(before, File.GetLastWriteTimeUtc(path));
        Assert.Equal(bytes, File.ReadAllBytes(path));
    }
}
