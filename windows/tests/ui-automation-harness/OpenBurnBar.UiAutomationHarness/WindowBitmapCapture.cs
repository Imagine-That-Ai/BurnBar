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
        ShowWindow(hwnd, 9);
        if (!GetWindowRect(hwnd, out Rect initialRect))
        {
            throw new InvalidOperationException("GetWindowRect failed for the OpenBurnBar window.");
        }

        int visibleWidth = Math.Min(
            Math.Max(640, initialRect.Right - initialRect.Left),
            Math.Max(640, GetSystemMetrics(0) - 40));
        int visibleHeight = Math.Min(
            Math.Max(480, initialRect.Bottom - initialRect.Top),
            Math.Max(480, GetSystemMetrics(1) - 60));
        SetWindowPos(hwnd, new IntPtr(-1), 20, 20, visibleWidth, visibleHeight, SetWindowPosShowWindow);
        System.Threading.Thread.Sleep(250);
        if (!GetWindowRect(hwnd, out Rect rect))
        {
            throw new InvalidOperationException("GetWindowRect failed for the OpenBurnBar window.");
        }

        int width = Math.Max(1, rect.Right - rect.Left);
        int height = Math.Max(1, rect.Bottom - rect.Top);
        using var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        bool printWindowSucceeded;
        using (Graphics graphics = Graphics.FromImage(bitmap))
        {
            IntPtr hdc = graphics.GetHdc();
            try
            {
                printWindowSucceeded = PrintWindow(hwnd, hdc, flags: 2);
            }
            finally
            {
                if (hdc != IntPtr.Zero)
                {
                    graphics.ReleaseHdc(hdc);
                }
            }
        }

        // Composition-backed WinUI surfaces can report PrintWindow success while
        // returning an empty bitmap. Reject that evidence and capture the actual
        // interactive desktop instead.
        if (!printWindowSucceeded || IsNearUniform(bitmap) || !HasLowerBodyDetail(bitmap))
        {
            using Graphics graphics = Graphics.FromImage(bitmap);
            graphics.CopyFromScreen(
                rect.Left,
                rect.Top,
                0,
                0,
                new Size(width, height),
                CopyPixelOperation.SourceCopy);
        }

        if (IsNearUniform(bitmap) || !HasLowerBodyDetail(bitmap))
        {
            _ = DwmGetWindowAttribute(hwnd, 14, out int cloaked, sizeof(int));
            throw new InvalidOperationException(
                $"OpenBurnBar window capture remained blank or omitted the routed body after the interactive desktop fallback. " +
                $"rect={rect.Left},{rect.Top},{rect.Right},{rect.Bottom} visible={IsWindowVisible(hwnd)} cloaked={cloaked}");
        }

        bitmap.Save(pngPath, ImageFormat.Png);
        SetWindowPos(hwnd, new IntPtr(-2), 0, 0, 0, 0, SetWindowPosNoMove | SetWindowPosNoSize);
    }

    private static bool IsNearUniform(Bitmap bitmap)
    {
        int insetX = Math.Max(1, bitmap.Width / 10);
        int insetY = Math.Max(1, bitmap.Height / 10);
        Color first = bitmap.GetPixel(insetX, insetY);
        const int tolerance = 6;
        const int samplesPerAxis = 12;
        for (int yIndex = 0; yIndex < samplesPerAxis; yIndex++)
        {
            int y = insetY + (yIndex * Math.Max(0, bitmap.Height - (2 * insetY) - 1) / (samplesPerAxis - 1));
            for (int xIndex = 0; xIndex < samplesPerAxis; xIndex++)
            {
                int x = insetX + (xIndex * Math.Max(0, bitmap.Width - (2 * insetX) - 1) / (samplesPerAxis - 1));
                Color sample = bitmap.GetPixel(x, y);
                if (Math.Abs(sample.R - first.R) > tolerance
                    || Math.Abs(sample.G - first.G) > tolerance
                    || Math.Abs(sample.B - first.B) > tolerance)
                {
                    return false;
                }
            }
        }

        return true;
    }

    private static bool HasLowerBodyDetail(Bitmap bitmap)
    {
        int left = Math.Max(1, bitmap.Width / 20);
        int right = Math.Max(left, bitmap.Width - left - 1);
        int top = Math.Clamp(bitmap.Height / 4, 0, bitmap.Height - 1);
        int bottom = Math.Max(top, bitmap.Height - Math.Max(1, bitmap.Height / 12) - 1);
        double minLuma = double.MaxValue;
        double maxLuma = double.MinValue;
        const int horizontalSamples = 18;
        const int verticalSamples = 12;
        for (int yIndex = 0; yIndex < verticalSamples; yIndex++)
        {
            int y = top + (yIndex * Math.Max(0, bottom - top) / (verticalSamples - 1));
            for (int xIndex = 0; xIndex < horizontalSamples; xIndex++)
            {
                int x = left + (xIndex * Math.Max(0, right - left) / (horizontalSamples - 1));
                Color sample = bitmap.GetPixel(x, y);
                double luma = (0.2126 * sample.R) + (0.7152 * sample.G) + (0.0722 * sample.B);
                minLuma = Math.Min(minLuma, luma);
                maxLuma = Math.Max(maxLuma, luma);
            }
        }

        return maxLuma - minLuma >= 12;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hwnd, int command);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(
        IntPtr hwnd,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int valueSize);

    private const uint SetWindowPosNoSize = 0x0001;
    private const uint SetWindowPosNoMove = 0x0002;
    private const uint SetWindowPosShowWindow = 0x0040;

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct Rect
    {
        public readonly int Left;
        public readonly int Top;
        public readonly int Right;
        public readonly int Bottom;
    }
}
