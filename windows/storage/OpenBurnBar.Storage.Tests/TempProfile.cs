using System;
using System.IO;

namespace OpenBurnBar.Storage.Tests;

/// <summary>
/// A throwaway profile directory holding one provisioned encrypted database.
/// Deleted (best-effort) on dispose, so suites that call
/// <c>WindowsSqlCipherProvisioner.EnsureReady</c> leave nothing behind — including
/// the journal, key-provenance, and recovery-log sidecars it writes.
/// </summary>
internal sealed class TempProfile : IDisposable
{
    private readonly string _root;

    private TempProfile(string root, string databasePath)
    {
        _root = root;
        DatabasePath = databasePath;
    }

    internal string DatabasePath { get; }

    internal static TempProfile Create()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-storage-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        return new TempProfile(root, Path.Combine(root, "openburnbar.sqlite"));
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_root, recursive: true);
        }
        catch
        {
            // Best-effort cleanup.
        }
    }
}
