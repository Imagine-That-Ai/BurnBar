// Single source of truth for the Windows DLL-load hardening controls (Phase 5 · R19).
//
// The three hardening layers (runtime search-order, native link flags, managed PE flags) each
// have their required knobs listed HERE. The packaging .props files under windows/dist/props/
// must carry exactly these flags/properties, and the test suite asserts that — so the policy and
// the props can never silently drift. Nothing here is Windows-specific; it is plain data + the
// numeric constants the runtime layer uses.

using System.Collections.Generic;

namespace OpenBurnBar.Dist.Hardening;

/// <summary>Declarative description of the required DLL-load hardening controls.</summary>
public static class HardeningPolicy
{
    // ── Win32 LOAD_LIBRARY_SEARCH_* flags (winbase.h) ────────────────────────

    /// <summary>LOAD_LIBRARY_SEARCH_APPLICATION_DIR.</summary>
    public const int LoadLibrarySearchApplicationDir = 0x00000200;

    /// <summary>LOAD_LIBRARY_SEARCH_USER_DIRS.</summary>
    public const int LoadLibrarySearchUserDirs = 0x00000400;

    /// <summary>LOAD_LIBRARY_SEARCH_SYSTEM32.</summary>
    public const int LoadLibrarySearchSystem32 = 0x00000800;

    /// <summary>LOAD_LIBRARY_SEARCH_DEFAULT_DIRS — the safe composite the app applies at startup
    /// (application dir + user dirs + System32, and NOT the current working directory).</summary>
    public const int LoadLibrarySearchDefaultDirs = 0x00001000;

    /// <summary>The value the managed app passes to SetDefaultDllDirectories at startup.</summary>
    public const int RecommendedDefaultDllDirectories = LoadLibrarySearchDefaultDirs;

    /// <summary>The /DEPENDENTLOADFLAG value the in-tree native binaries link with
    /// (LOAD_LIBRARY_SEARCH_SYSTEM32 — statically imported DLLs resolve only from System32).</summary>
    public const int DependentLoadFlagSystem32 = LoadLibrarySearchSystem32;

    /// <summary>Hex string form of <see cref="DependentLoadFlagSystem32"/> as it appears in the
    /// native linker flag (/DEPENDENTLOADFLAG:0x0800).</summary>
    public const string DependentLoadFlagHex = "0x0800";

    // ── Required native (C++) linker flags ───────────────────────────────────

    /// <summary>Linker flags every in-tree native binary must carry. Asserted against
    /// OpenBurnBar.Windows.NativeHardening.props by the test suite.</summary>
    public static IReadOnlyList<string> RequiredNativeLinkerFlags { get; } = new[]
    {
        "/DEPENDENTLOADFLAG:0x0800", // dependent DLLs load only from System32
        "/guard:cf",                 // Control Flow Guard
        "/DYNAMICBASE",              // ASLR
        "/HIGHENTROPYVA",            // 64-bit high-entropy ASLR
        "/NXCOMPAT",                 // DEP
    };

    // ── Required managed (C#) PE-hardening MSBuild properties ─────────────────

    /// <summary>MSBuild properties (name → required value) the managed app packaging props must
    /// set so the shipped EXE gets full ASLR entropy + a deterministic, hardened PE. Asserted
    /// against OpenBurnBar.Windows.Hardening.props by the test suite.</summary>
    public static IReadOnlyDictionary<string, string> RequiredManagedPeProperties { get; } =
        new Dictionary<string, string>
        {
            ["HighEntropyVA"] = "true",
            ["Deterministic"] = "true",
        };
}
