using System;

namespace OpenBurnBar.Pal.Overlay.Interop;

// Win32 constants for the layered click-through overlay window. Declarations only;
// live execution is on a Windows dev host / CI (see windows/pal/overlay/README.md).
internal static class NativeConstants
{
    // GetWindowLongPtr / SetWindowLongPtr indices (winuser.h).
    internal const int GwlStyle = -16;
    internal const int GwlExStyle = -20;

    // Window messages.
    internal const uint WmDestroy = 0x0002;
    internal const uint WmNcDestroy = 0x0082;
    internal const uint WmNcHitTest = 0x0084;
    internal const uint WmClose = 0x0010;

    // WM_NCHITTEST results.
    internal const int HtTransparent = -1;
    internal const int HtClient = 1;
    internal const int HtCaption = 2;

    // ShowWindow commands — always the NOACTIVATE variants so the overlay never
    // steals focus.
    internal const int SwHide = 0;
    internal const int SwShowNoActivate = 4;
    internal const int SwShowNa = 8;

    // SetWindowPos flags + z-order.
    internal const uint SwpNoSize = 0x0001;
    internal const uint SwpNoMove = 0x0002;
    internal const uint SwpNoActivate = 0x0010;
    internal const uint SwpShowWindow = 0x0040;
    internal static readonly IntPtr HwndTopMost = new(-1);

    // UpdateLayeredWindow flags + alpha blend (wingdi.h).
    internal const uint UlwAlpha = 0x0000_0002;
    internal const byte AcSrcOver = 0x00;
    internal const byte AcSrcAlpha = 0x01;

    // DIB section.
    internal const uint BiRgb = 0;
    internal const uint DibRgbColors = 0;

    // Class styles.
    internal const uint CsHRedraw = 0x0002;
    internal const uint CsVRedraw = 0x0001;
}
