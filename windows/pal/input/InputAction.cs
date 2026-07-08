// Advisory-vs-non-bypassable input action classification (R17).
//
// Ported from OpenBurnBarComputerUseCore.MacInputAction / MacInspectAction. On macOS
// every synthesized action goes through CGEvent, which the OS gates uniformly. On
// Windows, `SendInput` is bypassable by any same-integrity process (R17), so the
// capability-token gate in front of SendInput is only *advisory*. Actions that COMMIT
// input into the system — activate UI, enter text, press keys, drag/drop — are
// therefore NON-BYPASSABLE: they must route through the ViGEm virtual-HID device where
// the gate is enforced structurally (the sink is unreachable except through the gate).
// Actions that merely reposition the pointer or observe state are ADVISORY: lower
// consequence, allowed via SendInput with an advisory audit record.

using System;
using System.Collections.Generic;

namespace OpenBurnBar.Pal.Input;

/// <summary>
/// The computer-use input action kinds this path dispatches. Names + audit-kind
/// strings mirror <c>MacInputAction.Kind</c> / <c>MacInspectAction.Kind</c> in
/// OpenBurnBarComputerUseCore so a capability token minted for the macOS engine
/// (whose <c>allowedActionKinds</c> carry the same strings) verifies unchanged here.
/// </summary>
public enum InputActionKind
{
    /// <summary>Left/primary button click at a display point. Activates UI.</summary>
    Click,

    /// <summary>Type a literal string. Enters text (could be a password/command).</summary>
    Type,

    /// <summary>Press a single named key.</summary>
    Key,

    /// <summary>Send a modifier+key shortcut.</summary>
    Shortcut,

    /// <summary>Press-move-release drag from one point to another.</summary>
    DragDrop,

    /// <summary>Wheel/trackpad scroll at a point. View change only — advisory.</summary>
    Scroll,

    /// <summary>Reposition the pointer without pressing. Advisory.</summary>
    PointerMove,

    /// <summary>Click at the current pointer position. Activates UI — non-bypassable.</summary>
    PointerClick,

    /// <summary>Read-only accessibility inspection of the element under a point. Advisory.</summary>
    Inspect,
}

/// <summary>
/// Which physical route a classified action takes.
/// </summary>
public enum InputDispatchRoute
{
    /// <summary>Win32 <c>SendInput</c>. The capability-token gate here is advisory only:
    /// a same-integrity process can call <c>SendInput</c> directly, bypassing it (R17).</summary>
    Advisory,

    /// <summary>The ViGEmBus virtual-HID device. The capability-token gate is enforced
    /// structurally — the sink is only ever reached through <see cref="VirtualHidInputGate"/>.</summary>
    NonBypassable,
}

/// <summary>
/// How a dispatched action was authorized, recorded on every audit entry.
/// </summary>
public enum InputDispatchAuthorization
{
    /// <summary>A valid, signed, unexpired, unreplayed capability token was verified
    /// BEFORE dispatch (the non-bypassable route).</summary>
    CapabilityTokenEnforced,

    /// <summary>Advisory route: logged and dispatched via SendInput without a hard token
    /// gate (a same-integrity process could bypass the gate anyway, R17).</summary>
    Advisory,
}

/// <summary>
/// Maps an <see cref="InputActionKind"/> to its dispatch route and stable audit kind.
/// This is the advisory-vs-non-bypassable classification, isolated as a pure function
/// so every branch is unit-tested from a fixture.
/// </summary>
public static class InputActionClassifier
{
    /// <summary>
    /// Classify an action. Anything that commits input (activation / text / keys /
    /// drag-drop) is <see cref="InputDispatchRoute.NonBypassable"/>; pure navigation or
    /// observation (pointer move / scroll / read-only inspect) is
    /// <see cref="InputDispatchRoute.Advisory"/>.
    /// </summary>
    public static InputDispatchRoute Classify(InputActionKind kind) => kind switch
    {
        InputActionKind.Click => InputDispatchRoute.NonBypassable,
        InputActionKind.Type => InputDispatchRoute.NonBypassable,
        InputActionKind.Key => InputDispatchRoute.NonBypassable,
        InputActionKind.Shortcut => InputDispatchRoute.NonBypassable,
        InputActionKind.DragDrop => InputDispatchRoute.NonBypassable,
        InputActionKind.PointerClick => InputDispatchRoute.NonBypassable,
        InputActionKind.Scroll => InputDispatchRoute.Advisory,
        InputActionKind.PointerMove => InputDispatchRoute.Advisory,
        InputActionKind.Inspect => InputDispatchRoute.Advisory,
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "Unknown input action kind."),
    };

    /// <summary>True when the action must route through the ViGEm virtual-HID device.</summary>
    public static bool IsNonBypassable(InputActionKind kind) =>
        Classify(kind) == InputDispatchRoute.NonBypassable;

    /// <summary>
    /// Stable audit-kind string, byte-identical to <c>ComputerUseAction.auditKind</c> on
    /// macOS ("mac.input.&lt;kind&gt;" / "mac.inspect.accessibility"). This is the string a
    /// capability token's <c>allowedActionKinds</c> is matched against.
    /// </summary>
    public static string AuditKind(InputActionKind kind) => kind switch
    {
        InputActionKind.Click => "mac.input.click",
        InputActionKind.Type => "mac.input.type",
        InputActionKind.Key => "mac.input.key",
        InputActionKind.Shortcut => "mac.input.shortcut",
        InputActionKind.DragDrop => "mac.input.drag_drop",
        InputActionKind.Scroll => "mac.input.scroll",
        InputActionKind.PointerMove => "mac.input.pointer_move",
        InputActionKind.PointerClick => "mac.input.pointer_click",
        InputActionKind.Inspect => "mac.inspect.accessibility",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "Unknown input action kind."),
    };
}

/// <summary>
/// A normalized input report — the concrete payload a virtual-HID / SendInput sink
/// executes. Mirrors <c>MacInputAction</c> (display-space coordinates, button, text,
/// key, modifiers) so the dispatcher never sees a platform type.
/// </summary>
public sealed class VirtualHidInputReport
{
    public VirtualHidInputReport(
        InputActionKind kind,
        int? x = null,
        int? y = null,
        int? endX = null,
        int? endY = null,
        int? deltaX = null,
        int? deltaY = null,
        int mouseButton = 0,
        string? text = null,
        string? key = null,
        IReadOnlyList<string>? modifiers = null)
    {
        Kind = kind;
        X = x;
        Y = y;
        EndX = endX;
        EndY = endY;
        DeltaX = deltaX;
        DeltaY = deltaY;
        MouseButton = mouseButton;
        Text = text;
        Key = key;
        Modifiers = modifiers ?? Array.Empty<string>();
    }

    public InputActionKind Kind { get; }
    public int? X { get; }
    public int? Y { get; }
    public int? EndX { get; }
    public int? EndY { get; }
    public int? DeltaX { get; }
    public int? DeltaY { get; }
    public int MouseButton { get; }
    public string? Text { get; }
    public string? Key { get; }
    public IReadOnlyList<string> Modifiers { get; }
}

/// <summary>
/// A gate-and-dispatch request: the action, the capability-token action-kind string it
/// must be authorized against, and the concrete report to execute. Build with
/// <see cref="For"/> so the capability action-kind defaults to the canonical audit kind.
/// </summary>
public sealed class VirtualHidInputRequest
{
    public VirtualHidInputRequest(VirtualHidInputReport report, string? capabilityActionKind = null)
    {
        Report = report ?? throw new ArgumentNullException(nameof(report));
        CapabilityActionKind = string.IsNullOrWhiteSpace(capabilityActionKind)
            ? InputActionClassifier.AuditKind(report.Kind)
            : capabilityActionKind!;
    }

    public VirtualHidInputReport Report { get; }
    public InputActionKind Kind => Report.Kind;

    /// <summary>The action-kind string a capability token is matched against
    /// (defaults to <see cref="InputActionClassifier.AuditKind"/>).</summary>
    public string CapabilityActionKind { get; }

    public static VirtualHidInputRequest For(VirtualHidInputReport report) => new(report);
}
