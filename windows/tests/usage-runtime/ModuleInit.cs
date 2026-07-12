using System.Runtime.CompilerServices;

namespace OpenBurnBar.App.UsageRuntime.Tests;

internal static class ModuleInit
{
    [ModuleInitializer]
    public static void InitializeSqlCipher() => SQLitePCL.Batteries_V2.Init();
}
