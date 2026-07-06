using System.Runtime.CompilerServices;

namespace OpenBurnBar.App.TextExpansion.Tests;

internal static class ModuleInit
{
    /// <summary>
    /// Register the SQLCipher-enabled provider (bundle_e_sqlcipher) as the ambient
    /// SQLitePCL battery before any <c>SqliteConnection</c> is created, so
    /// <c>PRAGMA key</c> keys a real codec. Only the SQLCipher snippet-store round-trip
    /// touches SQLite; the pure-engine tests are unaffected. Mirrors
    /// OpenBurnBar.Storage.Tests/ModuleInit.
    /// </summary>
    [ModuleInitializer]
    public static void Init()
    {
        SQLitePCL.Batteries_V2.Init();
    }
}
