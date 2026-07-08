using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using OpenBurnBar.Pal.Overlay.Interop;

namespace OpenBurnBar.Pal.Overlay;

// MARK: - Layered click-through overlay window (Windows host)
//
// The Win32 host for the desktop pet's overlay, peer of
// `AgentLens/PetCompanion/Shell/PetPanel.swift` (a borderless, non-activating,
// per-pixel-shaped NSPanel). It applies the portable OverlayWindowStyle flag set
// via CreateWindowEx, uploads per-pixel-alpha frames with UpdateLayeredWindow, and
// answers WM_NCHITTEST through the portable PerPixelHitTest so near-transparent
// fringe pixels pass clicks through.
//
// This is Windows-only behaviour: every OS call is hand-written P/Invoke through
// Interop/NativeMethods (marked [SupportedOSPlatform("windows")]), so it COMPILES
// on the macOS authoring host as extra evidence but only RUNS on a Windows dev host
// / CI (windows/pal/overlay/README.md). The flag math + hit-test it drives are
// unit-tested on macOS today.
[SupportedOSPlatform("windows")]
public sealed class LayeredOverlayWindow : IDisposable
{
    private readonly string _className;
    private readonly WndProc _wndProc; // held to keep the native fn-pointer alive
    private readonly IntPtr _hInstance;

    private IntPtr _hwnd;
    private bool _classRegistered;
    private bool _disposed;

    // Last uploaded frame kept for per-pixel WM_NCHITTEST.
    private byte[] _alpha = Array.Empty<byte>();
    private int _frameWidth;
    private int _frameHeight;
    private int _frameStride;
    private int _originX;
    private int _originY;

    /// Alpha threshold below which a pixel passes clicks through (see
    /// <see cref="PerPixelHitTest"/>).
    public byte AlphaThreshold { get; set; } = PerPixelHitTest.DefaultAlphaThreshold;

    public LayeredOverlayWindow(string className = "OpenBurnBarPetOverlay", string title = "OpenBurnBar Pet")
    {
        _className = className ?? throw new ArgumentNullException(nameof(className));
        _wndProc = WindowProc;
        _hInstance = NativeMethods.GetModuleHandleW(null);
        RegisterClass();
        CreateWindow(title ?? string.Empty);
    }

    /// The native window handle (HWND).
    public IntPtr Handle => _hwnd;

    /// Whether the overlay currently passes mouse input straight through.
    public bool IsClickThrough => OverlayWindowStyle.IsClickThrough(CurrentExStyle());

    /// Toggle click-through. When false the overlay receives mouse input (drag the
    /// pet / click its bubble); when true input falls to the windows below. The
    /// no-activate + tool-window + layered invariants are preserved across the
    /// toggle.
    public void SetClickThrough(bool clickThrough)
    {
        EnsureAlive();
        var current = CurrentExStyle();
        var next = clickThrough
            ? OverlayWindowStyle.EnableClickThrough(current)
            : OverlayWindowStyle.DisableClickThrough(current);
        _ = NativeMethods.SetWindowLong(_hwnd, NativeConstants.GwlExStyle, next);
    }

    /// Upload one per-pixel-alpha frame and move the window to
    /// (<paramref name="screenX"/>, <paramref name="screenY"/>).
    /// <paramref name="bgraPremultiplied"/> is a 32-bpp top-down BGRA buffer with
    /// premultiplied alpha (the format UpdateLayeredWindow/AC_SRC_ALPHA expects).
    public void UpdateSurface(ReadOnlySpan<byte> bgraPremultiplied, int width, int height, int screenX, int screenY)
    {
        EnsureAlive();
        if (width <= 0 || height <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(width), "width/height must be positive.");
        }
        var stride = width * 4;
        if (bgraPremultiplied.Length < stride * height)
        {
            throw new ArgumentException("buffer is smaller than width*height*4.", nameof(bgraPremultiplied));
        }

        var screenDc = NativeMethods.GetDC(IntPtr.Zero);
        if (screenDc == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetDC failed.");
        }
        var memDc = IntPtr.Zero;
        var dib = IntPtr.Zero;
        var oldObj = IntPtr.Zero;
        try
        {
            memDc = NativeMethods.CreateCompatibleDC(screenDc);
            if (memDc == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateCompatibleDC failed.");
            }

            var bmi = new BITMAPINFO
            {
                Header = new BITMAPINFOHEADER
                {
                    BiSize = (uint)Marshal.SizeOf<BITMAPINFOHEADER>(),
                    BiWidth = width,
                    // Negative height => top-down DIB (row 0 at the top), matching the
                    // caller's top-down BGRA buffer.
                    BiHeight = -height,
                    BiPlanes = 1,
                    BiBitCount = 32,
                    BiCompression = NativeConstants.BiRgb,
                },
            };

            dib = NativeMethods.CreateDIBSection(memDc, ref bmi, NativeConstants.DibRgbColors, out var bits, IntPtr.Zero, 0);
            if (dib == IntPtr.Zero || bits == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateDIBSection failed.");
            }

            // Copy the caller's pixels into the DIB backing store.
            unsafe
            {
                fixed (byte* src = bgraPremultiplied)
                {
                    Buffer.MemoryCopy(src, bits.ToPointer(), stride * (long)height, stride * (long)height);
                }
            }

            oldObj = NativeMethods.SelectObject(memDc, dib);

            var blend = new BLENDFUNCTION
            {
                BlendOp = NativeConstants.AcSrcOver,
                BlendFlags = 0,
                SourceConstantAlpha = 255, // per-pixel alpha governs opacity
                AlphaFormat = NativeConstants.AcSrcAlpha,
            };
            var ptSrc = new POINT(0, 0);
            var ptDst = new POINT(screenX, screenY);
            var size = new SIZE(width, height);

            if (!NativeMethods.UpdateLayeredWindow(
                    _hwnd, screenDc, ref ptDst, ref size, memDc, ref ptSrc, 0, ref blend, NativeConstants.UlwAlpha))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateLayeredWindow failed.");
            }

            // Cache the frame for hit-testing.
            CacheFrame(bgraPremultiplied, width, height, stride, screenX, screenY);
        }
        finally
        {
            if (oldObj != IntPtr.Zero)
            {
                _ = NativeMethods.SelectObject(memDc, oldObj);
            }
            if (dib != IntPtr.Zero)
            {
                _ = NativeMethods.DeleteObject(dib);
            }
            if (memDc != IntPtr.Zero)
            {
                _ = NativeMethods.DeleteDC(memDc);
            }
            _ = NativeMethods.ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    /// Show the overlay without activating it (never steals focus).
    public void Show()
    {
        EnsureAlive();
        _ = NativeMethods.ShowWindow(_hwnd, NativeConstants.SwShowNoActivate);
    }

    /// Hide the overlay.
    public void Hide()
    {
        EnsureAlive();
        _ = NativeMethods.ShowWindow(_hwnd, NativeConstants.SwHide);
    }

    /// Move the overlay's top-left to a new screen position (keeps its size).
    public void Move(int screenX, int screenY)
    {
        EnsureAlive();
        _originX = screenX;
        _originY = screenY;
        _ = NativeMethods.SetWindowPos(
            _hwnd, NativeConstants.HwndTopMost, screenX, screenY, 0, 0,
            NativeConstants.SwpNoSize | NativeConstants.SwpNoActivate);
    }

    private void CacheFrame(ReadOnlySpan<byte> buffer, int width, int height, int stride, int originX, int originY)
    {
        var needed = stride * height;
        if (_alpha.Length != needed)
        {
            _alpha = new byte[needed];
        }
        buffer.Slice(0, needed).CopyTo(_alpha);
        _frameWidth = width;
        _frameHeight = height;
        _frameStride = stride;
        _originX = originX;
        _originY = originY;
    }

    private IntPtr WindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        switch (msg)
        {
            case NativeConstants.WmNcHitTest:
            {
                // Screen coords packed into lParam.
                var lp = lParam.ToInt32();
                int screenX = (short)(lp & 0xFFFF);
                int screenY = (short)((lp >> 16) & 0xFFFF);
                var localX = screenX - _originX;
                var localY = screenY - _originY;
                var hit = PerPixelHitTest.IsHit(
                    _alpha, _frameWidth, _frameHeight, _frameStride, localX, localY, AlphaThreshold, topDown: true);
                return new IntPtr(hit ? NativeConstants.HtClient : NativeConstants.HtTransparent);
            }
            case NativeConstants.WmDestroy:
                return IntPtr.Zero;
            default:
                return NativeMethods.DefWindowProcW(hWnd, msg, wParam, lParam);
        }
    }

    private int CurrentExStyle() => NativeMethods.GetWindowLong(_hwnd, NativeConstants.GwlExStyle);

    private void RegisterClass()
    {
        var wc = new WNDCLASSEXW
        {
            CbSize = (uint)Marshal.SizeOf<WNDCLASSEXW>(),
            Style = NativeConstants.CsHRedraw | NativeConstants.CsVRedraw,
            LpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc),
            HInstance = _hInstance,
            LpszClassName = _className,
        };
        var atom = NativeMethods.RegisterClassExW(ref wc);
        if (atom == 0)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "RegisterClassExW failed.");
        }
        _classRegistered = true;
    }

    private void CreateWindow(string title)
    {
        _hwnd = NativeMethods.CreateWindowExW(
            OverlayWindowStyle.WithClickThrough(true),
            _className,
            title,
            OverlayWindowStyle.BaseStyle,
            0, 0, 0, 0,
            IntPtr.Zero, IntPtr.Zero, _hInstance, IntPtr.Zero);
        if (_hwnd == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateWindowExW failed.");
        }
    }

    private void EnsureAlive()
    {
        if (_disposed || _hwnd == IntPtr.Zero)
        {
            throw new ObjectDisposedException(nameof(LayeredOverlayWindow));
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        if (_hwnd != IntPtr.Zero)
        {
            _ = NativeMethods.DestroyWindow(_hwnd);
            _hwnd = IntPtr.Zero;
        }
        if (_classRegistered)
        {
            _ = NativeMethods.UnregisterClassW(_className, _hInstance);
            _classRegistered = false;
        }
    }
}
