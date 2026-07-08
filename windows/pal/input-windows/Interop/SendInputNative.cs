// P/Invoke surface for Win32 SendInput (user32) — the ADVISORY route (R17).
//
// SendInput synthesizes input at the top of the user-mode input stack. Any same-integrity
// process can call it directly, so a capability-token gate in front of it is only advisory
// (R17). Only advisory, non-committing actions (pointer move, scroll) ride this route; every
// input-COMMITTING action routes through ViGEmBus instead.
//
// Declarations only; pinned to the System32 search path (user32 is a System32 component,
// mitigates DLL planting, R19). net8.0-windows; RUNS only on Windows.

using System;
using System.Runtime.InteropServices;

namespace OpenBurnBar.Pal.Input.Windows.Interop;

internal static class SendInputNative
{
    internal const uint InputMouse = 0;

    // MOUSEINPUT.dwFlags
    internal const uint MouseeventfMove = 0x0001;
    internal const uint MouseeventfWheel = 0x0800;
    internal const uint MouseeventfHwheel = 0x01000;
    internal const uint MouseeventfAbsolute = 0x8000;
    internal const uint MouseeventfVirtualdesk = 0x4000;

    [StructLayout(LayoutKind.Sequential)]
    internal struct MouseInput
    {
        internal int dx;
        internal int dy;
        internal uint mouseData;
        internal uint dwFlags;
        internal uint time;
        internal IntPtr dwExtraInfo;
    }

    // INPUT is a tagged union; the input path only uses the mouse arm, so the struct carries
    // the type discriminator + a MOUSEINPUT payload. (Keyboard/hardware arms are unused here
    // because keystrokes are input-committing and route through ViGEm, not SendInput.)
    [StructLayout(LayoutKind.Sequential)]
    internal struct Input
    {
        internal uint type;
        internal MouseInput mi;
    }

    // Pinned to safe directories at the assembly level (ViGEmClientNative.cs) — user32 lives
    // in System32, so it resolves without a plantable search (R19).
    [DllImport("user32.dll", SetLastError = true)]
    internal static extern uint SendInput(uint nInputs, [In] Input[] pInputs, int cbSize);
}
