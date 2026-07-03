// Shared glue for Settings leaf pages: after a page registers its anchored rows, this
// consumes the router's pending anchor/focus and scrolls there — the WinUI realization
// of a macOS destination view inspecting router.pendingAnchor on appear and calling
// consumePendingAnchor / consumePendingFocus once it has scrolled.

using OpenBurnBar.App.Settings;

namespace OpenBurnBar.App.Settings.Winui;

internal static class SettingsLeafPageSupport
{
    /// <summary>Scroll to (and clear) the router's pending anchor if this page owns it.</summary>
    public static void ConsumePending(SettingsRouter? router, SettingsAnchorScroller scroller)
    {
        if (router?.PendingAnchor is not string anchor)
        {
            return;
        }

        if (scroller.ScrollTo(anchor, router.PendingFocus))
        {
            router.ConsumePendingAnchor(anchor);
            if (router.PendingFocus is string focus)
            {
                router.ConsumePendingFocus(focus);
            }
        }
    }
}
