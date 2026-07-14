using System;
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
            Assert.Equal(3, inv.FileCount);
            Assert.Contains(inv.ByExtension, e => e.Extension == ".cs" && e.Count == 1);
            Assert.Contains(inv.ByExtension, e => e.Extension == ".swift" && e.Count == 1);
            Assert.Contains(inv.ByExtension, e => e.Extension == ".md" && e.Count == 1);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void Scan_DoesNotTraverseReparsePointDirectory()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-lex-root-" + Path.GetRandomFileName());
        string outside = Path.Combine(Path.GetTempPath(), "obb-lex-outside-" + Path.GetRandomFileName());
        string link = Path.Combine(root, "linked-outside");
        Directory.CreateDirectory(root);
        Directory.CreateDirectory(outside);
        try
        {
            File.WriteAllText(Path.Combine(root, "Inside.cs"), "class Inside {}");
            File.WriteAllText(Path.Combine(outside, "Outside.cs"), "class Outside {}");
            try
            {
                Directory.CreateSymbolicLink(link, outside);
            }
            catch (System.Exception error) when (
                error is IOException or UnauthorizedAccessException or System.PlatformNotSupportedException)
            {
                return;
            }

            ProjectCodeInventory inventory = ProjectCodeLexicalScanner.Scan(root);
            Assert.Equal(1, inventory.FileCount);

            using var index = new ProjectCodeSymbolIndex(root);
            ProjectCodeIndexSnapshot snapshot = index.Refresh();
            Assert.Contains(snapshot.Symbols, symbol => symbol.Name == "Inside");
            Assert.DoesNotContain(snapshot.Symbols, symbol => symbol.Name == "Outside");
        }
        finally
        {
            if (Directory.Exists(link))
            {
                Directory.Delete(link);
            }

            Directory.Delete(root, recursive: true);
            Directory.Delete(outside, recursive: true);
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
    public async Task SymbolIndex_FallsBackToLexicalWhenParserProcessIsUnavailable()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-parser-unavailable-" + Path.GetRandomFileName());
        Directory.CreateDirectory(root);
        try
        {
            File.WriteAllText(Path.Combine(root, "Runner.cs"), "class Runner {}");
            var parser = new DelegateProjectCodeStaticParserClient((_, _) =>
                Task.FromException<ProjectCodeParseResponse>(
                    new ProjectCodeParserException("project_code_parser_unavailable")));
            using var index = new ProjectCodeSymbolIndex(root);

            ProjectCodeIndexSnapshot snapshot = await index.RefreshWithParserAsync(parser);

            Assert.Equal("lexical", snapshot.ParserMode);
            Assert.Contains(snapshot.Symbols, symbol => symbol.Name == "Runner" && symbol.Parser == "lexical");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task SymbolIndex_DisposeWaitsForParserRefreshAndRejectsNewWork()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-parser-dispose-" + Path.GetRandomFileName());
        Directory.CreateDirectory(root);
        try
        {
            File.WriteAllText(Path.Combine(root, "Runner.cs"), "class Runner {}");
            var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var parser = new DelegateProjectCodeStaticParserClient(async (_, _) =>
            {
                entered.SetResult();
                await release.Task;
                return new ProjectCodeParseResponse(
                    Ok: true,
                    HasParseError: false,
                    Symbols: System.Array.Empty<ProjectCodeParsedSymbol>(),
                    Errors: System.Array.Empty<string>(),
                    Parser: "tree-sitter",
                    ShaMatch: true);
            });
            var index = new ProjectCodeSymbolIndex(root);

            Task<ProjectCodeIndexSnapshot> refresh = index.RefreshWithParserAsync(parser);
            await entered.Task;
            Task dispose = Task.Run(index.Dispose);
            await Task.Delay(50);
            Assert.False(dispose.IsCompleted);

            release.SetResult();
            await refresh;
            await dispose;

            Assert.Throws<System.ObjectDisposedException>(() => index.Refresh());
            Assert.Throws<System.ObjectDisposedException>(index.StartWatching);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void SymbolIndex_UsesLexicalFallbackWhenParserIsUnavailable()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-parser-fallback-" + Path.GetRandomFileName());
        Directory.CreateDirectory(root);
        try
        {
            File.WriteAllText(Path.Combine(root, "notes.md"), "class Notes\n");
            using var index = new ProjectCodeSymbolIndex(root);
            ProjectCodeIndexSnapshot snapshot = index.Refresh();

            Assert.Equal("lexical", snapshot.ParserMode);
            Assert.Contains(index.Symbols, symbol =>
                symbol.Name == "Notes" && symbol.Parser == "lexical");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void TreeSitterExtensions_CoverMacOSInventoryFormats()
    {
        foreach (string path in new[]
        {
            "main.c", "main.cpp", "main.h", "main.hpp", "Widget.m", "Widget.mm",
            "config.json", "README.md", "config.yml", "config.yaml",
        })
        {
            Assert.True(ProjectCodeLexicalScanner.SupportsTreeSitter(path), path);
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
