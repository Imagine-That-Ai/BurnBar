// IInputSynthesizer over user32 SendInput.
//
// R17 (master plan § risk register): on Windows, SendInput makes the
// capability-token gate ADVISORY — any process running at the SAME integrity
// level as the agent can synthesize identical input, so a token cannot make a
// SendInput action non-bypassable, and SendInput cannot reach the secure desktop
// / UAC / lock screen at all. Therefore:
//   * <see cref="RoutesThroughSignedDriver"/> is false here, and
//   * non-bypassable actions (secure-desktop / cross-integrity / lock-screen)
//     MUST route through a signed virtual-HID driver — ViGEm v1, WHQL driver
//     v1.1 — which advertises RoutesThroughSignedDriver = true. The dispatcher
//     refuses a non-bypassable action that only this advisory synthesizer serves.
//
// This class is Windows-only at runtime (SendInput). It Roslyn-compiles on the
// macOS authoring host; the live injection proof is a Windows dev-host task.

using System;
using System.Runtime.Versioning;
using OpenBurnBar.ComputerUse.Core.Adapters;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Windows.Interop;

namespace OpenBurnBar.ComputerUse.Windows;

/// <summary>Advisory desktop input synthesizer backed by user32 SendInput.</summary>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class SendInputInputSynthesizer : IInputSynthesizer
{
    /// <summary>False: SendInput is advisory + same-integrity-bypassable (R17).</summary>
    public bool RoutesThroughSignedDriver => false;

    public InputSynthesisResult Synthesize(MacInputAction action)
    {
        switch (action.ActionKind)
        {
            case MacInputAction.Kind.Click:
                return ClickAt(action.DisplayX, action.DisplayY, action.MouseButton);
            case MacInputAction.Kind.PointerClick:
                return ClickCurrent(action.MouseButton);
            case MacInputAction.Kind.PointerMove:
                return MoveTo(action.DisplayX, action.DisplayY);
            case MacInputAction.Kind.Type:
                return TypeText(action.Text);
            case MacInputAction.Kind.Scroll:
                if (action.DisplayX is not { } scrollX || action.DisplayY is not { } scrollY)
                {
                    return new InputSynthesisResult(dispatched: false, detail: "missing_coordinates");
                }

                var scrollDeltaX = action.DeltaX ?? ((action.DragEndX ?? scrollX) - scrollX);
                var scrollDeltaY = action.DeltaY ?? ((action.DragEndY ?? (scrollY - 600)) - scrollY);
                return Scroll(scrollX, scrollY, scrollDeltaX, scrollDeltaY);
            case MacInputAction.Kind.Key:
                return Key(action.Key);
            case MacInputAction.Kind.Shortcut:
                return Shortcut(action.Key, action.Modifiers);
            case MacInputAction.Kind.DragDrop:
                return DragDrop(action.DisplayX, action.DisplayY, action.DragEndX, action.DragEndY, action.MouseButton);
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

        if (!IsWithinVirtualScreen(x.Value, y.Value))
        {
            return new InputSynthesisResult(dispatched: false, detail: "out_of_bounds");
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

        if (!IsWithinVirtualScreen(x.Value, y.Value))
        {
            return new InputSynthesisResult(dispatched: false, detail: "out_of_bounds");
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

    private static InputSynthesisResult ClickCurrent(int mouseButton)
    {
        var (down, up) = MouseButtonFlags(mouseButton);
        return Send(new[] { MakeMouse(down), MakeMouse(up) }, "pointer_click");
    }

    private static InputSynthesisResult Scroll(int? x, int? y, int deltaX, int deltaY)
    {
        if ((x is null) != (y is null))
        {
            return new InputSynthesisResult(dispatched: false, detail: "missing_coordinates");
        }

        var inputs = new System.Collections.Generic.List<NativeMethods.INPUT>();
        if (x is not null && y is not null)
        {
            if (!IsWithinVirtualScreen(x.Value, y.Value))
            {
                return new InputSynthesisResult(dispatched: false, detail: "out_of_bounds");
            }

            inputs.Add(MakeAbsoluteMove(x.Value, y.Value));
        }

        if (deltaX == 0 && deltaY == 0)
        {
            return new InputSynthesisResult(dispatched: false, detail: "empty_scroll");
        }

        if (deltaY != 0)
        {
            var wheel = MakeMouse(NativeMethods.MouseEventFWheel);
            wheel.u.mi.mouseData = unchecked((uint)deltaY);
            inputs.Add(wheel);
        }

        if (deltaX != 0)
        {
            var wheel = MakeMouse(NativeMethods.MouseEventFHWheel);
            wheel.u.mi.mouseData = unchecked((uint)deltaX);
            inputs.Add(wheel);
        }

        return inputs.Count == 0
            ? new InputSynthesisResult(dispatched: false, detail: "empty_scroll")
            : Send(inputs.ToArray(), "scroll");
    }

    private static InputSynthesisResult TypeText(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return new InputSynthesisResult(dispatched: false, detail: "empty_text");
        }

        var inputs = new NativeMethods.INPUT[text.Length * 2];
        for (var i = 0; i < text.Length; i++)
        {
            inputs[i * 2] = MakeUnicode(text[i], keyUp: false);
            inputs[(i * 2) + 1] = MakeUnicode(text[i], keyUp: true);
        }

        return Send(inputs, "type");
    }

    private static NativeMethods.INPUT MakeAbsoluteMove(int displayX, int displayY)
    {
        var left = NativeMethods.GetSystemMetrics(NativeMethods.SmXVirtualScreen);
        var top = NativeMethods.GetSystemMetrics(NativeMethods.SmYVirtualScreen);
        var width = Math.Max(1, NativeMethods.GetSystemMetrics(NativeMethods.SmCxVirtualScreen));
        var height = Math.Max(1, NativeMethods.GetSystemMetrics(NativeMethods.SmCyVirtualScreen));
        var input = MakeMouse(NativeMethods.MouseEventFMove
            | NativeMethods.MouseEventFAbsolute
            | NativeMethods.MouseEventFVirtualDesk);
        input.u.mi.dx = NormalizeAbsolute(displayX, left, width);
        input.u.mi.dy = NormalizeAbsolute(displayY, top, height);
        return input;
    }

    private static int NormalizeAbsolute(int coordinate, int origin, int extent)
    {
        var relative = (long)coordinate - origin;
        return extent <= 1 ? 0 : (int)Math.Round(relative * 65535.0 / (extent - 1));
    }

    private static bool IsWithinVirtualScreen(int displayX, int displayY)
    {
        var left = NativeMethods.GetSystemMetrics(NativeMethods.SmXVirtualScreen);
        var top = NativeMethods.GetSystemMetrics(NativeMethods.SmYVirtualScreen);
        var width = Math.Max(1, NativeMethods.GetSystemMetrics(NativeMethods.SmCxVirtualScreen));
        var height = Math.Max(1, NativeMethods.GetSystemMetrics(NativeMethods.SmCyVirtualScreen));
        return displayX >= left
            && displayX < (long)left + width
            && displayY >= top
            && displayY < (long)top + height;
    }

    private static InputSynthesisResult DragDrop(int? startX, int? startY, int? endX, int? endY, int mouseButton)
    {
        if (startX is null || startY is null || endX is null || endY is null)
        {
            return new InputSynthesisResult(dispatched: false, detail: "missing_coordinates");
        }

        if (!IsWithinVirtualScreen(startX.Value, startY.Value)
            || !IsWithinVirtualScreen(endX.Value, endY.Value))
        {
            return new InputSynthesisResult(dispatched: false, detail: "out_of_bounds");
        }

        var (down, up) = MouseButtonFlags(mouseButton);
        return Send(new[]
        {
            MakeAbsoluteMove(startX.Value, startY.Value),
            MakeMouse(down),
            MakeAbsoluteMove(endX.Value, endY.Value),
            MakeMouse(up),
        }, "drag_drop");
    }

    private static InputSynthesisResult Key(string? key)
    {
        if (!TryVirtualKey(key, out ushort virtualKey, out ushort implicitModifiers))
        {
            return new InputSynthesisResult(dispatched: false, detail: "unsupported_key");
        }

        return Send(KeyChord(virtualKey, implicitModifiers), "key");
    }

    private static InputSynthesisResult Shortcut(string? key, System.Collections.Generic.IReadOnlyList<string>? modifiers)
    {
        if (!TryVirtualKey(key, out ushort virtualKey, out ushort implicitModifiers))
        {
            return new InputSynthesisResult(dispatched: false, detail: "unsupported_key");
        }

        ushort modifierMask = implicitModifiers;
        if (modifiers is not null)
        {
            foreach (var modifier in modifiers)
            {
                if (!TryModifierMask(modifier, out ushort mask))
                {
                    return new InputSynthesisResult(dispatched: false, detail: "unsupported_modifier");
                }

                modifierMask |= mask;
            }
        }

        return Send(KeyChord(virtualKey, modifierMask), "shortcut");
    }

    private static NativeMethods.INPUT[] KeyChord(ushort virtualKey, ushort modifierMask)
    {
        var keys = new System.Collections.Generic.List<ushort>();
        AddModifier(keys, modifierMask, 1, 0x10); // shift
        AddModifier(keys, modifierMask, 2, 0x11); // ctrl
        AddModifier(keys, modifierMask, 4, 0x12); // alt
        AddModifier(keys, modifierMask, 8, 0x5B); // win

        var inputs = new System.Collections.Generic.List<NativeMethods.INPUT>();
        foreach (var modifier in keys)
        {
            inputs.Add(MakeVirtualKey(modifier, keyUp: false));
        }

        inputs.Add(MakeVirtualKey(virtualKey, keyUp: false));
        inputs.Add(MakeVirtualKey(virtualKey, keyUp: true));
        for (var i = keys.Count - 1; i >= 0; i--)
        {
            inputs.Add(MakeVirtualKey(keys[i], keyUp: true));
        }

        return inputs.ToArray();
    }

    private static void AddModifier(System.Collections.Generic.List<ushort> keys, ushort mask, ushort bit, ushort virtualKey)
    {
        if ((mask & bit) != 0)
        {
            keys.Add(virtualKey);
        }
    }

    private static bool TryModifierMask(string? modifier, out ushort mask)
    {
        mask = modifier?.Trim().ToLowerInvariant() switch
        {
            "shift" => 1,
            "ctrl" or "control" => 2,
            "alt" or "option" => 4,
            "win" or "windows" or "command" or "cmd" => 8,
            _ => 0,
        };
        return mask != 0;
    }

    private static bool TryVirtualKey(string? key, out ushort virtualKey, out ushort implicitModifiers)
    {
        virtualKey = 0;
        implicitModifiers = 0;
        if (string.IsNullOrWhiteSpace(key))
        {
            return false;
        }

        var normalized = key.Trim().ToLowerInvariant();
        virtualKey = normalized switch
        {
            "backspace" => 0x08,
            "tab" => 0x09,
            "enter" or "return" => 0x0D,
            "escape" or "esc" => 0x1B,
            "space" => 0x20,
            "pageup" or "page_up" => 0x21,
            "pagedown" or "page_down" => 0x22,
            "end" => 0x23,
            "home" => 0x24,
            "left" or "arrowleft" => 0x25,
            "up" or "arrowup" => 0x26,
            "right" or "arrowright" => 0x27,
            "down" or "arrowdown" => 0x28,
            "insert" => 0x2D,
            "delete" or "del" => 0x2E,
            _ => 0,
        };
        if (virtualKey != 0)
        {
            return true;
        }

        if (normalized.Length >= 2 && normalized[0] == 'f'
            && int.TryParse(normalized.AsSpan(1), out var function) && function is >= 1 and <= 24)
        {
            virtualKey = (ushort)(0x70 + function - 1);
            return true;
        }

        if (key.Trim().Length == 1)
        {
            short scan = NativeMethods.VkKeyScanW(key.Trim()[0]);
            if (scan != -1)
            {
                virtualKey = (ushort)(scan & 0xFF);
                implicitModifiers = (ushort)((scan >> 8) & 0x07);
                return true;
            }
        }

        return false;
    }

    private static (uint Down, uint Up) MouseButtonFlags(int mouseButton) => mouseButton == 1
        ? (NativeMethods.MouseEventFRightDown, NativeMethods.MouseEventFRightUp)
        : (NativeMethods.MouseEventFLeftDown, NativeMethods.MouseEventFLeftUp);

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

    private static InputSynthesisResult Send(NativeMethods.INPUT[] inputs, string detail)
    {
        var sent = NativeMethods.SendInput((uint)inputs.Length, inputs, System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.INPUT>());
        return new InputSynthesisResult(dispatched: sent == inputs.Length, detail: detail);
    }
}
