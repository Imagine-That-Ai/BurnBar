using System;
using System.IO;

namespace OpenBurnBar.Storage.Tests;

/// <summary>
/// Locates the committed DB byte-compat fixtures by walking up from the test
/// assembly to the repo root. The 900 KB encrypted fixture is NOT copied into the
/// test output (it lives once, under <c>AgentLensTests/Fixtures/DBByteCompat</c>,
/// shared with the macOS validator) — the test reads it in place, exactly as a
/// real committed-fixture test does.
/// </summary>
internal static class RepoFixtures
{
    private const string RelativeDir = "AgentLensTests/Fixtures/DBByteCompat";
    private const string PinnedFixtureFile = "openburnbar-db-compat-v64.sqlcipher";
    private const string VectorFile = "openburnbar-db-compat-vector.json";
    private const string ParamsFile = "openburnbar-db-compat-params-observed.json";

    /// <summary>
    /// The committed Mac SQLCipher fixture. Prefers the pinned name, but falls back
    /// to the single <c>*.sqlcipher</c> in the directory so a future schema-endpoint
    /// regeneration (which bumps the filename) does not silently break this proof.
    /// </summary>
    internal static string FixturePath
    {
        get
        {
            var dir = FixtureDirectory();
            var pinned = Path.Combine(dir, PinnedFixtureFile);
            if (File.Exists(pinned))
            {
                return pinned;
            }

            var candidates = Directory.GetFiles(dir, "*.sqlcipher");
            return candidates.Length switch
            {
                1 => candidates[0],
                0 => throw new FileNotFoundException($"No *.sqlcipher fixture found in '{dir}'."),
                _ => throw new InvalidOperationException(
                    $"Multiple *.sqlcipher fixtures in '{dir}' and the pinned '{PinnedFixtureFile}' is absent; "
                    + "cannot disambiguate the byte-compat fixture."),
            };
        }
    }

    internal static string VectorPath => Path.Combine(FixtureDirectory(), VectorFile);

    internal static string ParamsPath => Path.Combine(FixtureDirectory(), ParamsFile);

    private static string FixtureDirectory()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, RelativeDir.Replace('/', Path.DirectorySeparatorChar));
            if (File.Exists(Path.Combine(candidate, VectorFile)))
            {
                return candidate;
            }

            dir = dir.Parent;
        }

        throw new DirectoryNotFoundException(
            $"Could not locate '{RelativeDir}' by walking up from '{AppContext.BaseDirectory}'. "
            + "The committed DB byte-compat fixtures must be reachable from the repo root.");
    }
}
