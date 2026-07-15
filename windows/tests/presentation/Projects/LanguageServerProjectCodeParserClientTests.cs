using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Projects;
using Xunit;
using FakeLanguageServerMarker = OpenBurnBar.App.Presentation.Tests.FakeLanguageServer.FakeLanguageServerMarker;

namespace OpenBurnBar.App.Presentation.Tests.Projects;

public sealed class LanguageServerProjectCodeParserClientTests
{
    [Fact]
    public async Task JsonRpcServerProvidesSymbolsAndReferencesWithIntegrityEvidence()
    {
        string root = Directory.CreateTempSubdirectory("openburnbar-lsp-").FullName;
        try
        {
            string filePath = Path.Combine(root, "Runner.cs");
            string source = "class ExactTarget {}\n\nvar value = ExactTarget();\n";
            await File.WriteAllTextAsync(filePath, source);
            var client = new LanguageServerProjectCodeParserClient(
                new Dictionary<string, IReadOnlyList<string>>
                {
                    ["cs"] = new[] { "dotnet", typeof(FakeLanguageServerMarker).Assembly.Location },
                },
                timeout: TimeSpan.FromSeconds(30));
            string blobSha = JsonLinesProjectCodeStaticParserClient.ComputeGitBlobSha(source);

            ProjectCodeParseResponse symbols = await client.ParseAsync(new ProjectCodeParseRequest(
                "symbols-1",
                "Runner.cs",
                "cs",
                blobSha,
                source,
                root,
                Operation: "symbols"));
            ProjectCodeParsedSymbol symbol = Assert.Single(symbols.Symbols);
            Assert.Equal("ExactTarget", symbol.Name);
            Assert.Equal("function", symbol.Kind);
            Assert.Equal("exact_lsp", symbol.ConfidenceTier);
            Assert.True(symbol.ShaMatch);
            Assert.Equal("lsp", symbols.Parser);

            ProjectCodeParseResponse references = await client.ParseAsync(new ProjectCodeParseRequest(
                "references-1",
                "Runner.cs",
                "cs",
                blobSha,
                source,
                root,
                Operation: "references",
                Position: new ProjectCodeParsePosition(0, 6)));
            Assert.Equal(2, references.References!.Count);
            Assert.All(references.References, item => Assert.Equal("exact_lsp", item.ConfidenceTier));
            Assert.Equal("Runner.cs", references.References[1].FilePath);
            Assert.Equal(3, references.References[1].StartLine);
            Assert.True(references.ShaMatch);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task MissingLanguageCommandAndEscapingPathFailClosed()
    {
        string root = Directory.CreateTempSubdirectory("openburnbar-lsp-").FullName;
        try
        {
            var client = new LanguageServerProjectCodeParserClient(
                new Dictionary<string, IReadOnlyList<string>> { ["cs"] = new[] { "dotnet", "missing.dll" } });
            var missingLanguage = await Assert.ThrowsAsync<ProjectCodeParserException>(() => client.ParseAsync(
                new ProjectCodeParseRequest("missing", "Runner.cs", "python", "sha", "class X {}", root)));
            Assert.Equal("lsp_unavailable", missingLanguage.Message);

            var traversal = await Assert.ThrowsAsync<ArgumentException>(() => client.ParseAsync(
                new ProjectCodeParseRequest("traversal", "../outside.cs", "cs", "sha", "class X {}", root)));
            Assert.Contains("inside the project root", traversal.Message);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task LspFailureFallsBackToTreeSitterParser()
    {
        var fallback = new DelegateProjectCodeStaticParserClient((request, _) => Task.FromResult(
            new ProjectCodeParseResponse(
                true,
                false,
                new[] { new ProjectCodeParsedSymbol("Fallback", "class", 1, 1, "static_tree_sitter", true, "tree-sitter") },
                Array.Empty<string>(),
                "tree-sitter",
                true)));
        var primary = new DelegateProjectCodeStaticParserClient((_, _) =>
            throw new ProjectCodeParserException("lsp_timeout"));
        var client = new FallbackProjectCodeStaticParserClient(primary, fallback);

        ProjectCodeParseResponse response = await client.ParseAsync(
            new ProjectCodeParseRequest("fallback", "Runner.cs", "cs", "sha", "class Runner {}", "/tmp"));

        Assert.Equal("tree-sitter", response.Parser);
        Assert.Equal("Fallback", Assert.Single(response.Symbols).Name);
    }

    [Fact]
    public void TreeSitterWireCoordinatesRemainOneBased()
    {
        var wire = new JsonLinesProjectCodeStaticParserClient.ProjectCodeParserWireResponse(
            true,
            false,
            new List<JsonLinesProjectCodeStaticParserClient.ProjectCodeParserWireSymbol>
            {
                new(
                    "ExactTarget",
                    "class",
                    7,
                    9,
                    "static_tree_sitter",
                    new JsonLinesProjectCodeStaticParserClient.ProjectCodeParserWireEvidence("tree-sitter", true)),
            },
            new List<string>(),
            "c_sharp",
            "sha",
            true,
            null);

        ProjectCodeParsedSymbol symbol = Assert.Single(wire.ToResponse().Symbols);
        Assert.Equal(7, symbol.StartLine);
        Assert.Equal(9, symbol.EndLine);
    }
}
