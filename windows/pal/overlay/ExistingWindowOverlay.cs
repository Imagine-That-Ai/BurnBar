using System;
using System.Runtime.Versioning;
using OpenBurnBar.Pal.Overlay.Interop;

namespace OpenBurnBar.Pal.Overlay;

// MARK: - Overlay styling for an EXISTING window handle
//
// LayeredOverlayWindow creates + owns a raw Win32 window (the 2D atlas / GDI path).
// The 3D glTF path instead hosts a WebView2 inside a WinUI Window, which already
// owns its HWND — so this helper applies the SAME OverlayWindowStyle flag set to an
// existing handle (WindowNative.GetWindowHandle(window)) and toggles click-through
// on it. Keeping the P/Invoke here means the WinUI app never hand-rolls its own
// SetWindowLongPtr, and the flag math has one home (OverlayWindowStyle).
//
// Windows-only behaviour (every call is P/Invoke); compiles on macOS, runs on
// Windows.
[SupportedOSPlatform("windows")]
public static class ExistingWindowOverlay
{
    /// Apply the overlay extended-style set (layered + tool-window + topmost +
    /// no-activate, plus click-through per <paramref name="clickThrough"/>) to an
    /// existing window handle. Returns the resulting extended style.
    public static int ApplyOverlayStyle(IntPtr hwnd, bool clickThrough)
    {
        if (hwnd == IntPtr.Zero)
        {
            throw new ArgumentException("hwnd must be non-null.", nameof(hwnd));
        }
        var current = NativeMethods.GetWindowLong(hwnd, NativeConstants.GwlExStyle);
        var next = (current | OverlayWindowStyle.BaseExStyle);
        next = clickThrough
            ? OverlayWindowStyle.EnableClickThrough(next)
            : OverlayWindowStyle.DisableClickThrough(next);
        return NativeMethods.SetWindowLong(hwnd, NativeConstants.GwlExStyle, next);
    }

    /// Toggle click-through on an existing overlay handle, preserving the layered /
    /// tool-window / no-activate invariants.
    public static int SetClickThrough(IntPtr hwnd, bool clickThrough)
    {
        if (hwnd == IntPtr.Zero)
        {
            throw new ArgumentException("hwnd must be non-null.", nameof(hwnd));
        }
        var current = NativeMethods.GetWindowLong(hwnd, NativeConstants.GwlExStyle);
        var next = clickThrough
            ? OverlayWindowStyle.EnableClickThrough(current)
            : OverlayWindowStyle.DisableClickThrough(current);
        return NativeMethods.SetWindowLong(hwnd, NativeConstants.GwlExStyle, next);
    }

    /// Read whether an existing handle currently passes mouse input through.
    public static bool IsClickThrough(IntPtr hwnd) =>
        OverlayWindowStyle.IsClickThrough(NativeMethods.GetWindowLong(hwnd, NativeConstants.GwlExStyle));
}
