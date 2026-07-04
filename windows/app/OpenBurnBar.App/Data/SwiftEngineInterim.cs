using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Data;

/// <summary>
/// Interim Swift Engine compute on the macOS authoring host: runs the B0-proven G2 parser
/// parity executable via <c>swift run</c>. This is NOT the Rust <c>burnbar-remote</c> UniFFI
/// binding (that crate is remote/relay transport only).
/// </summary>
/// <remarks>
/// <para>
/// Deferred follow-up: an in-process Swift Engine C-ABI / UniFFI export from
/// <c>OpenBurnBarCore</c> must be built and proven on Windows CI before the shell can call
/// parse/quota compute without shelling out.
/// </para>
/// <para>
/// After a successful parity run, populate <c>token_usage</c> via the storage write seam
/// (or the Mac indexer) and read aggregates through <see cref="OpenBurnBar.Storage.TokenUsageReadSeam"/>.
/// </para>
/// </remarks>
public static class SwiftEngineInterim
{
    /// <summary>
    /// Runs <c>OpenBurnBarG2ParserParity</c> under <paramref name="openBurnBarCorePackagePath"/>.
    /// Returns <c>true</c> when the process exits 0.
    /// </summary>
    public static async Task<bool> RunG2ParserParityAsync(
        string openBurnBarCorePackagePath,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(openBurnBarCorePackagePath);
        string fullPath = Path.GetFullPath(openBurnBarCorePackagePath);
        if (!Directory.Exists(fullPath))
        {
            return false;
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = "swift",
            ArgumentList =
            {
                "run",
                "--package-path",
                fullPath,
                "OpenBurnBarG2ParserParity",
            },
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        using var process = new Process { StartInfo = startInfo };
        if (!process.Start())
        {
            return false;
        }

        await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        return process.ExitCode == 0;
    }

    /// <summary>
    /// Resolves the repo's <c>OpenBurnBarCore</c> directory from an optional env override.
    /// </summary>
    public static string? ResolveOpenBurnBarCorePath()
    {
        string? env = Environment.GetEnvironmentVariable("OPENBURNBAR_CORE_PACKAGE_PATH");
        if (!string.IsNullOrWhiteSpace(env) && Directory.Exists(env))
        {
            return Path.GetFullPath(env);
        }

        string? cwd = Directory.GetCurrentDirectory();
        for (int i = 0; i < 8 && cwd is not null; i++)
        {
            string candidate = Path.Combine(cwd, "OpenBurnBarCore");
            if (Directory.Exists(candidate) && File.Exists(Path.Combine(candidate, "Package.swift")))
            {
                return candidate;
            }

            cwd = Directory.GetParent(cwd)?.FullName;
        }

        return null;
    }
}