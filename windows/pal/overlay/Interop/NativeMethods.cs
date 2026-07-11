// Win32 P/Invoke surface for the layered click-through pet overlay window.
// Declarations only; live execution is on a Windows dev host / CI.
//
// Every method is `internal` (CA1401) and pinned to the System32 search path
// (mitigates DLL planting, R19) so nothing here is a visible API or a side-load
// vector. LayeredOverlayWindow calls these.

using System;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

// The Win32 P/Invoke surface + the window/GDI hosts are Windows-only, but the
// PORTABLE half of this assembly (OverlayWindowStyle flag math + PerPixelHitTest)
// is cross-platform and is unit-tested on macOS. So the windows gate is applied at
// the TYPE level (this class + LayeredOverlayWindow + ExistingWindowOverlay) rather
// than assembly-wide — otherwise the pure classes would inherit the gate and the
// all-platform test project could not call them (mirrors how windows/pal/ipc keeps
// its portable half in a separate un-gated assembly).

// Pin every P/Invoke in this assembly to the System32 search path (R19). This is
// not a platform gate, so it stays assembly-level.
[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

namespace OpenBurnBar.Pal.Overlay.Interop;

[SupportedOSPlatform("windows")]
internal static class NativeMethods
{
    // ── Window class + lifecycle (user32) ────────────────────────────────────────
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern ushort RegisterClassExW(ref WNDCLASSEXW lpwcx);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UnregisterClassW(string lpClassName, IntPtr hInstance);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern IntPtr CreateWindowExW(
        int dwExStyle,
        string lpClassName,
        string lpWindowName,
        uint dwStyle,
        int x,
        int y,
        int nWidth,
        int nHeight,
        IntPtr hWndParent,
        IntPtr hMenu,
        IntPtr hInstance,
        IntPtr lpParam);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    internal static extern IntPtr DefWindowProcW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetWindowPos(
        IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint uFlags);

    // ── Extended-style get/set (user32) ──────────────────────────────────────────
    // 64-bit uses the *Ptr variants; a wrapper below picks the 32-bit fallback.
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    internal static extern IntPtr GetWindowLongPtrW(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    internal static extern IntPtr SetWindowLongPtrW(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    internal static extern int GetWindowLongW(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    internal static extern int SetWindowLongW(IntPtr hWnd, int nIndex, int dwNewLong);

    /// Read an extended/base style, using the pointer-width-correct entry point.
    internal static int GetWindowLong(IntPtr hWnd, int nIndex) =>
        IntPtr.Size == 8 ? (int)GetWindowLongPtrW(hWnd, nIndex) : GetWindowLongW(hWnd, nIndex);

    /// Write an extended/base style, using the pointer-width-correct entry point.
    internal static int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong) =>
        IntPtr.Size == 8
            ? (int)SetWindowLongPtrW(hWnd, nIndex, new IntPtr(dwNewLong))
            : SetWindowLongW(hWnd, nIndex, dwNewLong);

    // ── Layered-window per-pixel alpha upload (user32) ────────────────────────────
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UpdateLayeredWindow(
        IntPtr hWnd,
        IntPtr hdcDst,
        ref POINT pptDst,
        ref SIZE psize,
        IntPtr hdcSrc,
        ref POINT pptSrc,
        uint crKey,
        ref BLENDFUNCTION pblend,
        uint dwFlags);

    // ── Device contexts (user32 + gdi32) ──────────────────────────────────────────
    [DllImport("user32.dll")]
    internal static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    internal static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll", SetLastError = true)]
    internal static extern IntPtr CreateCompatibleDC(IntPtr hdc);

    [DllImport("gdi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DeleteDC(IntPtr hdc);

    [DllImport("gdi32.dll", SetLastError = true)]
    internal static extern IntPtr SelectObject(IntPtr hdc, IntPtr hgdiobj);

    [DllImport("gdi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DeleteObject(IntPtr hObject);

    [DllImport("gdi32.dll", SetLastError = true)]
    internal static extern IntPtr CreateDIBSection(
        IntPtr hdc,
        ref BITMAPINFO pbmi,
        uint usage,
        out IntPtr ppvBits,
        IntPtr hSection,
        uint offset);

    // ── Module handle (kernel32) ──────────────────────────────────────────────────
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern IntPtr GetModuleHandleW(string? lpModuleName);
}

// The delegate the window class stores as its WndProc. Marshalled as a native
// function pointer via Marshal.GetFunctionPointerForDelegate.
[UnmanagedFunctionPointer(CallingConvention.Winapi)]
internal delegate IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
