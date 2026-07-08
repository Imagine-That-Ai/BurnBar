using System.Runtime.CompilerServices;

namespace OpenBurnBar.Storage.Tests;

internal static class ModuleInit
{
    /// <summary>
    /// Register the SQLCipher-enabled provider (bundle_e_sqlcipher) as the ambient
    /// SQLitePCL battery before any <c>SqliteConnection</c> is created. With
    /// Microsoft.Data.Sqlite.Core (no bundled vanilla SQLite) this is required so
    /// <c>PRAGMA key</c> keys a real codec instead of hitting a stock SQLite build.
    /// </summary>
    [ModuleInitializer]
    public static void Init()
    {
        SQLitePCL.Batteries_V2.Init();
    }
}
