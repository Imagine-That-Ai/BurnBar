// The input sink seam — the platform edge the portable path dispatches into.
//
// Two implementations live in the net8.0-windows adapter (OpenBurnBar.Pal.Input.Windows):
//   • ViGEmVirtualHidInputSink   — the NON-BYPASSABLE route (ViGEmBus virtual HID).
//   • SendInputAdvisoryInputSink — the ADVISORY route (Win32 SendInput).
// The sink is intentionally dumb: it receives an ALREADY-AUTHORIZED report. It is only ever
// reached through VirtualHidInputDispatcher after the gate authorizes — that is the R17
// structural guarantee, proven by a spy-sink test on macOS.

using System;

namespace OpenBurnBar.Pal.Input;

/// <summary>The result of submitting a report to a sink.</summary>
public sealed class VirtualHidSinkOutcome
{
    private VirtualHidSinkOutcome(bool ok, string? error)
    {
        Ok = ok;
        Error = error;
    }

    public bool Ok { get; }
    public string? Error { get; }

    public static VirtualHidSinkOutcome Success { get; } = new(true, null);
    public static VirtualHidSinkOutcome Failure(string error) => new(false, error);
}

/// <summary>An input sink. Implementations translate a normalized report into concrete OS
/// input (ViGEm reports / SendInput) and never gate — gating already happened.</summary>
public interface IVirtualHidInputSink
{
    /// <summary>Which route this sink serves. Used by the dispatcher to pick the sink and
    /// asserted to match the gate's route.</summary>
    InputDispatchRoute Route { get; }

    VirtualHidSinkOutcome Submit(VirtualHidInputReport report);
}
