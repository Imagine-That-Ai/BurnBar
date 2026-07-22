// IInputSynthesizer over user32 SendInput.
//
// R17 (master plan § risk register): on Windows, SendInput makes the
// capability-token gate ADVISORY — any process running at the SAME integrity
// level as the agent can synthesize identical input, so a token cannot make a
// SendInput action non-bypassable, and SendInput cannot reach the secure desktop
// / UAC / lock screen at all. Therefore:
//   * <see cref="RoutesThroughSignedDriver"/> is false here, and
//   * production interactive-desktop input runs only in the separately signed,
//     authenticated broker with protected-target denial and a leaf kill check;
//   * secure-desktop / cross-integrity / lock-screen injection is out of scope.
//     It would require a purpose-built, signed keyboard/mouse HID driver and its
//     own certification. ViGEm is a game-controller emulation bus and does not
//     satisfy that keyboard/mouse boundary.
//
// This class is Windows-only at runtime (SendInput). It Roslyn-compiles on the
// macOS authoring host; the live injection proof is a Windows host task.

using System;
using System.Collections.Generic;
using System.Runtime.Versioning;
using OpenBurnBar.ComputerUse.Core.Adapters;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Windows.Interop;

namespace OpenBurnBar.ComputerUse.Windows;

/// <summary>Advisory desktop input synthesizer backed by user32 SendInput.</summary>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class SendInputInputSynthesizer : IInputSynthesizer
{
    private readonly Func<bool> _killSwitchActive;

    public SendInputInputSynthesizer(Func<bool>? killSwitchActive = null)
    {
        _killSwitchActive = killSwitchActive ?? (() => false);
    }

    /// <summary>False: SendInput is advisory + same-integrity-bypassable (R17).</summary>
    public bool RoutesThroughSignedDriver => false;

    public InputSynthesisResult Synthesize(MacInputAction action)
    {
        if (KillSwitchActive())
        {
            return new InputSynthesisResult(dispatched: false, detail: "kill_switch");
        }

        switch (action.ActionKind)
        {
            case MacInputAction.Kind.Click:
            case MacInputAction.Kind.PointerClick:
                return ClickAt(action.DisplayX, action.DisplayY, action.MouseButton);
            case MacInputAction.Kind.PointerMove:
                return MoveTo(action.DisplayX, action.DisplayY);
            case MacInputAction.Kind.Type:
                return TypeText(action.Text);
            case MacInputAction.Kind.Scroll:
                return Scroll(action.DeltaX ?? 0, action.DeltaY ?? 0);
            case MacInputAction.Kind.Key:
            case MacInputAction.Kind.Shortcut:
                return KeyPress(action.Key, action.Modifiers, action.ActionKind == MacInputAction.Kind.Shortcut ? "shortcut" : "key");
            case MacInputAction.Kind.DragDrop:
                return DragDrop(action);
            default:
                return new InputSynthesisResult(dispatched: false, detail: "unsupported");
        }
    }

    private static InputSynthesisResult MoveTo(int? x, int? y)
    {
        if (x is null || y is null)
        {
            return new InputSynthesisResult(dispatched: false, detail: "missing_coordinates");
        }

        var move = MakeAbsoluteMove(x.Value, y.Value);
        return Send(new[] { move }, "pointer_move");
    }

    private static InputSynthesisResult ClickAt(int? x, int? y, int mouseButton)
    {
        if (x is null || y is null)
        {
            return new InputSynthesisResult(dispatched: false, detail: "missing_coordinates");
        }

        var (down, up) = mouseButton == 1
            ? (NativeMethods.MouseEventFRightDown, NativeMethods.MouseEventFRightUp)
            : (NativeMethods.MouseEventFLeftDown, NativeMethods.MouseEventFLeftUp);

        var inputs = new[]
        {
            MakeAbsoluteMove(x.Value, y.Value),
            MakeMouse(down),
            MakeMouse(up),
        };
        return Send(inputs, "click");
    }

    private static InputSynthesisResult Scroll(int deltaX, int deltaY)
    {
        if (deltaX == 0 && deltaY == 0)
        {
            return new InputSynthesisResult(dispatched: false, detail: "zero_scroll");
        }

        var inputs = new List<NativeMethods.INPUT>(capacity: 2);
        if (deltaY != 0)
        {
            var vertical = MakeMouse(NativeMethods.MouseEventFWheel);
            vertical.u.mi.mouseData = unchecked((uint)(deltaY * NativeMethods.WheelDelta));
            inputs.Add(vertical);
        }

        if (deltaX != 0)
        {
            var horizontal = MakeMouse(NativeMethods.MouseEventFHWheel);
            horizontal.u.mi.mouseData = unchecked((uint)(deltaX * NativeMethods.WheelDelta));
            inputs.Add(horizontal);
        }

        return Send(inputs.ToArray(), "scroll");
    }

    private InputSynthesisResult TypeText(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return new InputSynthesisResult(dispatched: false, detail: "empty_text");
        }

        if (text.Length > 64 * 1024)
        {
            return new InputSynthesisResult(dispatched: false, detail: "text_too_large");
        }

        for (var index = 0; index < text.Length; index++)
        {
            if (KillSwitchActive())
            {
                return new InputSynthesisResult(dispatched: false, detail: "kill_switch");
            }

            NativeMethods.INPUT[] inputs =
            {
                MakeUnicode(text[index], keyUp: false),
                MakeUnicode(text[index], keyUp: true),
            };
            InputSynthesisResult result = Send(inputs, "type");
            if (!result.Dispatched)
            {
                return result;
            }
        }

        return new InputSynthesisResult(dispatched: true, detail: "type");
    }

    private static InputSynthesisResult KeyPress(
        string? key,
        IReadOnlyList<string>? modifiers,
        string detail)
    {
        if (!TryVirtualKey(key, out var virtualKey))
        {
            return new InputSynthesisResult(dispatched: false, detail: "unsupported_key");
        }

        var modifierKeys = new List<ushort>();
        if (modifiers is not null)
        {
            foreach (var modifier in modifiers)
            {
                if (!TryModifierKey(modifier, out var modifierKey) || modifierKeys.Contains(modifierKey))
                {
                    return new InputSynthesisResult(dispatched: false, detail: "unsupported_modifier");
                }

                modifierKeys.Add(modifierKey);
            }
        }

        var inputs = new List<NativeMethods.INPUT>(modifierKeys.Count * 2 + 2);
        foreach (var modifierKey in modifierKeys)
        {
            inputs.Add(MakeVirtualKey(modifierKey, keyUp: false));
        }

        inputs.Add(MakeVirtualKey(virtualKey, keyUp: false));
        inputs.Add(MakeVirtualKey(virtualKey, keyUp: true));

        for (var index = modifierKeys.Count - 1; index >= 0; index--)
        {
            inputs.Add(MakeVirtualKey(modifierKeys[index], keyUp: true));
        }

        return Send(inputs.ToArray(), detail);
    }

    private static InputSynthesisResult DragDrop(MacInputAction action)
    {
        if (action.DisplayX is null || action.DisplayY is null || action.DragEndX is null || action.DragEndY is null)
        {
            return new InputSynthesisResult(dispatched: false, detail: "missing_coordinates");
        }

        var inputs = new[]
        {
            MakeAbsoluteMove(action.DisplayX.Value, action.DisplayY.Value),
            MakeMouse(NativeMethods.MouseEventFLeftDown),
            MakeAbsoluteMove(action.DragEndX.Value, action.DragEndY.Value),
            MakeMouse(NativeMethods.MouseEventFLeftUp),
        };
        return Send(inputs, "drag_drop");
    }

    private static bool TryModifierKey(string? modifier, out ushort virtualKey)
    {
        virtualKey = modifier?.Trim().ToLowerInvariant() switch
        {
            "ctrl" or "control" => 0xA2,
            "shift" => 0xA0,
            "alt" or "option" => 0xA4,
            "win" or "windows" or "meta" or "command" or "cmd" => 0x5B,
            _ => 0,
        };
        return virtualKey != 0;
    }

    private static bool TryVirtualKey(string? key, out ushort virtualKey)
    {
        virtualKey = 0;
        var normalized = key?.Trim().ToUpperInvariant();
        if (string.IsNullOrEmpty(normalized))
        {
            return false;
        }

        if (normalized.Length == 1)
        {
            var character = normalized[0];
            if (character is >= 'A' and <= 'Z' or >= '0' and <= '9')
            {
                virtualKey = character;
                return true;
            }
        }

        if (normalized.Length > 1 && normalized[0] == 'F' && int.TryParse(normalized.AsSpan(1), out var functionNumber)
            && functionNumber is >= 1 and <= 24)
        {
            virtualKey = (ushort)(0x70 + functionNumber - 1);
            return true;
        }

        virtualKey = normalized switch
        {
            "ENTER" or "RETURN" => 0x0D,
            "ESC" or "ESCAPE" => 0x1B,
            "TAB" => 0x09,
            "SPACE" => 0x20,
            "BACKSPACE" => 0x08,
            "DELETE" or "DEL" => 0x2E,
            "INSERT" or "INS" => 0x2D,
            "HOME" => 0x24,
            "END" => 0x23,
            "PAGEUP" or "PAGE_UP" or "PGUP" => 0x21,
            "PAGEDOWN" or "PAGE_DOWN" or "PGDN" => 0x22,
            "LEFT" or "ARROWLEFT" or "ARROW_LEFT" => 0x25,
            "UP" or "ARROWUP" or "ARROW_UP" => 0x26,
            "RIGHT" or "ARROWRIGHT" or "ARROW_RIGHT" => 0x27,
            "DOWN" or "ARROWDOWN" or "ARROW_DOWN" => 0x28,
            "CAPSLOCK" or "CAPS_LOCK" => 0x14,
            "NUMLOCK" or "NUM_LOCK" => 0x90,
            "PRINTSCREEN" or "PRINT_SCREEN" or "PRTSC" => 0x2C,
            "COMMA" => 0xBC,
            "PERIOD" or "DOT" => 0xBE,
            "SLASH" => 0xBF,
            "SEMICOLON" => 0xBA,
            "APOSTROPHE" or "QUOTE" => 0xDE,
            "LBRACKET" or "LEFTBRACKET" => 0xDB,
            "RBRACKET" or "RIGHTBRACKET" => 0xDD,
            "BACKSLASH" => 0xDC,
            "MINUS" => 0xBD,
            "EQUAL" or "EQUALS" => 0xBB,
            "GRAVE" or "BACKTICK" => 0xC0,
            _ => 0,
        };
        return virtualKey != 0;
    }

    private static NativeMethods.INPUT MakeVirtualKey(ushort virtualKey, bool keyUp) => new()
    {
        type = NativeMethods.InputKeyboard,
        u = new NativeMethods.INPUTUNION
        {
            ki = new NativeMethods.KEYBDINPUT
            {
                wVk = virtualKey,
                dwFlags = keyUp ? NativeMethods.KeyEventFKeyUp : 0,
            },
        },
    };

    private static NativeMethods.INPUT MakeAbsoluteMove(int displayX, int displayY)
    {
        var originX = NativeMethods.GetSystemMetrics(NativeMethods.SmXVirtualScreen);
        var originY = NativeMethods.GetSystemMetrics(NativeMethods.SmYVirtualScreen);
        var width = Math.Max(1, NativeMethods.GetSystemMetrics(NativeMethods.SmCxVirtualScreen));
        var height = Math.Max(1, NativeMethods.GetSystemMetrics(NativeMethods.SmCyVirtualScreen));
        var normalizedX = Math.Clamp((displayX - originX) * 65535.0 / Math.Max(1, width - 1), 0, 65535);
        var normalizedY = Math.Clamp((displayY - originY) * 65535.0 / Math.Max(1, height - 1), 0, 65535);
        var input = MakeMouse(NativeMethods.MouseEventFMove
            | NativeMethods.MouseEventFAbsolute
            | NativeMethods.MouseEventFVirtualDesk);
        input.u.mi.dx = (int)normalizedX;
        input.u.mi.dy = (int)normalizedY;
        return input;
    }

    private static NativeMethods.INPUT MakeMouse(uint flags) => new()
    {
        type = NativeMethods.InputMouse,
        u = new NativeMethods.INPUTUNION { mi = new NativeMethods.MOUSEINPUT { dwFlags = flags } },
    };

    private static NativeMethods.INPUT MakeUnicode(char ch, bool keyUp) => new()
    {
        type = NativeMethods.InputKeyboard,
        u = new NativeMethods.INPUTUNION
        {
            ki = new NativeMethods.KEYBDINPUT
            {
                wScan = ch,
                dwFlags = NativeMethods.KeyEventFUnicode | (keyUp ? NativeMethods.KeyEventFKeyUp : 0),
            },
        },
    };

    private static InputSynthesisResult Send(NativeMethods.INPUT[] inputs, string detail)
    {
        var sent = NativeMethods.SendInput((uint)inputs.Length, inputs, System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.INPUT>());
        return new InputSynthesisResult(dispatched: sent == inputs.Length, detail: detail);
    }

    private bool KillSwitchActive()
    {
        try
        {
            return _killSwitchActive();
        }
        catch (Exception)
        {
            return true;
        }
    }
}
