using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.B0Spike.Tests.Support;

/// <summary>
/// Invokes the in-process Swift Engine parity gate (<c>OpenBurnBarG2ParserParity</c>) as the
/// spike's parse step until UniFFI C# bindings land (B3).
/// </summary>
public static class SwiftEngineParseBridge
{
    /// <summary>Repo root (contains <c>OpenBurnBarCore/Package.swift</c>).</summary>
    public static string FindRepoRoot()
    {
        string? dir = AppContext.BaseDirectory;
        for (int i = 0; i < 12 && dir is not null; i++)
        {
            if (File.Exists(Path.Combine(dir, "OpenBurnBarCore", "Package.swift")))
            {
                return dir;
            }

            dir = Directory.GetParent(dir)?.FullName;
        }

        throw new InvalidOperationException(
            "Could not locate repo root (OpenBurnBarCore/Package.swift) from test output dir.");
    }

    /// <summary>
    /// Runs <c>swift run OpenBurnBarG2ParserParity</c> (real <c>ClaudeCodeParser</c> over committed fixtures).
    /// Returns exit code; throws on launch failure.
    /// </summary>
    public static async Task<(int ExitCode, string StdOut, string StdErr)> RunG2ParserParityAsync(
        CancellationToken cancellationToken = default)
    {
        string repoRoot = FindRepoRoot();
        string packagePath = Path.Combine(repoRoot, "OpenBurnBarCore");
        string cachePath = Path.Combine(packagePath, ".spm-cache-b0-spike");

        var psi = new ProcessStartInfo
        {
            FileName = "swift",
            WorkingDirectory = packagePath,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        psi.ArgumentList.Add("run");
        psi.ArgumentList.Add("--package-path");
        psi.ArgumentList.Add(packagePath);
        psi.ArgumentList.Add("--cache-path");
        psi.ArgumentList.Add(cachePath);
        psi.ArgumentList.Add("-c");
        psi.ArgumentList.Add("debug");
        psi.ArgumentList.Add("OpenBurnBarG2ParserParity");

        using var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        if (!process.Start())
        {
            throw new InvalidOperationException("Failed to start swift run OpenBurnBarG2ParserParity.");
        }

        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        process.OutputDataReceived += (_, e) => { if (e.Data is not null) stdout.AppendLine(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) stderr.AppendLine(e.Data); };
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        return (process.ExitCode, stdout.ToString(), stderr.ToString());
    }
}