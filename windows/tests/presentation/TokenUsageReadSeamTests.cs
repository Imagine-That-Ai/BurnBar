using System;
using System.IO;
using OpenBurnBar.Storage;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

public sealed class TokenUsageReadSeamTests
{
    [Fact]
    public void Aggregates_ReadNonNegative_OnCommittedFixture()
    {
        using var store = OpenBurnBarStorage.OpenReadOnly(DbByteCompatFixturePath(), SqlCipherParameters.FixturePassphrase);
        var connection = store.Connection;

        long sessions = TokenUsageReadSeam.CountDistinctSessions(connection);
        long tokens = TokenUsageReadSeam.SumTotalTokens(connection);
        double spend = TokenUsageReadSeam.SumCostCurrentUtcMonth(connection);

        Assert.True(sessions >= 0);
        Assert.True(tokens >= 0);
        Assert.True(spend >= 0);
    }

    internal static string DbByteCompatFixturePath()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            string candidate = Path.Combine(dir.FullName, "AgentLensTests", "Fixtures", "DBByteCompat");
            if (File.Exists(Path.Combine(candidate, "openburnbar-db-compat-vector.json")))
            {
                string pinned = Path.Combine(candidate, "openburnbar-db-compat-v64.sqlcipher");
                if (File.Exists(pinned))
                {
                    return pinned;
                }

                string[] any = Directory.GetFiles(candidate, "*.sqlcipher");
                if (any.Length == 1)
                {
                    return any[0];
                }
            }

            dir = dir.Parent;
        }

        throw new DirectoryNotFoundException(
            "Could not locate AgentLensTests/Fixtures/DBByteCompat by walking up from "
            + AppContext.BaseDirectory);
    }
}
