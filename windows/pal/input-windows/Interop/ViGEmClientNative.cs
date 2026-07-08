// P/Invoke surface for the ViGEmBus client library (ViGEmClient.dll) — the NON-BYPASSABLE
// virtual-HID route (R17). ViGEmBus is a signed kernel driver that exposes virtual HID
// devices; input submitted through it originates below user mode, so a same-integrity
// process cannot forge or intercept it the way it can a user-mode SendInput hook. That is
// exactly why non-bypassable computer-use actions route here instead of through SendInput.
//
// Declarations only — every method is `internal`. The whole assembly's P/Invokes are pinned
// to the OS "safe directories" search path (app dir + System32 + AddDllDirectory dirs;
// excludes the current directory + PATH) to mitigate DLL planting / side-loading (R19):
// ViGEmClient.dll ships in the application directory, user32.dll lives in System32, and both
// are found without a plantable search. This assembly targets net8.0-windows and RUNS only on
// a Windows host with ViGEmBus installed; on the macOS authoring host it Roslyn-compiles
// (EnableWindowsTargeting) but never loads the native DLL.

using System;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

// The whole assembly is Windows-only (ViGEmBus + user32). Marking it here satisfies the
// platform-compatibility analyzer (CA1416) while still compiling on the macOS authoring host.
[assembly: SupportedOSPlatform("windows")]

// Pin every P/Invoke in this assembly to the OS safe-directories search path (R19).
[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.SafeDirectories)]

namespace OpenBurnBar.Pal.Input.Windows.Interop;

/// <summary>ViGEm client/target handles are opaque native pointers.</summary>
internal static class ViGEmClientNative
{
    internal const string Dll = "ViGEmClient.dll";

    /// <summary>ViGEm result codes (VIGEM_ERROR). 0x20000000 == VIGEM_ERROR_NONE.</summary>
    internal enum VigemError : uint
    {
        None = 0x20000000,
        BusNotFound = 0xE0000001,
        NoFreeSlot = 0xE0000002,
        InvalidTarget = 0xE0000003,
        RemovalFailed = 0xE0000004,
        AlreadyConnected = 0xE0000005,
        TargetUninitialized = 0xE0000006,
        TargetNotPluggedIn = 0xE0000007,
        BusVersionMismatch = 0xE0000008,
        BusAccessFailed = 0xE0000009,
        CallbackAlreadyRegistered = 0xE0000010,
        CallbackNotFound = 0xE0000011,
        BusAlreadyConnected = 0xE0000012,
        BusInvalidHandle = 0xE0000013,
        XusbUserindexOutOfRange = 0xE0000014,
        InvalidParameter = 0xE0000015,
        NotSupported = 0xE0000016,
        WinapiError = 0xE0000017,
    }

    /// <summary>The XUSB (Xbox 360 pad) report submitted to a virtual target — a real,
    /// documented kernel virtual-HID report. Blittable; matches the native layout.</summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct XusbReport
    {
        internal ushort wButtons;
        internal byte bLeftTrigger;
        internal byte bRightTrigger;
        internal short sThumbLX;
        internal short sThumbLY;
        internal short sThumbRX;
        internal short sThumbRY;
    }

    [DllImport(Dll)]
    internal static extern IntPtr vigem_alloc();

    [DllImport(Dll)]
    internal static extern void vigem_free(IntPtr vigem);

    [DllImport(Dll)]
    internal static extern VigemError vigem_connect(IntPtr vigem);

    [DllImport(Dll)]
    internal static extern void vigem_disconnect(IntPtr vigem);

    [DllImport(Dll)]
    internal static extern IntPtr vigem_target_x360_alloc();

    [DllImport(Dll)]
    internal static extern void vigem_target_free(IntPtr target);

    [DllImport(Dll)]
    internal static extern VigemError vigem_target_add(IntPtr vigem, IntPtr target);

    [DllImport(Dll)]
    internal static extern VigemError vigem_target_remove(IntPtr vigem, IntPtr target);

    [DllImport(Dll)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool vigem_target_is_attached(IntPtr target);

    [DllImport(Dll)]
    internal static extern VigemError vigem_target_x360_update(IntPtr vigem, IntPtr target, XusbReport report);
}
