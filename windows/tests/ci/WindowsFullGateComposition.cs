using System;
using System.Collections.Generic;
using System.IO;

namespace OpenBurnBar.Windows.Ci;

/// <summary>
/// Production composition descriptor for the Windows full CI gate
/// (<c>.github/workflows/pr-windows-full.yml</c>). Used by unit tests and the
/// shell verifier so the gate is a first-class product artifact, not only a
/// workflow file outside <c>windows/</c>.
/// </summary>
public static class WindowsFullGateComposition
{
    public const string WorkflowRelativePath = ".github/workflows/pr-windows-full.yml";

    public const string DisplayName = "PR Windows Full Suite";

    public static IReadOnlyList<string> RequiredWorkflowTokens { get; } = new[]
    {
        "PR Windows Full Suite",
        "windows-latest",
        "windows-11-arm",
        "dotnet test",
        "windows/",
    };

    /// <summary>
    /// Validate the workflow file at <paramref name="repoRoot"/> contains the
    /// dual-arch full-suite composition. Returns fail-closed reasons when invalid.
    /// </summary>
    public static WindowsFullGateValidation Validate(string repoRoot)
    {
        if (string.IsNullOrWhiteSpace(repoRoot) || !Directory.Exists(repoRoot))
        {
            return WindowsFullGateValidation.Fail("repo_root_missing");
        }

        string path = Path.Combine(repoRoot, WorkflowRelativePath.Replace('/', Path.DirectorySeparatorChar));
        if (!File.Exists(path))
        {
            return WindowsFullGateValidation.Fail("workflow_missing");
        }

        string text = File.ReadAllText(path);
        var missing = new List<string>();
        foreach (string token in RequiredWorkflowTokens)
        {
            if (!text.Contains(token, StringComparison.Ordinal))
            {
                missing.Add(token);
            }
        }

        if (missing.Count > 0)
        {
            return WindowsFullGateValidation.Fail("missing_tokens:" + string.Join(",", missing));
        }

        return WindowsFullGateValidation.Ok(path);
    }
}

public sealed record WindowsFullGateValidation(bool IsValid, string? WorkflowPath, string? Error)
{
    public static WindowsFullGateValidation Ok(string path) => new(true, path, null);

    public static WindowsFullGateValidation Fail(string error) => new(false, null, error);
}
