using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace OpenBurnBar.UiAutomationHarness;

[SupportedOSPlatform("windows")]
internal static class WindowBitmapCapture
{
    public static void Capture(IntPtr hwnd, string pngPath)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(pngPath))!);
        if (!GetWindowRect(hwnd, out Rect rect))
        {
            throw new InvalidOperationException("GetWindowRect failed for the OpenBurnBar window.");
        }

        int width = Math.Max(1, rect.Right - rect.Left);
        int height = Math.Max(1, rect.Bottom - rect.Top);
        using var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(bitmap))
        {
            IntPtr hdc = graphics.GetHdc();
            try
            {
                if (!PrintWindow(hwnd, hdc, flags: 2))
                {
                    graphics.ReleaseHdc(hdc);
                    hdc = IntPtr.Zero;
                    graphics.CopyFromScreen(rect.Left, rect.Top, 0, 0, new Size(width, height), CopyPixelOperation.SourceCopy);
                }
            }
            finally
            {
                if (hdc != IntPtr.Zero)
                {
                    graphics.ReleaseHdc(hdc);
                }
            }
        }

        bitmap.Save(pngPath, ImageFormat.Png);
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct Rect
    {
        public readonly int Left;
        public readonly int Top;
        public readonly int Right;
        public readonly int Bottom;
    }
}
