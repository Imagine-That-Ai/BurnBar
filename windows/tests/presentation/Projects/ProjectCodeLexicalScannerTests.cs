using System.IO;
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
}
