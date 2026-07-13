using System.IO;
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
            await File.WriteAllTextAsync(sourcePath, "public class Widget { public void Run() {} }");
            var service = new ProjectCodeMemoryService(new ProjectCodeSymbolIndex(root));
            service.StartWatching();

            ProjectCodeIndexSnapshot snapshot = await service.RefreshAsync();
            ProjectCodeSearchHit hit = service.Search("Widget")[0];

            Assert.Equal("lexical", snapshot.ParserMode);
            Assert.Equal("Widget", hit.Symbol.Name);
            Assert.Equal(0, hit.Score);
            Assert.True(service.IsWatching);
            Assert.DoesNotContain("public class", File.ReadAllText(Path.Combine(root, ".openburnbar", "project-symbols.json")));

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
}
