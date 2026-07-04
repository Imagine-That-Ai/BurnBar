// P/Invoke declarations for winsparkle.dll (WinSparkle 0.8.0+).
//
// WinSparkle is the Windows analog of macOS Sparkle. Only the subset the host
// adapter needs is declared here. The `set_eddsa_public_key` entry point is the
// R19 pin: WinSparkle refuses to install an enclosure whose `sparkle:edSignature`
// does not verify against this key — the same pinned key the portable Core
// verifier holds, kept independent of the Authenticode certificate.
//
// These declarations are metadata and bind cross-platform, so the assembly
// COMPILES on the macOS authoring host (EnableWindowsTargeting). They only RUN
// on Windows with winsparkle.dll present, which every method guards via
// [SupportedOSPlatform("windows")].

using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace OpenBurnBar.Updater.Windows.Interop;

[SupportedOSPlatform("windows")]
internal static class WinSparkleNative
{
    private const string Dll = "winsparkle";

    /// <summary>Sets the appcast feed URL (UTF-8).</summary>
    [DllImport(Dll, EntryPoint = "win_sparkle_set_appcast_url", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void SetAppcastUrl([MarshalAs(UnmanagedType.LPUTF8Str)] string url);

    /// <summary>Sets the pinned EdDSA (Ed25519) public key, base64 (UTF-8).
    /// WinSparkle rejects any update whose signature does not verify against
    /// it — the native half of the R19 pin.</summary>
    [DllImport(Dll, EntryPoint = "win_sparkle_set_eddsa_public_key", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void SetEddsaPublicKey([MarshalAs(UnmanagedType.LPUTF8Str)] string base64PublicKey);

    /// <summary>Sets company / app name / current version (wide strings).</summary>
    [DllImport(Dll, EntryPoint = "win_sparkle_set_app_details", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void SetAppDetails(
        [MarshalAs(UnmanagedType.LPWStr)] string companyName,
        [MarshalAs(UnmanagedType.LPWStr)] string appName,
        [MarshalAs(UnmanagedType.LPWStr)] string appVersion);

    /// <summary>Enables or disables periodic automatic checks (1/0).</summary>
    [DllImport(Dll, EntryPoint = "win_sparkle_set_automatic_check_for_updates", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void SetAutomaticCheckForUpdates(int enabled);

    /// <summary>Initializes WinSparkle (call after configuration).</summary>
    [DllImport(Dll, EntryPoint = "win_sparkle_init", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void Init();

    /// <summary>Shuts WinSparkle down.</summary>
    [DllImport(Dll, EntryPoint = "win_sparkle_cleanup", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void Cleanup();

    /// <summary>User-visible update check (shows UI even when up to date).</summary>
    [DllImport(Dll, EntryPoint = "win_sparkle_check_update_with_ui", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void CheckUpdateWithUi();

    /// <summary>Silent background check (UI only when an update is found).</summary>
    [DllImport(Dll, EntryPoint = "win_sparkle_check_update_without_ui", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void CheckUpdateWithoutUi();
}
