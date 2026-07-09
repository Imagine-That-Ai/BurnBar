using System.Collections.Generic;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.SessionLogs;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Session-log fallback is an honest empty source (H0 rename of the old Sample-named helper).
/// </summary>
public sealed class SessionLogEmptySourceTests
{
    [Fact]
    public async Task CreateReadSource_ListsEmpty()
    {
        ISessionLogReadSource source = SessionLogEmptySource.CreateReadSource();
        IReadOnlyList<SessionLogRecord> rows = await source.ListAsync();
        Assert.Empty(rows);
    }

    [Fact]
    public async Task CreateReadSource_SearchReturnsEmpty()
    {
        ISessionLogReadSource source = SessionLogEmptySource.CreateReadSource();
        IReadOnlyList<string> ids = await source.SearchMatchingIdsAsync("anything");
        Assert.Empty(ids);
    }

    [Fact]
    public void CreateReadSource_IsSingletonInstance()
    {
        Assert.Same(SessionLogEmptySource.CreateReadSource(), SessionLogEmptySource.CreateReadSource());
    }
}
