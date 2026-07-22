// Shared fixtures for the distribution-core tests (Phase 5 · signed distribution).

using System;
using System.IO;
using OpenBurnBar.Dist.UpdateFeed;

namespace OpenBurnBar.Dist.Tests;

internal static class DistTestSupport
{
    /// <summary>A deterministic, well-formed 64-char lowercase hex sha256 for fixtures.</summary>
    public const string SampleSha256 = "26e7da660aecb7e1d8cd19ace3abfcac87ce476bb87b5cbecca438dbc085992c";

    /// <summary>Build a valid (unsigned) release entry for tests.</summary>
    public static UpdateFeedEntry SampleEntry(
        string version = "1.0.28",
        UpdatePlatform platform = UpdatePlatform.WinX64,
        UpdateChannel channel = UpdateChannel.Stable,
        int minOsBuild = 17763,
        bool critical = false) => new()
        {
            Version = version,
            Platform = platform,
            Channel = channel,
            Url = $"https://dl.openburnbar.dev/OpenBurnBar-{version}-{platform.ToToken()}.zip",
            SizeBytes = 12_345_678,
            Sha256 = SampleSha256,
            MinimumOsBuild = minOsBuild,
            Critical = critical,
            PublishedAtUtc = new DateTimeOffset(2026, 7, 4, 0, 0, 0, TimeSpan.Zero),
            ReleaseNotesUrl = $"https://openburnbar.dev/notes/{version}",
        };

    /// <summary>Generate a fresh Ed25519 key pair for a test.</summary>
    public static UpdateSigningKeyPair NewKeyPair() => new UpdateFeedSigner().GenerateKeyPair();

    /// <summary>Sign an entry with a key pair's private seed.</summary>
    public static UpdateFeedEntry Sign(UpdateFeedEntry entry, UpdateSigningKeyPair keyPair) =>
        new UpdateFeedSigner().Sign(entry, keyPair.PrivateKey);

    /// <summary>Build a pinned-key verifier from a key pair's public key.</summary>
    public static Ed25519UpdateFeedVerifier VerifierFor(UpdateSigningKeyPair keyPair) =>
        new(PinnedUpdateKey.FromBytes(keyPair.PublicKey));

    /// <summary>Locate the packaging-props directory (windows/dist/props) by walking up from the
    /// test binary directory until it is found. Robust to bin depth + worktree layout.</summary>
    public static string PropsDirectory()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "windows", "dist", "props");
            if (Directory.Exists(candidate) &&
                File.Exists(Path.Combine(candidate, "OpenBurnBar.Windows.NativeHardening.props")))
            {
                return candidate;
            }

            dir = dir.Parent;
        }

        throw new DirectoryNotFoundException("Could not locate windows/dist/props from the test binary directory.");
    }

    public static string RepositoryRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "windows", "OpenBurnBar.sln"))
                && File.Exists(Path.Combine(dir.FullName, "AGENTS.md")))
            {
                return dir.FullName;
            }

            dir = dir.Parent;
        }

        throw new DirectoryNotFoundException("Could not locate the repository root from the test binary directory.");
    }
}
