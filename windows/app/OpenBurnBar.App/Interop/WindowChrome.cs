using System;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using WinRT.Interop;

namespace OpenBurnBar.App.Interop;

/// <summary>
/// Small helpers that reach the <see cref="AppWindow"/> behind a WinUI <see cref="Window"/>
/// so the shell can do the two things WinUI's window API doesn't expose directly:
/// make a window a borderless top-most flyout (the NSPopover shape) and apply a Mica
/// backdrop (the Liquid-Glass analog, master plan §9.6).
/// </summary>
internal static class WindowChrome
{
    /// <summary>The Win32 HWND backing a WinUI window.</summary>
    public static IntPtr GetHandle(Window window) => WindowNative.GetWindowHandle(window);

    /// <summary>The <see cref="AppWindow"/> facade for a WinUI window.</summary>
    public static AppWindow GetAppWindow(Window window)
    {
        var windowId = Win32Interop.GetWindowIdFromWindow(GetHandle(window));
        return AppWindow.GetFromWindowId(windowId);
    }

    /// <summary>
    /// Apply a Mica backdrop to the window when the OS supports it. On Windows 10 (no Mica)
    /// this silently no-ops and the window keeps its solid theme brush — the honest fallback
    /// the master plan calls for (Frosted↔System↔Clear + reduced-transparency).
    /// </summary>
    public static void TryApplyMica(Window window)
    {
        if (MicaController.IsSupported())
        {
            window.SystemBackdrop = new MicaBackdrop { Kind = MicaKind.Base };
        }
    }

    /// <summary>
    /// Enable or disable the translucent backdrop for a window. Enabling re-applies Mica
    /// when the OS supports it; disabling clears <see cref="Window.SystemBackdrop"/> so the
    /// window falls back to its solid theme brush. This is the shell's reduced-transparency /
    /// high-contrast path (master plan §9.6 theme axes) and is independent of the per-card
    /// Liquid-Glass shim (#1200).
    /// </summary>
    public static void ApplyBackdrop(Window window, bool enabled)
    {
        if (enabled)
        {
            TryApplyMica(window);
        }
        else
        {
            window.SystemBackdrop = null;
        }
    }

    /// <summary>
    /// Turn a window into a borderless, non-resizable, always-on-top flyout: no title bar,
    /// no border, hidden from the taskbar and Alt-Tab. Mirrors an NSPopover attached to the
    /// menu-bar status item.
    /// </summary>
    public static void ConfigureAsFlyout(AppWindow appWindow)
    {
        if (appWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(hasBorder: false, hasTitleBar: false);
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.IsAlwaysOnTop = true;
        }

        // Keep the flyout out of the taskbar and Alt-Tab — it's a transient popover.
        appWindow.IsShownInSwitchers = false;
    }

    /// <summary>
    /// Position a flyout of <paramref name="size"/> at the bottom-right of the work area
    /// (just above the notification tray), inset by <paramref name="margin"/> — where a
    /// menu-bar popover would drop on Windows. Uses the display nearest the window.
    /// </summary>
    public static void MoveToTrayCorner(AppWindow appWindow, SizeInt32 size, int margin = 12)
    {
        appWindow.Resize(size);

        var display = DisplayArea.GetFromWindowId(appWindow.Id, DisplayAreaFallback.Nearest);
        var work = display.WorkArea;

        int x = work.X + work.Width - size.Width - margin;
        int y = work.Y + work.Height - size.Height - margin;
        appWindow.Move(new PointInt32(x, y));
    }
}
