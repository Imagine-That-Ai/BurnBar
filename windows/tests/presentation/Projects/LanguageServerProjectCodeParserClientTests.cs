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
                timeout: TimeSpan.FromSeconds(5));
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
}
