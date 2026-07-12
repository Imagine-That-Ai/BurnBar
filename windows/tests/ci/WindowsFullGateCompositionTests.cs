using System;
using System.IO;
using OpenBurnBar.Windows.Ci;
using Xunit;

namespace OpenBurnBar.Windows.Ci.Tests;

public sealed class WindowsFullGateCompositionTests
{
    [Fact]
    public void Validate_RepoRoot_PassesForThisCheckout()
    {
        string root = FindRepoRoot();
        WindowsFullGateValidation result = WindowsFullGateComposition.Validate(root);
        Assert.True(result.IsValid, result.Error);
        Assert.NotNull(result.WorkflowPath);
        Assert.True(File.Exists(result.WorkflowPath));
    }

    [Fact]
    public void Validate_MissingRoot_FailsClosed()
    {
        WindowsFullGateValidation result = WindowsFullGateComposition.Validate(
            Path.Combine(Path.GetTempPath(), "obb-no-such-root-" + Path.GetRandomFileName()));
        Assert.False(result.IsValid);
        Assert.Equal("repo_root_missing", result.Error);
    }

    private static string FindRepoRoot()
    {
        string dir = Directory.GetCurrentDirectory();
        while (!string.IsNullOrEmpty(dir))
        {
            if (File.Exists(Path.Combine(dir, ".github", "workflows", "pr-windows-full.yml")))
            {
                return dir;
            }

            string? parent = Directory.GetParent(dir)?.FullName;
            if (parent is null || parent == dir)
            {
                break;
            }

            dir = parent;
        }

        // Fallback: walk up from test assembly base
        dir = AppContext.BaseDirectory;
        for (int i = 0; i < 12; i++)
        {
            if (File.Exists(Path.Combine(dir, ".github", "workflows", "pr-windows-full.yml")))
            {
                return dir;
            }

            dir = Path.GetFullPath(Path.Combine(dir, ".."));
        }

        throw new DirectoryNotFoundException("Could not locate repo root with pr-windows-full.yml");
    }
}
