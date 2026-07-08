using System;
using OpenBurnBar.Pretext;

namespace OpenBurnBar.App.Chat;

/// <summary>
/// Process-wide holder for the chat surface's Pretext engine. Streaming bubbles
/// live inside <see cref="Microsoft.UI.Xaml.Controls.ItemsRepeater"/> templates
/// where reaching them from the page is awkward, so they pull the shared engine
/// from here on load and react when it becomes available. The
/// <see cref="StreamingBubble"/> still exposes a per-instance
/// <c>Engine</c> for tests / alternate hosting.
/// </summary>
public static class ChatPretextEngineHost
{
    private static PretextEngine? _current;

    /// The engine the offscreen WebView2 host has produced, or null until ready.
    public static PretextEngine? Current
    {
        get => _current;
        set
        {
            _current = value;
            CurrentChanged?.Invoke(value);
        }
    }

    /// Raised when <see cref="Current"/> changes so already-loaded bubbles adopt it.
    public static event Action<PretextEngine?>? CurrentChanged;
}
