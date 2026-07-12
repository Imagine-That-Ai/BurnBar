using System.Collections.Generic;

namespace OpenBurnBar.App.TextExpansion;

/// <summary>
/// US-ANSI virtual-keycode → printable-character fallback. Faithful port of the
/// pure lookup half of Swift <c>TextExpansionKeyEventCharacters.usKeyboardCharacter</c>
/// (OpenBurnBarCore/.../TextExpansion/TextExpansionKeyEventCharacters.swift).
/// </summary>
/// <remarks>
/// The AppKit / CGEvent unicode-extraction half of the Swift type is macOS-only OS
/// glue (keystroke capture = bucket B/C) and is intentionally NOT ported here. This
/// pure table IS ported because it is the parity oracle for the original global-tap
/// bug: punctuation like <c>&amp;</c> (Shift+7) can arrive with an empty unicode
/// payload, and the <c>&amp;&amp;</c> trigger prefix cannot build up without this
/// fallback. The keycodes below are macOS ANSI virtual keycodes; the Windows OS
/// adapter supplies its own VK→char map behind the same idea. Retained so the
/// golden corpus mirrors Swift <c>testUSKeyboardMapResolvesShiftedNumberRowSymbols</c>.
/// </remarks>
public static class TextExpansionUsKeyboardMap
{
    private static readonly IReadOnlyDictionary<int, string> Base = new Dictionary<int, string>
    {
        [0] = "a", [1] = "s", [2] = "d", [3] = "f", [4] = "h", [5] = "g", [6] = "z", [7] = "x", [8] = "c", [9] = "v",
        [11] = "b", [12] = "q", [13] = "w", [14] = "e", [15] = "r", [16] = "y", [17] = "t", [18] = "1", [19] = "2",
        [20] = "3", [21] = "4", [22] = "6", [23] = "5", [24] = "=", [25] = "9", [26] = "7", [27] = "-", [28] = "8",
        [29] = "0", [30] = "]", [31] = "o", [32] = "u", [33] = "[", [34] = "i", [35] = "p", [37] = "l", [38] = "j",
        [39] = "'", [40] = "k", [41] = ";", [42] = "\\", [43] = ",", [44] = "/", [45] = "n", [46] = "m", [47] = ".",
        [49] = " ", [50] = "`",
    };

    private static readonly IReadOnlyDictionary<int, string> Shifted = new Dictionary<int, string>
    {
        [18] = "!", [19] = "@", [20] = "#", [21] = "$", [23] = "%", [22] = "^", [26] = "&", [28] = "*", [25] = "(",
        [29] = ")", [27] = "_", [24] = "+", [30] = "}", [33] = "{", [39] = "\"", [41] = ":", [42] = "|", [43] = "<",
        [44] = ">", [47] = "?", [50] = "~",
    };

    /// <summary>
    /// US-ANSI fallback for punctuation-heavy triggers like <c>&amp;&amp;name</c>.
    /// Returns null for a keycode with no printable mapping. Mirrors Swift
    /// <c>usKeyboardCharacter(keyCode:shift:)</c> including the shift precedence.
    /// </summary>
    public static string? UsKeyboardCharacter(int keyCode, bool shift)
    {
        if (shift && Shifted.TryGetValue(keyCode, out string? shifted))
        {
            return shifted;
        }

        return Base.TryGetValue(keyCode, out string? value) ? value : null;
    }
}
