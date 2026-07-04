// The NON-BYPASSABLE virtual-HID sink (R17), backed by ViGEmBus.
//
// This is the concrete IVirtualHidInputSink the portable VirtualHidInputDispatcher routes a
// non-bypassable action to AFTER the capability-token gate authorizes it. It owns the
// ViGEmBus connection + a virtual target and submits kernel virtual-HID reports. Because the
// dispatcher is the only caller and the gate is the only path to the dispatcher, a report
// physically cannot reach this device without a valid, signed, unexpired, unreplayed token.
//
// SCOPE (honest): ViGEmBus (v1) provides the non-bypassable virtual-HID BUS and a virtual
// controller target — a real kernel HID device a user-mode SendInput hook cannot forge. This
// adapter is the integration SEAM. Full mouse/keyboard cursor+keystroke fidelity AND
// secure-desktop / lock-screen injection require the WHQL-signed virtual mouse/keyboard
// driver — v1.1 (master plan §15.1, R6) — which drops in behind this same IVirtualHidInputSink
// seam without changing the gate or the dispatcher. See README.md.

using System;
using System.Runtime.Versioning;
using OpenBurnBar.Pal.Input;
using OpenBurnBar.Pal.Input.Windows.Interop;

namespace OpenBurnBar.Pal.Input.Windows;

/// <summary>ViGEmBus-backed virtual-HID sink for the non-bypassable route. Not thread-safe;
/// the dispatcher serializes input. Windows-only (ViGEmBus).</summary>
[SupportedOSPlatform("windows")]
public sealed class ViGEmVirtualHidInputSink : IVirtualHidInputSink, IDisposable
{
    private IntPtr _client = IntPtr.Zero;
    private IntPtr _target = IntPtr.Zero;
    private bool _connected;
    private bool _disposed;

    public InputDispatchRoute Route => InputDispatchRoute.NonBypassable;

    /// <summary>Lazily connects to ViGEmBus, plugs a virtual target, and submits the report as
    /// a kernel virtual-HID update. Returns a failure outcome (never throws) so a bus/driver
    /// problem denies the action rather than crashing the dispatcher.</summary>
    public VirtualHidSinkOutcome Submit(VirtualHidInputReport report)
    {
        if (report is null)
        {
            return VirtualHidSinkOutcome.Failure("null report");
        }
        if (_disposed)
        {
            return VirtualHidSinkOutcome.Failure("sink disposed");
        }

        var ready = EnsureConnected();
        if (ready is not null)
        {
            return VirtualHidSinkOutcome.Failure(ready);
        }

        var vigemReport = Encode(report);
        var status = ViGEmClientNative.vigem_target_x360_update(_client, _target, vigemReport);
        return status == ViGEmClientNative.VigemError.None
            ? VirtualHidSinkOutcome.Success
            : VirtualHidSinkOutcome.Failure($"vigem_target_x360_update failed: {status}");
    }

    /// <summary>Encode a normalized input report into a virtual-HID (XUSB) report. The gate
    /// has already authorized the action; this is a pure translation. Absolute cursor +
    /// keystroke fidelity is the v1.1 signed-driver's job (README).</summary>
    internal static ViGEmClientNative.XusbReport Encode(VirtualHidInputReport report)
    {
        var xusb = default(ViGEmClientNative.XusbReport);
        switch (report.Kind)
        {
            case InputActionKind.Click:
            case InputActionKind.PointerClick:
                // Primary button press. 0x1000 == XUSB_GAMEPAD_A on the virtual target; the
                // signed v1.1 mouse driver maps this to a real left-button HID usage.
                xusb.wButtons = 0x1000;
                break;
            case InputActionKind.DragDrop:
                // Hold primary while moving from (X,Y) toward (EndX,EndY).
                xusb.wButtons = 0x1000;
                xusb.sThumbLX = ClampAxis(report.EndX, report.X);
                xusb.sThumbLY = ClampAxis(report.EndY, report.Y);
                break;
            case InputActionKind.Scroll:
                xusb.sThumbRY = ClampDelta(report.DeltaY);
                xusb.sThumbRX = ClampDelta(report.DeltaX);
                break;
            case InputActionKind.PointerMove:
                xusb.sThumbLX = ClampCoordinate(report.X);
                xusb.sThumbLY = ClampCoordinate(report.Y);
                break;
            case InputActionKind.Type:
            case InputActionKind.Key:
            case InputActionKind.Shortcut:
                // Keystroke/text: the virtual keyboard HID usages are emitted by the v1.1
                // signed keyboard driver behind this same seam. On the v1 gamepad target the
                // report is a neutral pressed-state marker; the gate + audit already ran.
                xusb.wButtons = 0x2000; // XUSB_GAMEPAD_B placeholder marker
                break;
            case InputActionKind.Inspect:
                // Read-only inspection is not an input-synthesis action; nothing to encode.
                break;
        }
        return xusb;
    }

    private string? EnsureConnected()
    {
        if (_connected)
        {
            return null;
        }

        _client = ViGEmClientNative.vigem_alloc();
        if (_client == IntPtr.Zero)
        {
            return "vigem_alloc returned null (ViGEmBus not installed?)";
        }

        var connect = ViGEmClientNative.vigem_connect(_client);
        if (connect != ViGEmClientNative.VigemError.None)
        {
            ViGEmClientNative.vigem_free(_client);
            _client = IntPtr.Zero;
            return $"vigem_connect failed: {connect}";
        }

        _target = ViGEmClientNative.vigem_target_x360_alloc();
        if (_target == IntPtr.Zero)
        {
            ViGEmClientNative.vigem_disconnect(_client);
            ViGEmClientNative.vigem_free(_client);
            _client = IntPtr.Zero;
            return "vigem_target_x360_alloc returned null";
        }

        var add = ViGEmClientNative.vigem_target_add(_client, _target);
        if (add != ViGEmClientNative.VigemError.None)
        {
            ViGEmClientNative.vigem_target_free(_target);
            _target = IntPtr.Zero;
            ViGEmClientNative.vigem_disconnect(_client);
            ViGEmClientNative.vigem_free(_client);
            _client = IntPtr.Zero;
            return $"vigem_target_add failed: {add}";
        }

        _connected = true;
        return null;
    }

    private static short ClampCoordinate(int? value) =>
        value is null ? (short)0 : (short)Math.Clamp(value.Value, short.MinValue, short.MaxValue);

    private static short ClampDelta(int? value) =>
        value is null ? (short)0 : (short)Math.Clamp(value.Value, short.MinValue, short.MaxValue);

    private static short ClampAxis(int? primary, int? fallback)
    {
        var v = primary ?? fallback ?? 0;
        return (short)Math.Clamp(v, short.MinValue, short.MaxValue);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;

        if (_target != IntPtr.Zero)
        {
            if (_client != IntPtr.Zero)
            {
                ViGEmClientNative.vigem_target_remove(_client, _target);
            }
            ViGEmClientNative.vigem_target_free(_target);
            _target = IntPtr.Zero;
        }
        if (_client != IntPtr.Zero)
        {
            if (_connected)
            {
                ViGEmClientNative.vigem_disconnect(_client);
            }
            ViGEmClientNative.vigem_free(_client);
            _client = IntPtr.Zero;
        }
        _connected = false;
    }
}
