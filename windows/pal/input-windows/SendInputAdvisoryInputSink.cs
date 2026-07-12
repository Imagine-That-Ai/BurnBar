// The ADVISORY sink (R17), backed by Win32 SendInput.
//
// Only advisory, non-committing actions (pointer move, scroll) reach this sink — the gate
// routes every input-committing action to ViGEm instead. The capability-token gate in front
// of SendInput is advisory by nature (a same-integrity process can call SendInput directly),
// which is precisely why nothing security-critical rides this route.

using System;
using System.Runtime.Versioning;
using OpenBurnBar.Pal.Input;
using OpenBurnBar.Pal.Input.Windows.Interop;

namespace OpenBurnBar.Pal.Input.Windows;

/// <summary>SendInput-backed advisory sink. Windows-only.</summary>
[SupportedOSPlatform("windows")]
public sealed class SendInputAdvisoryInputSink : IVirtualHidInputSink
{
    public InputDispatchRoute Route => InputDispatchRoute.Advisory;

    public VirtualHidSinkOutcome Submit(VirtualHidInputReport report)
    {
        if (report is null)
        {
            return VirtualHidSinkOutcome.Failure("null report");
        }

        SendInputNative.Input input;
        switch (report.Kind)
        {
            case InputActionKind.PointerMove:
                input = MouseMove(report.X ?? 0, report.Y ?? 0);
                break;
            case InputActionKind.Scroll:
                input = MouseWheel(report.DeltaX ?? 0, report.DeltaY ?? 0);
                break;
            default:
                // Anything else is either input-committing (routed to ViGEm) or read-only
                // (Inspect → served by the UIA inspector). This sink does not synthesize it.
                return VirtualHidSinkOutcome.Failure(
                    $"advisory sink only synthesizes pointer-move/scroll; '{report.Kind}' is not an advisory input action");
        }

        var sent = SendInputNative.SendInput(1, new[] { input }, System.Runtime.InteropServices.Marshal.SizeOf<SendInputNative.Input>());
        return sent == 1
            ? VirtualHidSinkOutcome.Success
            : VirtualHidSinkOutcome.Failure("SendInput did not inject the event");
    }

    private static SendInputNative.Input MouseMove(int x, int y) => new()
    {
        type = SendInputNative.InputMouse,
        mi = new SendInputNative.MouseInput
        {
            dx = x,
            dy = y,
            dwFlags = SendInputNative.MouseeventfMove | SendInputNative.MouseeventfAbsolute | SendInputNative.MouseeventfVirtualdesk,
        },
    };

    private static SendInputNative.Input MouseWheel(int deltaX, int deltaY)
    {
        // Vertical wheel when a Y delta is present; horizontal otherwise.
        var vertical = deltaY != 0 || deltaX == 0;
        return new SendInputNative.Input
        {
            type = SendInputNative.InputMouse,
            mi = new SendInputNative.MouseInput
            {
                mouseData = unchecked((uint)(vertical ? deltaY : deltaX)),
                dwFlags = vertical ? SendInputNative.MouseeventfWheel : SendInputNative.MouseeventfHwheel,
            },
        };
    }
}
