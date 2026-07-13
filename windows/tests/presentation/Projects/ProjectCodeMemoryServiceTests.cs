using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Projects;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Projects;

public sealed class ProjectCodeMemoryServiceTests
{
    [Fact]
    public async Task RefreshAndSearch_PersistMetadataOnlyIndex()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-code-memory-" + Path.GetRandomFileName());
        Directory.CreateDirectory(root);
        try
        {
            string sourcePath = Path.Combine(root, "Widget.cs");
            await File.WriteAllTextAsync(
                sourcePath,
                "public class Widget { public void Run() {} }\nconst string api_key = \"sk-live-abcdefghijklmnopqrstuvwxyz123456\";");
            var service = new ProjectCodeMemoryService(new ProjectCodeSymbolIndex(root));
            service.StartWatching();

            ProjectCodeIndexSnapshot snapshot = await service.RefreshAsync();
            ProjectCodeSearchHit hit = service.Search("Widget")[0];

            Assert.Equal("lexical", snapshot.ParserMode);
            Assert.Equal("Widget", hit.Symbol.Name);
            Assert.Equal(0, hit.Score);
            Assert.True(service.IsWatching);
            Assert.DoesNotContain("public class", File.ReadAllText(Path.Combine(root, ".openburnbar", "project-symbols.json")));

            ProjectCodeContextPack pack = service.BuildContextPack("Widget");
            Assert.Contains("<<<UNTRUSTED_SOURCE_BEGIN>>>", pack.Context, System.StringComparison.Ordinal);
            Assert.Contains("[REDACTED]", pack.Context, System.StringComparison.Ordinal);
            Assert.DoesNotContain("sk-live-abcdefghijklmnopqrstuvwxyz123456", pack.Context, System.StringComparison.Ordinal);
            Assert.True(pack.UntrustedContentWrapped);
            Assert.True(pack.WrappedCount >= 1);

            var restored = new ProjectCodeMemoryService(new ProjectCodeSymbolIndex(root));
            Assert.True(restored.TryLoad());
            Assert.Equal("Widget", Assert.Single(restored.FindSymbol("Widget")).Name);
            restored.Dispose();
            service.Dispose();
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    [Fact]
    public async Task Search_RejectsUnboundedQueriesAndLimits()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-code-memory-" + Path.GetRandomFileName());
        Directory.CreateDirectory(root);
        try
        {
            var service = new ProjectCodeMemoryService(new ProjectCodeSymbolIndex(root));
            await service.RefreshAsync();
            Assert.Throws<System.ArgumentException>(() => service.Search(string.Empty));
            Assert.Throws<System.ArgumentOutOfRangeException>(() => service.Search("x", 101));
            service.Dispose();
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    [Fact]
    public async Task ContextPack_EnforcesByteBudgetAndDoesNotPersistSource()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-code-memory-" + Path.GetRandomFileName());
        Directory.CreateDirectory(root);
        try
        {
            await File.WriteAllTextAsync(Path.Combine(root, "Alpha.cs"), "public class Alpha { }\n");
            var service = new ProjectCodeMemoryService(new ProjectCodeSymbolIndex(root));
            await service.RefreshAsync();

            ProjectCodeContextPack pack = service.BuildContextPack("Alpha", maxBytes: 32);
            Assert.True(pack.Truncated);
            Assert.True(System.Text.Encoding.UTF8.GetByteCount(pack.Context) <= 32);
            Assert.DoesNotContain("public class", File.ReadAllText(Path.Combine(root, ".openburnbar", "project-symbols.json")));
            service.Dispose();
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    [Fact]
    public async Task References_UsesBoundedRelativePathAndZeroBasedParserPosition()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-code-refs-" + Path.GetRandomFileName());
        Directory.CreateDirectory(root);
        try
        {
            string sourcePath = Path.Combine(root, "Runner.swift");
            await File.WriteAllTextAsync(sourcePath, "struct Runner { func start() {} }\n");
            var parser = new DelegateProjectCodeStaticParserClient((request, _) =>
            {
                Assert.Equal("Runner.swift", request.FilePath);
                Assert.Equal("references", request.Operation);
                Assert.Equal(new ProjectCodeParsePosition(0, 7), request.Position);
                return Task.FromResult(new ProjectCodeParseResponse(
                    Ok: true,
                    HasParseError: false,
                    Symbols: System.Array.Empty<ProjectCodeParsedSymbol>(),
                    Errors: System.Array.Empty<string>(),
                    Parser: "lsp",
                    ShaMatch: true,
                    References: new[]
                    {
                        new ProjectCodeParsedReference(
                            "Runner.swift", 1, 1, 7, 13, "exact_lsp"),
                    }));
            });

            using var service = new ProjectCodeMemoryService(
                new ProjectCodeSymbolIndex(root),
                parser);
            ProjectCodeReferencesResult result = await service.FindReferencesAsync(
                sourcePath,
                line: 1,
                character: 7);

            Assert.True(result.Ok);
            Assert.True(result.ShaMatch);
            Assert.Equal("Runner.swift", result.FilePath);
            Assert.Equal("exact_lsp", Assert.Single(result.References).ConfidenceTier);
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    [Fact]
    public async Task DurableStore_PersistsMetadataReferencesAndCheckpointWithoutSource()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-code-store-" + Path.GetRandomFileName());
        Directory.CreateDirectory(root);
        string databasePath = Path.Combine(root, "memory.sqlite");
        const string passphrase = "obb-project-code-test-key-2026";
        try
        {
            await File.WriteAllTextAsync(
                Path.Combine(root, "Widget.cs"),
                "public class Widget { public void Run() {} }\n");
            await File.WriteAllTextAsync(
                Path.Combine(root, "Caller.cs"),
                "public class Caller { public void Invoke() { Widget(); } }\n");

            using (var store = new ProjectCodeMemoryStore(databasePath, encryptionPassphrase: passphrase))
            using (var service = new ProjectCodeMemoryService(
                new ProjectCodeSymbolIndex(root, store: store)))
            {
                ProjectCodeIndexSnapshot snapshot = await service.RefreshAsync();
                Assert.True(service.HasDurableStore);
                Assert.Equal("lexical", snapshot.ParserMode);
                ProjectCodeMemoryStoreStats stats = Assert.IsType<ProjectCodeMemoryStoreStats>(service.DurableStoreStats);
                Assert.Equal(2, stats.ArtifactCount);
                Assert.True(stats.SymbolCount >= 4);
                Assert.True(stats.ReferenceCount >= 1);
                Assert.True(stats.CallEdgeCount >= 1);
                Assert.Equal(2, stats.ChunkCount);
                Assert.Equal(stats.ChunkCount, stats.EmbeddingCount);
                Assert.Equal(ProjectCodeMemoryStore.CodeEmbeddingDimensions, stats.EmbeddingDimensions);
                Assert.True(stats.SemanticAvailable);
                Assert.True(stats.StorageBytes > 0);
                ProjectCodeCallGraphResult graph = service.ReadCallGraph("Invoke");
                Assert.Contains(graph.Edges, edge => edge.Callee.Name == "Widget");
                ProjectCodeSemanticSearchResult semantic = service.ReadSemanticSearch("Widget");
                Assert.True(semantic.SemanticAvailable);
                Assert.NotEmpty(semantic.Hits);
                Assert.Contains(semantic.Hits, hit => hit.FilePath is "Widget.cs" or "Caller.cs");
            }

            string databaseText = Encoding.UTF8.GetString(await File.ReadAllBytesAsync(databasePath));
            Assert.DoesNotContain("public class Widget", databaseText, System.StringComparison.Ordinal);

            using var restoredStore = new ProjectCodeMemoryStore(databasePath, encryptionPassphrase: passphrase);
            using var restoredService = new ProjectCodeMemoryService(
                new ProjectCodeSymbolIndex(root, store: restoredStore));
            Assert.True(restoredService.TryLoad());
            Assert.Equal("Widget", Assert.Single(restoredService.FindSymbol("Widget")).Name);
            Assert.True(restoredService.DurableStoreStats?.ReferenceCount >= 1);
            Assert.True(restoredService.DurableStoreStats?.SemanticAvailable);
            Assert.NotEmpty(restoredService.ReadSemanticSearch("Widget").Hits);
            Assert.Contains(restoredService.ReadCallGraph("Invoke").Edges, edge => edge.Callee.Name == "Widget");
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    [Fact]
    public async Task DurableStore_ChunksLongFilesWithBoundedOverlap()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-code-chunking-" + Path.GetRandomFileName());
        Directory.CreateDirectory(root);
        string databasePath = Path.Combine(root, "memory.sqlite");
        try
        {
            string body = string.Join("\n", Enumerable.Repeat("alpha semantic code token", 220));
            await File.WriteAllTextAsync(Path.Combine(root, "Long.cs"), body);
            using var store = new ProjectCodeMemoryStore(databasePath, encryptionPassphrase: "obb-project-code-chunk-key-2026");
            using var service = new ProjectCodeMemoryService(new ProjectCodeSymbolIndex(root, store: store));

            await service.RefreshAsync();
            ProjectCodeMemoryStoreStats stats = Assert.IsType<ProjectCodeMemoryStoreStats>(service.DurableStoreStats);
            Assert.True(stats.ChunkCount >= 3);
            ProjectCodeSemanticSearchResult result = service.ReadSemanticSearch("alpha semantic");
            Assert.NotEmpty(result.Hits);
            Assert.All(result.Hits, hit =>
            {
                Assert.Equal("Long.cs", hit.FilePath);
                Assert.InRange(hit.EndOffset - hit.StartOffset, 1, ProjectCodeMemoryStore.CodeChunkMaxCharacters);
            });
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }
}
