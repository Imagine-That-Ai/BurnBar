using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Projects;
using OpenBurnBar.App.Presentation.SessionLogs;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Projects;

public sealed class ProjectsListViewModelTests
{
    [Fact]
    public async Task LoadAsync_EmptySource_IsHonestEmpty_WithWpdDisclosure()
    {
        var vm = new ProjectsListViewModel(new FakeSessionSource(Array.Empty<SessionLogRecord>()));
        await vm.LoadAsync();
        Assert.True(vm.IsEmpty);
        Assert.Contains("WPD-0003", vm.DepthDisclosure, StringComparison.Ordinal);
        Assert.Contains("No project groups", vm.Status, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task LoadAsync_GroupsByProjectName()
    {
        var now = DateTimeOffset.UtcNow;
        var records = new[]
        {
            new SessionLogRecord("1", "claude", "Claude", "s1", "alpha", "T1", "b", 1, now),
            new SessionLogRecord("2", "claude", "Claude", "s2", "alpha", "T2", "b", 1, now),
            new SessionLogRecord("3", "codex", "Codex", "s3", "beta", "T3", "b", 1, now),
            new SessionLogRecord("4", "codex", "Codex", "s4", "", "T4", "b", 1, now),
        };
        var vm = new ProjectsListViewModel(new FakeSessionSource(records));
        await vm.LoadAsync();
        Assert.False(vm.IsEmpty);
        Assert.Equal(3, vm.Projects.Count);
        Assert.Equal("alpha", vm.Projects[0].ProjectKey);
        Assert.Equal(2, vm.Projects[0].SessionCount);
        Assert.Contains(vm.Projects, p => p.ProjectKey == "Unassigned");
    }

    [Fact]
    public async Task LoadAsync_UsesConfiguredStaticParserForCodeSymbols()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-vm-parser-" + Path.GetRandomFileName());
        Directory.CreateDirectory(root);
        try
        {
            File.WriteAllText(Path.Combine(root, "Runner.swift"), "struct Runner {}\n");
            var parser = new DelegateProjectCodeStaticParserClient((request, _) =>
                Task.FromResult(new ProjectCodeParseResponse(
                    true,
                    false,
                    new[] { new ProjectCodeParsedSymbol("Runner", "struct", 1, 1, "static_tree_sitter", true, "tree-sitter") },
                    Array.Empty<string>(),
                    "tree-sitter",
                    true)));

            using var index = new ProjectCodeSymbolIndex(root);
            var vm = new ProjectsListViewModel(
                new FakeSessionSource(Array.Empty<SessionLogRecord>()),
                index,
                parser);
            await vm.LoadAsync();
            Assert.Contains(vm.CodeSymbols, symbol => symbol.Name == "Runner");
            Assert.Contains("Tree-sitter", vm.DepthDisclosure, StringComparison.Ordinal);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
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
