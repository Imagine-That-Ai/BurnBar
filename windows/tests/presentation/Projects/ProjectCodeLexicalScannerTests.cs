using System.IO;
using System.Collections.Generic;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Projects;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Projects;

public sealed class ProjectCodeLexicalScannerTests
{
    [Fact]
    public void Scan_MissingRoot_ReturnsEmptyInventory()
    {
        ProjectCodeInventory inv = ProjectCodeLexicalScanner.Scan(Path.Combine(Path.GetTempPath(), "no-such-obb-root-xyz"));
        Assert.Equal(0, inv.FileCount);
        Assert.Empty(inv.ByExtension);
    }

    [Fact]
    public void Scan_TempCodeTree_CountsExtensions()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-lex-" + Path.GetRandomFileName());
        Directory.CreateDirectory(root);
        try
        {
            File.WriteAllText(Path.Combine(root, "a.cs"), "class A {}");
            File.WriteAllText(Path.Combine(root, "b.swift"), "struct B {}");
            File.WriteAllText(Path.Combine(root, "readme.md"), "# hi");

            ProjectCodeInventory inv = ProjectCodeLexicalScanner.Scan(root);
            Assert.Equal(2, inv.FileCount);
            Assert.Contains(inv.ByExtension, e => e.Extension == ".cs" && e.Count == 1);
            Assert.Contains(inv.ByExtension, e => e.Extension == ".swift" && e.Count == 1);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void SymbolIndex_RefreshesAndPersistsMetadataOnly()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-symbols-" + Path.GetRandomFileName());
        string indexPath = Path.Combine(root, "state", "symbols.json");
        Directory.CreateDirectory(root);
        try
        {
            File.WriteAllText(Path.Combine(root, "Feature.cs"),
                "namespace Demo;\npublic class Feature { public void Run() {} }");

            using (var index = new ProjectCodeSymbolIndex(root, indexPath))
            {
                ProjectCodeIndexSnapshot snapshot = index.Refresh();
                Assert.Contains(index.Symbols, symbol => symbol.Name == "Feature");
                Assert.Contains(index.Symbols, symbol => symbol.Name == "Run");
                Assert.True(File.Exists(indexPath));
                Assert.DoesNotContain("public class", File.ReadAllText(indexPath), System.StringComparison.Ordinal);
                Assert.Equal(snapshot.Symbols.Count, index.Symbols.Count);
            }

            using var reloaded = new ProjectCodeSymbolIndex(root, indexPath);
            Assert.True(reloaded.TryLoad());
            Assert.Contains(reloaded.Symbols, symbol => symbol.Name == "Feature");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task SymbolIndex_UsesTreeSitterClientWhenConfigured()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-parser-" + Path.GetRandomFileName());
        Directory.CreateDirectory(root);
        try
        {
            string sourcePath = Path.Combine(root, "Runner.swift");
            File.WriteAllText(sourcePath, "struct Runner {\n  func start() {}\n}\n");
            var parser = new DelegateProjectCodeStaticParserClient((request, _) =>
                Task.FromResult(new ProjectCodeParseResponse(
                    Ok: true,
                    HasParseError: false,
                    Symbols: new[]
                    {
                        new ProjectCodeParsedSymbol("Runner", "struct", 1, 3, "static_tree_sitter", true, "tree-sitter"),
                    },
                    Errors: new List<string>(),
                    Parser: "tree-sitter",
                    ShaMatch: true)));

            using var index = new ProjectCodeSymbolIndex(root);
            ProjectCodeIndexSnapshot snapshot = await index.RefreshWithParserAsync(parser);
            Assert.Equal("tree-sitter", snapshot.ParserMode);
            Assert.Contains(index.Symbols, symbol =>
                symbol.Name == "Runner" && symbol.ConfidenceTier == "static_tree_sitter");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void GitBlobSha_IsStableAndContentAddressed()
    {
        string first = JsonLinesProjectCodeStaticParserClient.ComputeGitBlobSha("hello\n");
        string same = JsonLinesProjectCodeStaticParserClient.ComputeGitBlobSha("hello\n");
        string different = JsonLinesProjectCodeStaticParserClient.ComputeGitBlobSha("hello\r\n");
        Assert.Equal(first, same);
        Assert.NotEqual(first, different);
        Assert.Equal(40, first.Length);
    }
}
