using System;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using OpenBurnBar.App.Interop;
using OpenBurnBar.ComputerUse.Core.Gate;

namespace OpenBurnBar.App.Shell;

/// <summary>Independent global panic hotkey and workstation-lock monitor.</summary>
public sealed class ComputerUseSafetyMonitor : IDisposable
{
    private const int WmHotkey = 0x0312;
    private const int WmWtsSessionChange = 0x02B1;
    private const int WtsSessionLock = 0x7;
    private const int HotkeyId = 0xB0C;
    private const uint ModAlt = 0x0001;
    private const uint ModControl = 0x0002;
    private const uint ModWin = 0x0008;
    private const uint ModNoRepeat = 0x4000;
    private const uint VkOemPeriod = 0xBE;

    private readonly SubclassProc _proc;
    private Action<ComputerUsePanicSource>? _onPanic;
    private IntPtr _hwnd;
    private bool _registered;
    private bool _disposed;

    public ComputerUseSafetyMonitor() => _proc = SubclassCallback;

    public bool Register(Window window, Action<ComputerUsePanicSource> onPanic)
    {
        ArgumentNullException.ThrowIfNull(window);
        ArgumentNullException.ThrowIfNull(onPanic);
        if (_registered)
        {
            return true;
        }

        _onPanic = onPanic;
        _hwnd = WindowChrome.GetHandle(window);
        if (!SetWindowSubclass(_hwnd, _proc, new UIntPtr(1), UIntPtr.Zero))
        {
            Reset();
            return false;
        }

        bool hotkey = RegisterHotKey(
            _hwnd,
            HotkeyId,
            ModAlt | ModControl | ModWin | ModNoRepeat,
            VkOemPeriod);
        bool sessionNotifications = WTSRegisterSessionNotification(_hwnd, 0);
        if (!hotkey || !sessionNotifications)
        {
            if (hotkey) UnregisterHotKey(_hwnd, HotkeyId);
            if (sessionNotifications) WTSUnRegisterSessionNotification(_hwnd);
            RemoveWindowSubclass(_hwnd, _proc, new UIntPtr(1));
            Reset();
            return false;
        }

        _registered = true;
        return true;
    }

    private IntPtr SubclassCallback(
        IntPtr hWnd,
        uint message,
        UIntPtr wParam,
        IntPtr lParam,
        UIntPtr idSubclass,
        UIntPtr refData)
    {
        if (message == WmHotkey && (int)wParam == HotkeyId)
        {
            _onPanic?.Invoke(ComputerUsePanicSource.Hotkey);
            return IntPtr.Zero;
        }
        if (message == WmWtsSessionChange && (int)wParam == WtsSessionLock)
        {
            _onPanic?.Invoke(ComputerUsePanicSource.MacLock);
        }
        return DefSubclassProc(hWnd, message, wParam, lParam);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        if (_registered)
        {
            UnregisterHotKey(_hwnd, HotkeyId);
            WTSUnRegisterSessionNotification(_hwnd);
            RemoveWindowSubclass(_hwnd, _proc, new UIntPtr(1));
        }
        Reset();
    }

    private void Reset()
    {
        _registered = false;
        _hwnd = IntPtr.Zero;
        _onPanic = null;
    }

    private delegate IntPtr SubclassProc(
        IntPtr hWnd,
        uint message,
        UIntPtr wParam,
        IntPtr lParam,
        UIntPtr idSubclass,
        UIntPtr refData);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint virtualKey);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WTSRegisterSessionNotification(IntPtr hWnd, uint flags);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WTSUnRegisterSessionNotification(IntPtr hWnd);

    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(
        IntPtr hWnd,
        SubclassProc callback,
        UIntPtr idSubclass,
        UIntPtr refData);

    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveWindowSubclass(
        IntPtr hWnd,
        SubclassProc callback,
        UIntPtr idSubclass);

    [DllImport("comctl32.dll")]
    private static extern IntPtr DefSubclassProc(
        IntPtr hWnd,
        uint message,
        UIntPtr wParam,
        IntPtr lParam);
}
