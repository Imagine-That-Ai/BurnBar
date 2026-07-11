using System;
using System.Collections.Generic;
using System.Threading;
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

    [Fact]
    public async Task ListAsync_CanceledToken_ThrowsOperationCanceled()
    {
        ISessionLogReadSource source = SessionLogEmptySource.CreateReadSource();
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => source.ListAsync(cancellationToken: cts.Token));
    }

    [Fact]
    public async Task SearchMatchingIdsAsync_CanceledToken_ThrowsOperationCanceled()
    {
        ISessionLogReadSource source = SessionLogEmptySource.CreateReadSource();
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => source.SearchMatchingIdsAsync("q", cancellationToken: cts.Token));
    }
}
