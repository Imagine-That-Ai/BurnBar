// Canonical signable-bytes contract (Phase 5 · signed distribution).

using System;
using System.Text;
using OpenBurnBar.Dist.UpdateFeed;
using Xunit;

namespace OpenBurnBar.Dist.Tests;

public sealed class UpdateDescriptorCanonicalizerTests
{
    [Fact]
    public void CanonicalBytes_AreStableForTheSameLogicalEntry()
    {
        var a = UpdateDescriptorCanonicalizer.CanonicalBytes(DistTestSupport.SampleEntry());
        var b = UpdateDescriptorCanonicalizer.CanonicalBytes(DistTestSupport.SampleEntry());
        Assert.Equal(a, b);
    }

    [Fact]
    public void CanonicalBytes_IgnoreTheSignatureField()
    {
        var unsigned = DistTestSupport.SampleEntry();
        var signed = unsigned.WithSignature("AAAA");
        Assert.Equal(
            UpdateDescriptorCanonicalizer.CanonicalBytes(unsigned),
            UpdateDescriptorCanonicalizer.CanonicalBytes(signed));
    }

    [Fact]
    public void CanonicalBytes_NormalizeEquivalentVersions()
    {
        // Hold every OTHER signed field fixed (incl. the url) and vary only the version string
        // representation, so this isolates version normalization (1.0.28 == 1.0.28.0).
        const string fixedUrl = "https://dl.openburnbar.dev/OpenBurnBar-win-x64.zip";
        const string fixedNotes = "https://openburnbar.dev/notes";
        var threePart = DistTestSupport.SampleEntry(version: "1.0.28") with { Url = fixedUrl, ReleaseNotesUrl = fixedNotes };
        var fourPart = DistTestSupport.SampleEntry(version: "1.0.28.0") with { Url = fixedUrl, ReleaseNotesUrl = fixedNotes };
        Assert.Equal(
            UpdateDescriptorCanonicalizer.CanonicalBytes(threePart),
            UpdateDescriptorCanonicalizer.CanonicalBytes(fourPart));
    }

    [Fact]
    public void CanonicalBytes_BeginWithTheVersionedMagicHeader()
    {
        var text = Encoding.UTF8.GetString(UpdateDescriptorCanonicalizer.CanonicalBytes(DistTestSupport.SampleEntry()));
        Assert.StartsWith("OBBWIN-UPDATE-DESCRIPTOR\nv1\n", text, StringComparison.Ordinal);
    }

    [Fact]
    public void CanonicalBytes_ChangeWhenAnyBoundFieldChanges()
    {
        var baseline = UpdateDescriptorCanonicalizer.CanonicalBytes(DistTestSupport.SampleEntry());
        var mutated = UpdateDescriptorCanonicalizer.CanonicalBytes(DistTestSupport.SampleEntry() with { Critical = true });
        Assert.NotEqual(baseline, mutated);
    }

    [Theory]
    [InlineData("https://evil\nhost/x")]
    [InlineData("https://host/x\rinjected")]
    public void CanonicalBytes_RejectCrLfInjectionInUrl(string url)
    {
        var entry = DistTestSupport.SampleEntry() with { Url = url };
        Assert.Throws<FormatException>(() => UpdateDescriptorCanonicalizer.CanonicalBytes(entry));
    }

    [Theory]
    [InlineData("short")]
    [InlineData("zz7da660aecb7e1d8cd19ace3abfcac87ce476bb87b5cbecca438dbc085992c00")]
    public void CanonicalBytes_RejectMalformedSha256(string sha256)
    {
        var entry = DistTestSupport.SampleEntry() with { Sha256 = sha256 };
        Assert.Throws<FormatException>(() => UpdateDescriptorCanonicalizer.CanonicalBytes(entry));
    }

    [Fact]
    public void CanonicalBytes_RejectNegativeSize()
    {
        var entry = DistTestSupport.SampleEntry() with { SizeBytes = -1 };
        Assert.Throws<FormatException>(() => UpdateDescriptorCanonicalizer.CanonicalBytes(entry));
    }

    [Fact]
    public void NormalizeSha256_LowercasesAndValidates()
    {
        var normalized = UpdateDescriptorCanonicalizer.NormalizeSha256(DistTestSupport.SampleSha256.ToUpperInvariant());
        Assert.Equal(DistTestSupport.SampleSha256, normalized);
    }
}
