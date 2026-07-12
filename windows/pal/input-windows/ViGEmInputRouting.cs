// Factory that assembles the Windows input path: the portable gate + the two Windows sinks
// (ViGEmBus non-bypassable + SendInput advisory) into a ready VirtualHidInputDispatcher.
//
// The gate, verifier, nonce store, and audit sink are all portable (OpenBurnBar.Pal.Input);
// only the two IVirtualHidInputSink implementations are Windows-native. This is the single
// place the WHQL-signed v1.1 virtual mouse/keyboard driver later swaps in behind
// IVirtualHidInputSink without touching the gate or the dispatcher.

using System;
using System.Runtime.Versioning;
using OpenBurnBar.Pal.Input;

namespace OpenBurnBar.Pal.Input.Windows;

/// <summary>Builds the Windows-backed virtual-HID input dispatcher.</summary>
[SupportedOSPlatform("windows")]
public static class ViGEmInputRouting
{
    /// <summary>Assemble the dispatcher from a verifier + audit sink and the two Windows
    /// sinks. The caller owns the returned <paramref name="nonBypassableSink"/> lifetime
    /// (dispose it on shutdown to unplug the virtual target).</summary>
    public static VirtualHidInputDispatcher CreateDispatcher(
        VirtualHidCapabilityTokenVerifier verifier,
        IInputAuditSink auditSink,
        out ViGEmVirtualHidInputSink nonBypassableSink,
        Func<long>? clockUnixMs = null)
    {
        if (verifier is null)
        {
            throw new ArgumentNullException(nameof(verifier));
        }
        if (auditSink is null)
        {
            throw new ArgumentNullException(nameof(auditSink));
        }

        nonBypassableSink = new ViGEmVirtualHidInputSink();
        var advisorySink = new SendInputAdvisoryInputSink();
        var gate = new VirtualHidInputGate(verifier);
        return new VirtualHidInputDispatcher(gate, auditSink, nonBypassableSink, advisorySink, clockUnixMs);
    }
}
