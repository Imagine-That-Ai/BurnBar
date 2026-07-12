using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Database;
using OpenBurnBar.App.Presentation.SessionLogs;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Database;

public sealed class DatabaseBrowseViewModelTests
{
    [Fact]
    public async Task LoadAsync_EmptySource_IsHonestEmpty()
    {
        var vm = new DatabaseBrowseViewModel(new FakeSessionSource(Array.Empty<SessionLogRecord>()));
        await vm.LoadAsync();
        Assert.True(vm.IsEmpty);
        Assert.Empty(vm.Sessions);
        Assert.Contains("No tracked sessions", vm.Status, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task LoadAsync_WithSessions_ListsRecords()
    {
        var records = new[]
        {
            new SessionLogRecord(
                "1", "claude", "Claude", "s1", "proj-a", "Task A", "body", 3,
                DateTimeOffset.UtcNow),
        };
        var vm = new DatabaseBrowseViewModel(new FakeSessionSource(records));
        await vm.LoadAsync();
        Assert.False(vm.IsEmpty);
        Assert.Single(vm.Sessions);
        Assert.Contains("1 tracked session", vm.Status, StringComparison.OrdinalIgnoreCase);
    }

    private sealed class FakeSessionSource : ISessionLogReadSource
    {
        private readonly IReadOnlyList<SessionLogRecord> _items;

        public FakeSessionSource(IReadOnlyList<SessionLogRecord> items) => _items = items;

        public Task<IReadOnlyList<SessionLogRecord>> ListAsync(int limit = 200, CancellationToken cancellationToken = default)
            => Task.FromResult(_items);

        public Task<IReadOnlyList<string>> SearchMatchingIdsAsync(string query, int limit = 200, CancellationToken cancellationToken = default)
            => Task.FromResult<IReadOnlyList<string>>(Array.Empty<string>());
    }
}
