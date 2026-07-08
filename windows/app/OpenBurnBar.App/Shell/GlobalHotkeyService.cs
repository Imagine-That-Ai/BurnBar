using System;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using OpenBurnBar.App.Interop;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// Registers a process-global hotkey (default Ctrl+K) that opens the Command Palette — the
/// Windows substitute for the macOS App-Intents / menu-bar key equivalent.
///
/// It uses the Win32 <c>RegisterHotKey</c> + a ComCtl32 window subclass to catch
/// <c>WM_HOTKEY</c> on the host window's message loop. The P/Invoke surface is real and
/// compiles cross-platform, but the <b>runtime</b> hotkey dispatch can only be exercised on a
/// Windows dev host — this macOS worktree cannot run the message loop. Treat the live keypress
/// as CI/dev-host-deferred (a "wiring stub" that is genuinely wired, not faked).
/// </summary>
public sealed class GlobalHotkeyService : IDisposable
{
    private const int WmHotkey = 0x0312;
    private const uint ModControl = 0x0002;
    private const uint ModNoRepeat = 0x4000;
    private const uint VkK = 0x4B;
    private const int HotkeyId = 0xB0B; // arbitrary per-window id

    // Keep the delegate alive for the lifetime of the subclass to avoid GC of the callback.
    private readonly SubclassProc _proc;
    private Action? _onInvoke;
    private IntPtr _hwnd;
    private bool _registered;
    private bool _disposed;

    public GlobalHotkeyService()
    {
        _proc = SubclassCallback;
    }

    /// <summary>
    /// Register the hotkey against a window and invoke <paramref name="onInvoke"/> when it fires.
    /// Returns <c>false</c> if the OS refused the registration (e.g. already owned by another app).
    /// </summary>
    public bool Register(Window window, Action onInvoke)
    {
        if (_registered)
        {
            return true;
        }

        _onInvoke = onInvoke;
        _hwnd = WindowChrome.GetHandle(window);

        SetWindowSubclass(_hwnd, _proc, UIntPtr.Zero, UIntPtr.Zero);
        _registered = RegisterHotKey(_hwnd, HotkeyId, ModControl | ModNoRepeat, VkK);
        return _registered;
    }

    private IntPtr SubclassCallback(IntPtr hWnd, uint uMsg, UIntPtr wParam, IntPtr lParam, UIntPtr idSubclass, UIntPtr refData)
    {
        if (uMsg == WmHotkey && (int)wParam == HotkeyId)
        {
            _onInvoke?.Invoke();
            return IntPtr.Zero;
        }

        return DefSubclassProc(hWnd, uMsg, wParam, lParam);
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
            if (_registered)
            {
                UnregisterHotKey(_hwnd, HotkeyId);
                _registered = false;
            }

            RemoveWindowSubclass(_hwnd, _proc, UIntPtr.Zero);
        }

        _onInvoke = null;
    }

    private delegate IntPtr SubclassProc(IntPtr hWnd, uint uMsg, UIntPtr wParam, IntPtr lParam, UIntPtr idSubclass, UIntPtr refData);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(IntPtr hWnd, SubclassProc pfnSubclass, UIntPtr uIdSubclass, UIntPtr dwRefData);

    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveWindowSubclass(IntPtr hWnd, SubclassProc pfnSubclass, UIntPtr uIdSubclass);

    [DllImport("comctl32.dll")]
    private static extern IntPtr DefSubclassProc(IntPtr hWnd, uint uMsg, UIntPtr wParam, IntPtr lParam);
}
