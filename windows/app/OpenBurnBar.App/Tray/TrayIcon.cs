using System;
using static OpenBurnBar.App.Tray.TrayNativeMethods;

namespace OpenBurnBar.App.Tray;

/// <summary>
/// A managed <c>Shell_NotifyIcon</c> tray item — the Windows analog of AppKit's
/// <c>NSStatusItem</c>. Owns a hidden message-only window that receives the tray's
/// callback message on the UI thread's pump; left-click raises <c>onPrimaryClick</c>
/// (toggle the flyout) and right-click shows an Open / Quit context menu.
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    private const uint CallbackMessage = WM_APP + 1;
    private const uint TrayId = 0x4242;
    private const int CmdOpen = 1;
    private const int CmdQuit = 2;

    private readonly string _tooltip;
    private readonly Action _onPrimaryClick;
    private readonly Action _onOpenMainWindow;
    private readonly Action _onExit;

    // The delegate MUST be held so the GC never collects the marshaled thunk under Win32.
    private readonly WndProc _wndProcDelegate;
    private readonly string _className;

    private IntPtr _hwnd;
    private bool _iconAdded;
    private bool _disposed;

    public TrayIcon(string tooltip, Action onPrimaryClick, Action onOpenMainWindow, Action onExit)
    {
        _tooltip = tooltip;
        _onPrimaryClick = onPrimaryClick;
        _onOpenMainWindow = onOpenMainWindow;
        _onExit = onExit;
        _wndProcDelegate = WindowProc;
        _className = "OpenBurnBar.TrayHost." + Environment.ProcessId;
    }

    /// <summary>Register the host window and add the icon to the notification area.</summary>
    public void Show()
    {
        EnsureHostWindow();
        AddOrModifyIcon(NIM_ADD);

        // Opt into v4 behavior (rich callback packing, reliable NIN_* events).
        var data = BuildIconData();
        data.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, ref data);
    }

    private void EnsureHostWindow()
    {
        if (_hwnd != IntPtr.Zero)
        {
            return;
        }

        var hInstance = GetModuleHandleW(null);
        var wndClass = new WNDCLASSEXW
        {
            cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<WNDCLASSEXW>(),
            lpfnWndProc = System.Runtime.InteropServices.Marshal.GetFunctionPointerForDelegate(_wndProcDelegate),
            hInstance = hInstance,
            lpszClassName = _className,
        };
        RegisterClassExW(ref wndClass);

        // Message-only window (HWND_MESSAGE): no UI, just a pump target for the callback.
        _hwnd = CreateWindowExW(
            0, _className, "OpenBurnBar Tray Host", 0,
            0, 0, 0, 0,
            HWND_MESSAGE, IntPtr.Zero, hInstance, IntPtr.Zero);
    }

    private NOTIFYICONDATAW BuildIconData()
    {
        return new NOTIFYICONDATAW
        {
            cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<NOTIFYICONDATAW>(),
            hWnd = _hwnd,
            uID = TrayId,
            uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP,
            uCallbackMessage = CallbackMessage,
            // System app icon keeps the spike text-only (no binary .ico blob). WINUI-017
            // swaps in the branded ember icon loaded from Assets/OpenBurnBar.ico.
            hIcon = LoadIconW(IntPtr.Zero, IDI_APPLICATION),
            szTip = _tooltip,
        };
    }

    private void AddOrModifyIcon(uint message)
    {
        var data = BuildIconData();
        if (Shell_NotifyIconW(message, ref data))
        {
            _iconAdded = true;
        }
    }

    private IntPtr WindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == CallbackMessage)
        {
            // v4 packing: LOWORD(lParam) is the mouse/keyboard event; WPARAM holds the
            // screen anchor (x = LOWORD, y = HIWORD) for placing the context menu.
            int notifyEvent = LoWord(lParam);
            switch ((uint)notifyEvent)
            {
                case WM_LBUTTONUP:
                    _onPrimaryClick();
                    return IntPtr.Zero;
                case WM_RBUTTONUP:
                case WM_CONTEXTMENU:
                    ShowContextMenu(LoWord(wParam), HiWord(wParam));
                    return IntPtr.Zero;
            }

            return IntPtr.Zero;
        }

        if (msg == WM_DESTROY)
        {
            return IntPtr.Zero;
        }

        return DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    private void ShowContextMenu(int anchorX, int anchorY)
    {
        // Fall back to the cursor when the shell didn't supply an anchor.
        if (anchorX == 0 && anchorY == 0 && GetCursorPos(out var cursor))
        {
            anchorX = cursor.X;
            anchorY = cursor.Y;
        }

        var menu = CreatePopupMenu();
        if (menu == IntPtr.Zero)
        {
            return;
        }

        try
        {
            AppendMenuW(menu, MF_STRING, (UIntPtr)CmdOpen, "Open OpenBurnBar");
            AppendMenuW(menu, MF_SEPARATOR, UIntPtr.Zero, null);
            AppendMenuW(menu, MF_STRING, (UIntPtr)CmdQuit, "Quit");

            // Classic Win32 quirk: the owner must be foreground or the menu never dismisses.
            SetForegroundWindow(_hwnd);
            int command = TrackPopupMenuEx(
                menu,
                TPM_RIGHTBUTTON | TPM_NONOTIFY | TPM_RETURNCMD,
                anchorX, anchorY, _hwnd, IntPtr.Zero);
            PostMessageW(_hwnd, 0x0000 /* WM_NULL */, IntPtr.Zero, IntPtr.Zero);

            switch (command)
            {
                case CmdOpen:
                    _onOpenMainWindow();
                    break;
                case CmdQuit:
                    _onExit();
                    break;
            }
        }
        finally
        {
            DestroyMenu(menu);
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        if (_iconAdded)
        {
            var data = BuildIconData();
            Shell_NotifyIconW(NIM_DELETE, ref data);
            _iconAdded = false;
        }

        if (_hwnd != IntPtr.Zero)
        {
            DestroyWindow(_hwnd);
            _hwnd = IntPtr.Zero;
        }
    }
}
