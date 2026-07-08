using System;
using System.IO;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using OpenBurnBar.B0Spike.Cli;
using OpenBurnBar.B0Spike.Tests.Support;
using OpenBurnBar.Storage;
using Xunit;
using Xunit.Abstractions;

namespace OpenBurnBar.B0Spike.Tests;

/// <summary>
/// WS-B0 walking proof: Swift Engine parse (subprocess) → SQLCipher row → live-tile readback.
/// ConPTY stream is authored; interactive proof is Windows-only (VAL-P0-CONPTY-019).
/// </summary>
public sealed class B0EndToEndSpikeTests
{
    private readonly ITestOutputHelper _output;

    public B0EndToEndSpikeTests(ITestOutputHelper output) => _output = output;

    [Fact]
    public async Task SwiftEngine_ParseStep_G2ParityPasses()
    {
        (int exitCode, string stdout, string stderr) =
            await SwiftEngineParseBridge.RunG2ParserParityAsync();

        if (!string.IsNullOrWhiteSpace(stdout))
        {
            _output.WriteLine(stdout);
        }

        if (!string.IsNullOrWhiteSpace(stderr))
        {
            _output.WriteLine(stderr);
        }

        Assert.Equal(0, exitCode);
    }

    [Fact]
    public void ParserFixture_IsOnDisk_ForClaudeBasicSession()
    {
        string path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "pc-claude-basic-session.jsonl");
        Assert.True(File.Exists(path));
        Assert.True(new FileInfo(path).Length > 0);
    }

    [Fact]
    public void Storage_ParseGolden_WriteRead_LiveTileRoundTrips()
    {
        ParserContractUsage golden = ParserContractGolden.LoadClaudeCodeSessionUsage();
        TokenUsageRecord record = LiveTileReadback.FromParserContract(
            golden,
            rowId: "b0-spike-e2e-claude-basic-session");

        string dbPath = LiveTileReadback.CopyDbFixture();
        try
        {
            using (var connection = SqlCipherConnection.Open(dbPath, SqlCipherParameters.FixturePassphrase))
            {
                SqlCipherConnection.AssertPinnedParams(connection, out _);
                int affected = TokenUsageWriteSeam.WriteTokenUsage(connection, record);
                Assert.Equal(1, affected);
            }

            using (var connection = SqlCipherConnection.Open(dbPath, SqlCipherParameters.FixturePassphrase))
            {
                TokenUsageRecord? readBack = TokenUsageWriteSeam.ReadTokenUsage(connection, record.Id);
                Assert.NotNull(readBack);
                Assert.Equal(record.Provider, readBack!.Provider);
                Assert.Equal(record.SessionId, readBack.SessionId);
                Assert.Equal(record.Model, readBack.Model);
                Assert.Equal(record.InputTokens, readBack.InputTokens);
                Assert.Equal(record.OutputTokens, readBack.OutputTokens);
                Assert.Equal(record.TotalTokens, readBack.TotalTokens);
                Assert.Equal(record.Cost, readBack.Cost, precision: 9);

                string tile = LiveTileReadback.FormatTile(readBack);
                _output.WriteLine(tile);
                Assert.Contains("claude-basic-session", tile, StringComparison.Ordinal);
                Assert.Contains("Claude Code", tile, StringComparison.Ordinal);
            }
        }
        finally
        {
            TryDelete(dbPath);
        }
    }

    [Fact]
    public async Task ConPtyCliStream_OnNonWindows_ThrowsBeforeSpawn()
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }

        var stream = new ConPtyCliStream("cmd.exe /c echo b0-spike");
        await Assert.ThrowsAsync<PlatformNotSupportedException>(async () =>
        {
            await foreach (CliStreamEvent _ in stream.ReadAsync(default))
            {
            }
        });
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (IOException)
        {
        }
    }
}