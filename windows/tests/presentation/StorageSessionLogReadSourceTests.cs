using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.SessionLogs;
using OpenBurnBar.Storage;
using OpenBurnBar.Storage.SessionLogs;
using Xunit;
using PresentationSessionLogReadSource = OpenBurnBar.App.Presentation.SessionLogs.StorageSessionLogReadSource;
using StorageSessionLogAdapter = OpenBurnBar.Storage.SessionLogs.StorageSessionLogReadSource;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// End-to-end proof that the Windows session-logs surface reads the shared, encrypted,
/// Mac-produced database: the presentation read seam (<see cref="ISessionLogReadSource"/>)
/// wired through the real SQLCipher DataStore adapter
/// (<see cref="StorageSessionLogReadSource"/>) against the COMMITTED byte-compat
/// fixture (VAL-P0-DB-010). Runs on the macOS authoring host today; the same managed
/// assemblies ship on Windows (native SQLCipher per-RID from the bundle).
/// </summary>
public sealed class StorageSessionLogReadSourceTests
{
    private static StorageSessionLogAdapter OpenSource(out OpenBurnBarStorage storage)
    {
        storage = OpenBurnBarStorage.OpenReadOnly(FixturePath, SqlCipherParameters.FixturePassphrase);
        return new StorageSessionLogAdapter(storage);
    }

    [Fact]
    public async Task List_ReturnsSeededCorpus_MappedToPresentationRecords()
    {
        var source = OpenSource(out var storage);
        using (storage)
        {
            var records = await source.ListAsync();
            var ids = records.Select(r => r.Id).ToHashSet(StringComparer.Ordinal);

            Assert.Contains("conv-alpha-fox", ids);
            Assert.Contains("conv-beta-run", ids);
            Assert.Contains("conv-gamma-db", ids);

            var beta = records.Single(r => r.Id == "conv-beta-run");
            Assert.Equal("Claude Code", beta.Provider);
            Assert.Equal("Claude Code", beta.ProviderDisplayName);
            Assert.Equal("s-beta", beta.SessionId);
            Assert.Equal("ByteCompat", beta.ProjectName);
            Assert.Equal("Beta Running Log", beta.InferredTaskTitle);
            Assert.Contains("running shoes", beta.FullText, StringComparison.Ordinal);
            Assert.Equal("Beta Running Log", beta.DisplayTitle);
        }
    }

    [Fact]
    public async Task Search_ReturnsFtsRankedIds()
    {
        var source = OpenSource(out var storage);
        using (storage)
        {
            var forRun = await source.SearchMatchingIdsAsync("run");
            Assert.Equal(new[] { "conv-beta-run", "conv-alpha-fox" }, forRun);

            var forGamma = await source.SearchMatchingIdsAsync("GAMMA");
            Assert.Equal(new[] { "conv-gamma-db" }, forGamma);
        }
    }

    [Fact]
    public async Task ViewModel_LoadThenSearch_DrivesGroupedListFromRealDb()
    {
        var source = OpenSource(out var storage);
        using (storage)
        {
            var vm = new SessionLogsViewModel(source, () => new DateTimeOffset(2026, 7, 22, 12, 0, 0, TimeSpan.Zero))
            {
                GroupMode = SessionLogGroupMode.Provider,
            };
            await vm.LoadAsync();

            Assert.False(vm.IsLoading);
            Assert.Null(vm.ErrorMessage);
            Assert.True(vm.FilteredCount >= 3);
            Assert.Contains(vm.Groups, g => g.Title == "Claude Code");

            // Local FTS search narrows to the two "run" matches, in rank order.
            await vm.UpdateSearchAsync("run");
            Assert.Equal(new[] { "conv-beta-run", "conv-alpha-fox" }, vm.FilteredLogs.Select(r => r.Id));

            // Clearing the query restores the full set.
            await vm.UpdateSearchAsync("");
            Assert.True(vm.FilteredCount >= 3);
        }
    }

    [Theory]
    [InlineData("run", "\"run\"")]
    [InlineData("  GAMMA  ", "\"GAMMA\"")]
    [InlineData("db schema", "\"db\" \"schema\"")]
    [InlineData("weird\"; drop", "\"weird\" \"drop\"")] // punctuation/quotes stripped → safe
    [InlineData("   ", "")]
    public void BuildFtsMatch_QuotesTerms_AndStripsPunctuation(string input, string expected)
    {
        Assert.Equal(expected, PresentationSessionLogReadSource.BuildFtsMatch(input));
    }

    // ---- fixture location (walks up to the committed DBByteCompat fixtures) ----

    private static string FixturePath
    {
        get
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            while (dir is not null)
            {
                var candidate = Path.Combine(dir.FullName, "AgentLensTests", "Fixtures", "DBByteCompat");
                if (File.Exists(Path.Combine(candidate, "openburnbar-db-compat-vector.json")))
                {
                    var pinned = Path.Combine(candidate, "openburnbar-db-compat-v64.sqlcipher");
                    if (File.Exists(pinned))
                    {
                        return pinned;
                    }

                    var any = Directory.GetFiles(candidate, "*.sqlcipher");
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
}
