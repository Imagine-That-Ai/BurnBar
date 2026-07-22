using System;
using System.IO;
using System.Linq;
using OpenBurnBar.App.Configuration;
using Xunit;

namespace OpenBurnBar.App.Configuration.Tests;

public sealed class ProtectedFilePayloadStoreTests : IDisposable
{
    private readonly string _directory = Path.Combine(
        Path.GetTempPath(),
        "openburnbar-protected-payload-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void WriteReadDelete_RoundTripsOpaqueBytes()
    {
        ProtectedFilePayloadStore store = ProtectedFilePayloadStore.CreateForTests(_directory);
        byte[] payload = Enumerable.Range(0, 4096).Select(index => (byte)(index % 251)).ToArray();

        store.Write("run-one", payload);

        Assert.Equal(payload, store.Read("run-one"));
        Assert.DoesNotContain(payload, File.ReadAllBytes(store.PathFor("run-one")));
        store.Delete("run-one");
        Assert.Null(store.Read("run-one"));
    }

    [Fact]
    public void Read_TamperedEnvelopeFailsClosed()
    {
        ProtectedFilePayloadStore store = ProtectedFilePayloadStore.CreateForTests(_directory);
        store.Write("run-tampered", new byte[] { 1, 2, 3, 4 });
        File.WriteAllBytes(store.PathFor("run-tampered"), "not-an-envelope"u8.ToArray());

        SecretStoreException error = Assert.Throws<SecretStoreException>(() => store.Read("run-tampered"));

        Assert.Equal(SecretStoreFailureKind.CorruptProtectedPayload, error.Failure);
    }

    [Fact]
    public void Write_RejectsOversizedPayload()
    {
        ProtectedFilePayloadStore store = ProtectedFilePayloadStore.CreateForTests(_directory);

        SecretStoreException error = Assert.Throws<SecretStoreException>(() =>
            store.Write("run-large", new byte[ProtectedFilePayloadStore.MaximumPayloadBytes + 1]));

        Assert.Equal(SecretStoreFailureKind.WriteDenied, error.Failure);
        Assert.False(File.Exists(store.PathFor("run-large")));
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
