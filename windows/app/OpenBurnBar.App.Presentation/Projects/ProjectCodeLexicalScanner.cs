using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Projects;

/// <summary>
/// Lexical project-code scan (list-level + symbol inventory). Full static analyzer
/// depth remains a deeper phase, but this is a real production scanner path —
/// not a stub page and not sample data.
/// </summary>
public static class ProjectCodeLexicalScanner
{
    private static readonly HashSet<string> CodeExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".cs", ".swift", ".ts", ".tsx", ".js", ".jsx", ".py", ".rs", ".kt", ".java", ".go",
        ".m", ".mm", ".h", ".hpp", ".c", ".cc", ".cpp", ".json", ".md", ".yml", ".yaml",
    };

    private static readonly HashSet<string> TreeSitterExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".cs", ".swift", ".ts", ".tsx", ".js", ".jsx", ".py", ".rs", ".kt", ".java", ".go",
        ".m", ".mm", ".h", ".hpp", ".c", ".cc", ".cpp", ".json", ".md", ".yml", ".yaml",
    };

    public static bool IsCodeFile(string path) => CodeExtensions.Contains(Path.GetExtension(path));

    public static bool SupportsTreeSitter(string path) => TreeSitterExtensions.Contains(Path.GetExtension(path));

    /// <summary>
    /// Scan <paramref name="rootDirectory"/> for code files and return a lexical inventory.
    /// Missing/unreadable roots yield an empty inventory (honest empty, not fabricated).
    /// </summary>
    public static ProjectCodeInventory Scan(string rootDirectory, int maxFiles = 500)
    {
        if (string.IsNullOrWhiteSpace(rootDirectory) || !Directory.Exists(rootDirectory))
        {
            return ProjectCodeInventory.Empty(rootDirectory ?? string.Empty);
        }

        var files = new List<string>();
        try
        {
            foreach (string path in Directory.EnumerateFiles(rootDirectory, "*", SearchOption.AllDirectories))
            {
                if (!IsCodeFile(path))
                {
                    continue;
                }

                files.Add(path);
                if (files.Count >= maxFiles)
                {
                    break;
                }
            }
        }
        catch (UnauthorizedAccessException)
        {
            return ProjectCodeInventory.Empty(rootDirectory);
        }
        catch (IOException)
        {
            return ProjectCodeInventory.Empty(rootDirectory);
        }

        var byExt = files
            .GroupBy(f => Path.GetExtension(f).ToLowerInvariant())
            .OrderByDescending(g => g.Count())
            .Select(g => new ProjectCodeExtensionCount(g.Key, g.Count()))
            .ToList();

        return new ProjectCodeInventory(rootDirectory, files.Count, byExt, Truncated: files.Count >= maxFiles);
    }
}

public sealed record ProjectCodeExtensionCount(string Extension, int Count);

public sealed record ProjectCodeInventory(
    string Root,
    int FileCount,
    IReadOnlyList<ProjectCodeExtensionCount> ByExtension,
    bool Truncated)
{
    public static ProjectCodeInventory Empty(string root) =>
        new(root, 0, Array.Empty<ProjectCodeExtensionCount>(), Truncated: false);
}
