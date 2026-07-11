using System.Text;
using OpenBurnBar.Updater.Core.Crypto;
using OpenBurnBar.Updater.Core.Feed;

namespace OpenBurnBar.Updater.Tests;

/// <summary>
/// Shared builders: mint a real Ed25519 key, sign a real artifact, and emit a
/// real feed in either encoding. Every test that needs a "valid" feed goes
/// through here, so "valid" always means "signed by the pinned key over these
/// exact bytes" — never a hand-faked string.
/// </summary>
internal static class FeedTestData
{
    internal static readonly byte[] Artifact =
        Encoding.UTF8.GetBytes("OpenBurnBar-Setup-1.4.2.msix :: deterministic test artifact payload");

    internal static UpdateReleaseDescriptor Descriptor(
        Ed25519UpdateKeyPair signer,
        byte[] artifact,
        string version = "1.4.2",
        string build = "1420",
        bool critical = false)
    {
        var unsigned = new UpdateReleaseDescriptor
        {
            Version = version,
            Build = build,
            BundleId = "com.openburnbar.app",
            DownloadUrl = "https://dl.openburnbar.app/windows/OpenBurnBar-Setup-" + version + ".msix",
            PackageName = "OpenBurnBar-Setup-" + version + ".msix",
            Length = artifact.LongLength,
            Sha256 = Sha256Digest.HexOf(artifact),
            EdSignatureBase64 = string.Empty,
            Critical = critical,
            MinimumSystemVersion = "10.0.19041",
            ReleaseNotesUrl = "https://dl.openburnbar.app/windows/release-metadata.json",
            AppcastUrl = "https://dl.openburnbar.app/windows/appcast-windows.xml",
            Commit = "0000000000000000000000000000000000000000",
        };

        return unsigned with
        {
            EdSignatureBase64 = signer.SignBase64(
                UpdateDescriptorCanonicalizer.CanonicalBytes(unsigned)),
        };
    }

    internal static string Write(FeedFormat format, UpdateReleaseDescriptor descriptor) =>
        format == FeedFormat.Appcast
            ? AppcastFeedWriter.Write(descriptor)
            : JsonFeedWriter.Write(descriptor);
}
