// Typed Computer-Use action descriptors.
//
// Port of ComputerUseActionDescriptor.swift. The gate + dispatcher convert a
// loosely-typed tool invocation into one of these, run scope + approval + deny
// gates, then convert to the concrete platform payload (CDP JSON-RPC, SendInput,
// UIA, clipboard). Keeping the descriptors pure keeps the gate free of any
// platform dependency, so it lives in this portable core.

using System;
using System.Collections.Generic;
using System.Globalization;
using OpenBurnBar.ComputerUse.Core.Crypto;

namespace OpenBurnBar.ComputerUse.Core.Gate;

/// <summary>The five action lanes the capability gate branches on.</summary>
public enum ActionCategory
{
    Browser,
    MacInput,
    MacInspect,
    PhoneIntent,
    RemoteClipboard,
}

/// <summary>Base type for every typed Computer-Use action descriptor.</summary>
public abstract class ComputerUseAction
{
    /// <summary>Which lane the gate treats this action as.</summary>
    public abstract ActionCategory Category { get; }

    /// <summary>Stable <c>action.kind</c> discriminator recorded in the audit chain.</summary>
    public abstract string AuditKind { get; }

    /// <summary>Terse human-readable summary surfaced in the approval sheet + audit.</summary>
    public abstract string ExecutableSummary(ScopeContextSummary? context = null);

    /// <summary>Canonical-JSON map used to hash the action descriptor privately.</summary>
    public abstract CanonicalJsonObject ToCanonicalMap();

    private protected static string Quoted(string value) => $"‘{value}’";

    private protected static string FormatNormalized(double? value)
        => value is { } v ? v.ToString("0.00", CultureInfo.InvariantCulture) : "?";
}

/// <summary>The subset of a scope context used by summaries (host / app labels).</summary>
public sealed class ScopeContextSummary
{
    public ScopeContextSummary(string? url = null, string? bundleId = null)
    {
        Url = url;
        BundleId = bundleId;
    }

    public string? Url { get; }

    public string? BundleId { get; }

    public string? Host()
    {
        if (Url is null || !Uri.TryCreate(Url, UriKind.Absolute, out var parsed))
        {
            return null;
        }

        return string.IsNullOrEmpty(parsed.Host) ? null : parsed.Host;
    }
}

/// <summary>Browser (Path B) action.</summary>
public sealed class BrowserAction : ComputerUseAction
{
    public enum Kind
    {
        Click,
        Fill,
        Goto,
        Key,
        Select,
        Screenshot,
        Extract,
    }

    public BrowserAction(
        Kind kind,
        string? selector = null,
        string? text = null,
        string? url = null,
        string? key = null,
        string? value = null,
        int? positionX = null,
        int? positionY = null,
        int timeoutMillis = 10_000)
    {
        ActionKind = kind;
        Selector = selector;
        Text = text;
        Url = url;
        Key = key;
        Value = value;
        PositionX = positionX;
        PositionY = positionY;
        TimeoutMillis = timeoutMillis;
    }

    public Kind ActionKind { get; }

    public string? Selector { get; }

    public string? Text { get; }

    public string? Url { get; }

    public string? Key { get; }

    public string? Value { get; }

    public int? PositionX { get; }

    public int? PositionY { get; }

    public int TimeoutMillis { get; }

    public override ActionCategory Category => ActionCategory.Browser;

    public override string AuditKind => $"browser.{KindWire(ActionKind)}";

    public override string ExecutableSummary(ScopeContextSummary? context = null)
    {
        var host = context?.Host() ?? "browser";
        return ActionKind switch
        {
            Kind.Click when Selector is not null => $"Click {Quoted(Selector)} on {host}",
            Kind.Click when PositionX is { } x && PositionY is { } y => $"Click at ({x}, {y}) on {host}",
            Kind.Click => $"Click on {host}",
            Kind.Fill => $"Type {Quoted(Text ?? "<text>")} into {Quoted(Selector ?? "<field>")} on {host}",
            Kind.Goto => $"Navigate to {Url ?? "?"}",
            Kind.Key => $"Press {Key ?? "?"} on {host}",
            Kind.Select => $"Select {Quoted(Value ?? "<value>")} in {Quoted(Selector ?? "<field>")} on {host}",
            Kind.Screenshot => $"Screenshot the page on {host}",
            Kind.Extract => $"Extract content of {Quoted(Selector ?? "<root>")} from {host}",
            _ => $"Browser action on {host}",
        };
    }

    public override CanonicalJsonObject ToCanonicalMap() => new CanonicalJsonObject()
        .Set("_lane", "browser")
        .Set("kind", KindWire(ActionKind))
        .Set("selector", Selector)
        .Set("text", Text)
        .Set("url", Url)
        .Set("key", Key)
        .Set("value", Value)
        .Set("positionX", PositionX.HasValue ? PositionX.Value : (object?)null)
        .Set("positionY", PositionY.HasValue ? PositionY.Value : (object?)null)
        .Set("timeoutMillis", TimeoutMillis);

    private static string KindWire(Kind kind) => kind switch
    {
        Kind.Click => "click",
        Kind.Fill => "fill",
        Kind.Goto => "goto",
        Kind.Key => "key",
        Kind.Select => "select",
        Kind.Screenshot => "screenshot",
        Kind.Extract => "extract",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null),
    };
}

/// <summary>Desktop input (Path C) action — synthesized via SendInput / ViGEm.</summary>
public sealed class MacInputAction : ComputerUseAction
{
    public enum Kind
    {
        Click,
        Type,
        Key,
        Shortcut,
        DragDrop,
        Scroll,
        PointerMove,
        PointerClick,
    }

    public MacInputAction(
        Kind kind,
        int? displayX = null,
        int? displayY = null,
        int? dragEndX = null,
        int? dragEndY = null,
        int? deltaX = null,
        int? deltaY = null,
        int mouseButton = 0,
        string? text = null,
        string? key = null,
        IReadOnlyList<string>? modifiers = null)
    {
        ActionKind = kind;
        DisplayX = displayX;
        DisplayY = displayY;
        DragEndX = dragEndX;
        DragEndY = dragEndY;
        DeltaX = deltaX;
        DeltaY = deltaY;
        MouseButton = mouseButton;
        Text = text;
        Key = key;
        Modifiers = modifiers;
    }

    public Kind ActionKind { get; }

    public int? DisplayX { get; }

    public int? DisplayY { get; }

    public int? DragEndX { get; }

    public int? DragEndY { get; }

    public int? DeltaX { get; }

    public int? DeltaY { get; }

    public int MouseButton { get; }

    public string? Text { get; }

    public string? Key { get; }

    public IReadOnlyList<string>? Modifiers { get; }

    /// <summary>
    /// True for actions whose effect must not be same-integrity bypassable. The
    /// Windows dispatcher requires a signed virtual-HID route for these.
    /// </summary>
    public bool RequiresSignedDriver => ActionKind is
        Kind.Click or Kind.Type or Kind.Key or Kind.Shortcut or Kind.DragDrop or Kind.PointerClick;

    public override ActionCategory Category => ActionCategory.MacInput;

    public override string AuditKind => $"mac.input.{KindWire(ActionKind)}";

    public override string ExecutableSummary(ScopeContextSummary? context = null)
    {
        var app = context?.BundleId ?? "desktop";
        return ActionKind switch
        {
            Kind.Click when DisplayX is { } x && DisplayY is { } y => $"Click at ({x}, {y}) in {app}",
            Kind.Click => $"Click in {app}",
            Kind.Type => $"Type {Quoted(Text ?? "<text>")} in {app}",
            Kind.Key => $"Press {Key ?? "?"} in {app}",
            Kind.Shortcut => $"Send shortcut {Combo()} in {app}",
            Kind.DragDrop => $"Drag from ({Coord(DisplayX, DisplayY)}) to ({Coord(DragEndX, DragEndY)}) in {app}",
            Kind.Scroll when DisplayX is { } x && DisplayY is { } y => $"Scroll at ({x}, {y}) in {app}",
            Kind.Scroll => $"Scroll in {app}",
            Kind.PointerMove => $"Move pointer in {app}",
            Kind.PointerClick => $"Click current pointer in {app}",
            _ => $"Input in {app}",
        };
    }

    public override CanonicalJsonObject ToCanonicalMap() => new CanonicalJsonObject()
        .Set("_lane", "mac.input")
        .Set("kind", KindWire(ActionKind))
        .Set("displayX", DisplayX.HasValue ? DisplayX.Value : (object?)null)
        .Set("displayY", DisplayY.HasValue ? DisplayY.Value : (object?)null)
        .Set("dragEndX", DragEndX.HasValue ? DragEndX.Value : (object?)null)
        .Set("dragEndY", DragEndY.HasValue ? DragEndY.Value : (object?)null)
        .Set("deltaX", DeltaX.HasValue ? DeltaX.Value : (object?)null)
        .Set("deltaY", DeltaY.HasValue ? DeltaY.Value : (object?)null)
        .Set("mouseButton", MouseButton)
        .Set("text", Text)
        .Set("key", Key)
        .Set("modifiers", Modifiers);

    private string Combo()
    {
        var parts = new List<string>();
        if (Modifiers is not null)
        {
            parts.AddRange(Modifiers);
        }

        if (Key is not null)
        {
            parts.Add(Key);
        }

        return string.Join("+", parts);
    }

    private static string Coord(int? x, int? y)
        => $"{(x.HasValue ? x.Value.ToString(CultureInfo.InvariantCulture) : "?")},{(y.HasValue ? y.Value.ToString(CultureInfo.InvariantCulture) : "?")}";

    private static string KindWire(Kind kind) => kind switch
    {
        Kind.Click => "click",
        Kind.Type => "type",
        Kind.Key => "key",
        Kind.Shortcut => "shortcut",
        Kind.DragDrop => "drag_drop",
        Kind.Scroll => "scroll",
        Kind.PointerMove => "pointer_move",
        Kind.PointerClick => "pointer_click",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null),
    };
}

/// <summary>Desktop inspect (Path C, read-only) action — UIA point probe.</summary>
public sealed class MacInspectAction : ComputerUseAction
{
    public enum Kind
    {
        Accessibility,
    }

    public MacInspectAction(Kind kind, int? displayX = null, int? displayY = null)
    {
        ActionKind = kind;
        DisplayX = displayX;
        DisplayY = displayY;
    }

    public Kind ActionKind { get; }

    public int? DisplayX { get; }

    public int? DisplayY { get; }

    public override ActionCategory Category => ActionCategory.MacInspect;

    public override string AuditKind => "mac.inspect.accessibility";

    public override string ExecutableSummary(ScopeContextSummary? context = null)
    {
        var app = context?.BundleId ?? "desktop";
        return DisplayX is { } x && DisplayY is { } y
            ? $"Inspect element at ({x}, {y}) in {app}"
            : $"Inspect frontmost window in {app}";
    }

    public override CanonicalJsonObject ToCanonicalMap() => new CanonicalJsonObject()
        .Set("_lane", "mac.inspect")
        .Set("kind", "accessibility")
        .Set("displayX", DisplayX.HasValue ? DisplayX.Value : (object?)null)
        .Set("displayY", DisplayY.HasValue ? DisplayY.Value : (object?)null);
}

/// <summary>Remote-clipboard (Path D) action — split from the broad remote-control grant.</summary>
public sealed class RemoteClipboardAction : ComputerUseAction
{
    public enum Kind
    {
        PasteToMac,
        GrabFromMac,
    }

    public RemoteClipboardAction(Kind kind, string requestId, string contentType, int maxBytes, int? byteCount = null)
    {
        ActionKind = kind;
        RequestId = requestId ?? throw new ArgumentNullException(nameof(requestId));
        ContentType = contentType ?? throw new ArgumentNullException(nameof(contentType));
        MaxBytes = maxBytes;
        ByteCount = byteCount;
    }

    public Kind ActionKind { get; }

    public string RequestId { get; }

    public string ContentType { get; }

    public int MaxBytes { get; }

    public int? ByteCount { get; }

    public override ActionCategory Category => ActionCategory.RemoteClipboard;

    public override string AuditKind => $"clipboard.{KindWire(ActionKind)}";

    public override string ExecutableSummary(ScopeContextSummary? context = null)
    {
        var app = context?.BundleId ?? "desktop";
        return ActionKind switch
        {
            Kind.PasteToMac => $"Paste phone clipboard text into {app}",
            Kind.GrabFromMac => $"Copy desktop clipboard text from {app}",
            _ => $"Clipboard action in {app}",
        };
    }

    public override CanonicalJsonObject ToCanonicalMap() => new CanonicalJsonObject()
        .Set("_lane", "clipboard")
        .Set("kind", KindWire(ActionKind))
        .Set("requestId", RequestId)
        .Set("contentType", ContentType)
        .Set("byteCount", ByteCount.HasValue ? ByteCount.Value : (object?)null)
        .Set("maxBytes", MaxBytes);

    private static string KindWire(Kind kind) => kind switch
    {
        Kind.PasteToMac => "paste_to_mac",
        Kind.GrabFromMac => "grab_from_mac",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null),
    };
}

/// <summary>Phone-control (Path D) intent — a paired operator driving the desktop.</summary>
public sealed class PhoneControlIntent : ComputerUseAction
{
    public enum Kind
    {
        Tap,
        DragStart,
        DragMove,
        DragEnd,
        Type,
        Shortcut,
        Scroll,
        Panic,
        ContextTarget,
    }

    public PhoneControlIntent(
        Kind kind,
        double? normalizedX = null,
        double? normalizedY = null,
        double? normalizedX2 = null,
        double? normalizedY2 = null,
        string? text = null,
        string? key = null,
        IReadOnlyList<string>? modifiers = null)
    {
        ActionKind = kind;
        NormalizedX = normalizedX;
        NormalizedY = normalizedY;
        NormalizedX2 = normalizedX2;
        NormalizedY2 = normalizedY2;
        Text = text;
        Key = key;
        Modifiers = modifiers;
    }

    public Kind ActionKind { get; }

    public double? NormalizedX { get; }

    public double? NormalizedY { get; }

    public double? NormalizedX2 { get; }

    public double? NormalizedY2 { get; }

    public string? Text { get; }

    public string? Key { get; }

    public IReadOnlyList<string>? Modifiers { get; }

    public override ActionCategory Category => ActionCategory.PhoneIntent;

    public override string AuditKind => $"phone.{KindWire(ActionKind)}";

    public override string ExecutableSummary(ScopeContextSummary? context = null)
    {
        var app = context?.BundleId ?? "desktop";
        return ActionKind switch
        {
            Kind.Tap => $"Phone tap at ({FormatNormalized(NormalizedX)}, {FormatNormalized(NormalizedY)}) on {app}",
            Kind.DragStart => $"Phone drag start at ({FormatNormalized(NormalizedX)}, {FormatNormalized(NormalizedY)})",
            Kind.DragMove => $"Phone drag move to ({FormatNormalized(NormalizedX)}, {FormatNormalized(NormalizedY)})",
            Kind.DragEnd => $"Phone drag end at ({FormatNormalized(NormalizedX)}, {FormatNormalized(NormalizedY)})",
            Kind.Type => $"Phone type {Quoted(Text ?? "<text>")} in {app}",
            Kind.Shortcut => $"Phone shortcut {Combo()} in {app}",
            Kind.Scroll => $"Phone scroll on {app}",
            Kind.Panic => "Phone panic halt",
            Kind.ContextTarget => $"Phone context handoff for instruction {Quoted(Text ?? string.Empty)} on {app}",
            _ => $"Phone intent on {app}",
        };
    }

    public override CanonicalJsonObject ToCanonicalMap() => new CanonicalJsonObject()
        .Set("_lane", "phone")
        .Set("kind", KindWire(ActionKind))
        .Set("normalizedX", NormalizedX.HasValue ? NormalizedX.Value : (object?)null)
        .Set("normalizedY", NormalizedY.HasValue ? NormalizedY.Value : (object?)null)
        .Set("normalizedX2", NormalizedX2.HasValue ? NormalizedX2.Value : (object?)null)
        .Set("normalizedY2", NormalizedY2.HasValue ? NormalizedY2.Value : (object?)null)
        .Set("text", Text)
        .Set("key", Key)
        .Set("modifiers", Modifiers);

    private string Combo()
    {
        var parts = new List<string>();
        if (Modifiers is not null)
        {
            parts.AddRange(Modifiers);
        }

        if (Key is not null)
        {
            parts.Add(Key);
        }

        return string.Join("+", parts);
    }

    private static string KindWire(Kind kind) => kind switch
    {
        Kind.Tap => "tap",
        Kind.DragStart => "drag_start",
        Kind.DragMove => "drag_move",
        Kind.DragEnd => "drag_end",
        Kind.Type => "type",
        Kind.Shortcut => "shortcut",
        Kind.Scroll => "scroll",
        Kind.Panic => "panic",
        Kind.ContextTarget => "context_target",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null),
    };
}
