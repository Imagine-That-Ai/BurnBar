using System;

namespace OpenBurnBar.Pal.Overlay;

// MARK: - Overlay window style math (portable)
//
// The pure bit math for the transparent, click-through, non-activating overlay
// window the desktop pet lives in — the Windows peer of the borderless,
// ignores-mouse-events NSPanel the macOS companion uses
// (`AgentLens/PetCompanion/Shell/PetPanel.swift`).
//
// This carries NO P/Invoke and NO OS call, so the exact extended-style bitmask and
// the click-through toggle are unit-tested on the macOS authoring host. The Win32
// host (LayeredOverlayWindow) applies these values via CreateWindowEx /
// SetWindowLongPtr; keeping the math here means the security-relevant flag set
// (NOACTIVATE so the overlay never steals focus; TOOLWINDOW so it never shows in
// Alt-Tab; LAYERED for per-pixel alpha) is provable without a window.

/// The extended (WS_EX_*) and base (WS_*) window-style constants + transforms for
/// the pet overlay window.
public static class OverlayWindowStyle
{
    // ── WS_EX_* extended styles (winuser.h) ──────────────────────────────────────

    /// WS_EX_TRANSPARENT — the window is "click-through": mouse messages fall to the
    /// windows beneath it. Toggled on/off as the pet grabs vs releases the cursor.
    public const int WsExTransparent = 0x0000_0020;

    /// WS_EX_TOOLWINDOW — keep the overlay out of the taskbar + Alt-Tab.
    public const int WsExToolWindow = 0x0000_0080;

    /// WS_EX_TOPMOST — float above ordinary windows.
    public const int WsExTopMost = 0x0000_0008;

    /// WS_EX_LAYERED — required for per-pixel alpha via UpdateLayeredWindow.
    public const int WsExLayered = 0x0008_0000;

    /// WS_EX_NOACTIVATE — the overlay never becomes the foreground/active window, so
    /// it cannot steal keyboard focus from the app the user is working in.
    public const int WsExNoActivate = 0x0800_0000;

    // ── WS_* base styles ─────────────────────────────────────────────────────────

    /// WS_POPUP — a borderless top-level window (no caption/frame).
    public const uint WsPopup = 0x8000_0000;

    /// WS_VISIBLE — shown on create.
    public const uint WsVisible = 0x1000_0000;

    /// The always-on extended-style base for the overlay: layered (per-pixel alpha),
    /// tool-window (hidden from Alt-Tab/taskbar), topmost, and — critically —
    /// no-activate (never steals focus). Click-through (WS_EX_TRANSPARENT) is layered
    /// on top of this via <see cref="WithClickThrough"/>.
    public const int BaseExStyle = WsExLayered | WsExToolWindow | WsExTopMost | WsExNoActivate;

    /// The base window style: a visible borderless popup.
    public const uint BaseStyle = WsPopup | WsVisible;

    /// The full extended style for a given click-through mode.
    public static int WithClickThrough(bool clickThrough) =>
        clickThrough ? BaseExStyle | WsExTransparent : BaseExStyle;

    /// Set the click-through bit on an existing extended style (mouse passes through).
    public static int EnableClickThrough(int exStyle) => exStyle | WsExTransparent;

    /// Clear the click-through bit (the overlay receives mouse input again — e.g. to
    /// drag the pet or click its bubble).
    public static int DisableClickThrough(int exStyle) => exStyle & ~WsExTransparent;

    /// Whether an extended style currently passes mouse input through.
    public static bool IsClickThrough(int exStyle) => (exStyle & WsExTransparent) != 0;

    /// Whether an extended style never activates (focus-safety invariant). The host
    /// asserts this stays true across every click-through toggle.
    public static bool IsNonActivating(int exStyle) => (exStyle & WsExNoActivate) != 0;

    /// Whether an extended style is hidden from Alt-Tab / taskbar.
    public static bool IsToolWindow(int exStyle) => (exStyle & WsExToolWindow) != 0;

    /// Whether an extended style is layered (per-pixel alpha capable).
    public static bool IsLayered(int exStyle) => (exStyle & WsExLayered) != 0;
}
