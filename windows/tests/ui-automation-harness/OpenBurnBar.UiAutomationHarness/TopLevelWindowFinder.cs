using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace OpenBurnBar.UiAutomationHarness;

[SupportedOSPlatform("windows")]
internal static class TopLevelWindowFinder
{
    public static IntPtr FindLargestVisibleWindow(int processId)
    {
        var candidates = new List<(IntPtr Handle, long Area)>();
        EnumWindowsProc callback = (hwnd, parameter) =>
        {
            _ = parameter;
            _ = GetWindowThreadProcessId(hwnd, out uint ownerProcessId);
            if (ownerProcessId != (uint)processId || !IsWindowVisible(hwnd) || GetWindow(hwnd, GetWindowOwner) != IntPtr.Zero)
            {
                return true;
            }

            if (DwmGetWindowAttribute(hwnd, DwmWindowAttributeCloaked, out int cloaked, sizeof(int)) == 0 && cloaked != 0)
            {
                return true;
            }

            if (GetWindowRect(hwnd, out Rect rect))
            {
                long width = Math.Max(0, rect.Right - rect.Left);
                long height = Math.Max(0, rect.Bottom - rect.Top);
                if (width > 0 && height > 0)
                {
                    candidates.Add((hwnd, width * height));
                }
            }

            return true;
        };

        if (!EnumWindows(callback, IntPtr.Zero))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "EnumWindows failed while locating the OpenBurnBar top-level window.");
        }

        IntPtr largest = IntPtr.Zero;
        long largestArea = 0;
        foreach ((IntPtr handle, long area) in candidates)
        {
            if (area > largestArea)
            {
                largest = handle;
                largestArea = area;
            }
        }

        return largest;
    }

    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr parameter);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hwnd, uint command);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int valueSize);

    private const uint GetWindowOwner = 4;
    private const int DwmWindowAttributeCloaked = 14;

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct Rect
    {
        public readonly int Left;
        public readonly int Top;
        public readonly int Right;
        public readonly int Bottom;
    }
}
