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
            case MacInputAction.Kind.PointerClick:
                return ClickAt(action.DisplayX, action.DisplayY, action.MouseButton);
            case MacInputAction.Kind.PointerMove:
                return MoveTo(action.DisplayX, action.DisplayY);
            case MacInputAction.Kind.Type:
                return TypeText(action.Text);
            case MacInputAction.Kind.Scroll:
                return Scroll(action.DeltaY ?? 0);
            case MacInputAction.Kind.Key:
            case MacInputAction.Kind.Shortcut:
            case MacInputAction.Kind.DragDrop:
                // These need VK mapping / press-hold-drag sequences finalized on a
                // Windows dev host; the advisory-vs-signed-driver routing decision
                // (R17) gates them regardless.
                return new InputSynthesisResult(dispatched: false, detail: "deferred_dev_host");
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

    private static InputSynthesisResult Scroll(int deltaY)
    {
        var wheel = MakeMouse(NativeMethods.MouseEventFWheel);
        wheel.u.mi.mouseData = unchecked((uint)(deltaY * NativeMethods.WheelDelta));
        return Send(new[] { wheel }, "scroll");
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
        var width = Math.Max(1, NativeMethods.GetSystemMetrics(NativeMethods.SmCxVirtualScreen));
        var height = Math.Max(1, NativeMethods.GetSystemMetrics(NativeMethods.SmCyVirtualScreen));
        var input = MakeMouse(NativeMethods.MouseEventFMove
            | NativeMethods.MouseEventFAbsolute
            | NativeMethods.MouseEventFVirtualDesk);
        input.u.mi.dx = (int)(displayX * 65535.0 / width);
        input.u.mi.dy = (int)(displayY * 65535.0 / height);
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
}
