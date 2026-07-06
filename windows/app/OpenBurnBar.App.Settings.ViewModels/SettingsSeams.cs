// Small OS/data-bound seams shared by several settings view-models. Each is an
// interface the WinUI shell backs with the real Windows implementation; tests wire an
// in-memory fake. Keeping the common ones here avoids re-declaring identical seams in
// every tab file.

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>Writes text to the system clipboard (WinUI: <c>Clipboard.SetContent</c>).</summary>
public interface ISettingsClipboard
{
    /// <summary>Copy <paramref name="text"/> to the clipboard.</summary>
    void WriteText(string text);
}

/// <summary>
/// Reports whether the app currently has the OS accessibility/UI-automation grant that
/// global keystroke features need (macOS <c>AXIsProcessTrusted()</c>; Windows UIA).
/// </summary>
public interface IAccessibilityProbe
{
    /// <summary>Whether accessibility/UI-automation access is granted right now.</summary>
    bool IsAccessibilityTrusted { get; }
}

/// <summary>A no-op clipboard (default for tests / headless).</summary>
public sealed class NullSettingsClipboard : ISettingsClipboard
{
    /// <summary>Shared instance.</summary>
    public static readonly NullSettingsClipboard Instance = new();

    /// <summary>The last text "copied" — lets a test assert what the VM produced.</summary>
    public string? LastText { get; private set; }

    /// <inheritdoc />
    public void WriteText(string text) => LastText = text;
}

/// <summary>A fixed-answer accessibility probe (default for tests).</summary>
public sealed class StaticAccessibilityProbe : IAccessibilityProbe
{
    public StaticAccessibilityProbe(bool trusted) => IsAccessibilityTrusted = trusted;

    /// <inheritdoc />
    public bool IsAccessibilityTrusted { get; set; }
}
