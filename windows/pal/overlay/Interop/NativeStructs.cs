using System;
using System.Runtime.InteropServices;

namespace OpenBurnBar.Pal.Overlay.Interop;

// Win32 structs for the layered overlay window. Declarations only.

[StructLayout(LayoutKind.Sequential)]
internal struct POINT
{
    public int X;
    public int Y;

    public POINT(int x, int y)
    {
        X = x;
        Y = y;
    }
}

[StructLayout(LayoutKind.Sequential)]
internal struct SIZE
{
    public int Cx;
    public int Cy;

    public SIZE(int cx, int cy)
    {
        Cx = cx;
        Cy = cy;
    }
}

// AC_SRC_OVER blend with per-pixel alpha (AC_SRC_ALPHA). SourceConstantAlpha is the
// window-wide opacity multiplier (255 = fully governed by per-pixel alpha).
[StructLayout(LayoutKind.Sequential)]
internal struct BLENDFUNCTION
{
    public byte BlendOp;
    public byte BlendFlags;
    public byte SourceConstantAlpha;
    public byte AlphaFormat;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
internal struct WNDCLASSEXW
{
    public uint CbSize;
    public uint Style;
    public IntPtr LpfnWndProc;
    public int CbClsExtra;
    public int CbWndExtra;
    public IntPtr HInstance;
    public IntPtr HIcon;
    public IntPtr HCursor;
    public IntPtr HbrBackground;
    [MarshalAs(UnmanagedType.LPWStr)] public string? LpszMenuName;
    [MarshalAs(UnmanagedType.LPWStr)] public string? LpszClassName;
    public IntPtr HIconSm;
}

[StructLayout(LayoutKind.Sequential)]
internal struct BITMAPINFOHEADER
{
    public uint BiSize;
    public int BiWidth;
    public int BiHeight;
    public ushort BiPlanes;
    public ushort BiBitCount;
    public uint BiCompression;
    public uint BiSizeImage;
    public int BiXPelsPerMeter;
    public int BiYPelsPerMeter;
    public uint BiClrUsed;
    public uint BiClrImportant;
}

// 32-bpp DIB: the color table is empty, so BITMAPINFO is just the header for our use.
[StructLayout(LayoutKind.Sequential)]
internal struct BITMAPINFO
{
    public BITMAPINFOHEADER Header;
    // For BI_RGB 32-bpp there is no palette; a single dummy quad keeps the struct
    // valid for CreateDIBSection's [In] BITMAPINFO parameter.
    public uint FirstColor;
}
