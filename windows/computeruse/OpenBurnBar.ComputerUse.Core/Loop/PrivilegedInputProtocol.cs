using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.ComputerUse.Core.Adapters;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.KillSwitch;
using OpenBurnBar.ComputerUse.Core.Scope;

namespace OpenBurnBar.ComputerUse.Core.Loop;

public enum PrivilegedInputCommandKind
{
    Invalid,
    Health,
    Dispatch,
}

/// <summary>Bounded wire request accepted by the isolated Windows input broker.</summary>
public sealed class PrivilegedInputCommand
{
    public const int MaximumPayloadBytes = 128 * 1024;
    public const int MaximumTextCharacters = 4 * 1024;

    private PrivilegedInputCommand(
        PrivilegedInputCommandKind kind,
        string? sessionId,
        string? approvalId,
        string? actionId,
        MacInputAction? action,
        string? error)
    {
        Kind = kind;
        SessionId = sessionId;
        ApprovalId = approvalId;
        ActionId = actionId;
        Action = action;
        Error = error;
    }

    public PrivilegedInputCommandKind Kind { get; }
    public string? SessionId { get; }
    public string? ApprovalId { get; }
    public string? ActionId { get; }
    public MacInputAction? Action { get; }
    public string? Error { get; }

    public static byte[] EncodeHealth() => JsonSerializer.SerializeToUtf8Bytes(new { action = "health" });

    public static byte[] EncodeDispatch(
        string sessionId,
        string approvalId,
        string actionId,
        MacInputAction action)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);
        ArgumentException.ThrowIfNullOrWhiteSpace(approvalId);
        ArgumentException.ThrowIfNullOrWhiteSpace(actionId);
        ArgumentNullException.ThrowIfNull(action);
        return JsonSerializer.SerializeToUtf8Bytes(new
        {
            action = "dispatch",
            sessionId,
            approvalId,
            actionId,
            input = new
            {
                kind = ActionKindWire(action.ActionKind),
                displayX = action.DisplayX,
                displayY = action.DisplayY,
                dragEndX = action.DragEndX,
                dragEndY = action.DragEndY,
                deltaX = action.DeltaX,
                deltaY = action.DeltaY,
                mouseButton = action.MouseButton,
                text = action.Text,
                key = action.Key,
                modifiers = action.Modifiers,
            },
        });
    }

    public static PrivilegedInputCommand Parse(ReadOnlySpan<byte> payload)
    {
        if (payload.Length is 0 or > MaximumPayloadBytes)
        {
            return Invalid("payload_size");
        }

        try
        {
            using JsonDocument document = JsonDocument.Parse(payload.ToArray());
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !TryRequiredString(root, "action", 32, out string command))
            {
                return Invalid("invalid_action");
            }

            if (command == "health")
            {
                return new PrivilegedInputCommand(
                    PrivilegedInputCommandKind.Health,
                    null,
                    null,
                    null,
                    null,
                    null);
            }

            if (command != "dispatch"
                || !TryRequiredString(root, "sessionId", 128, out string sessionId)
                || !TryRequiredString(root, "approvalId", 128, out string approvalId)
                || !TryRequiredString(root, "actionId", 128, out string actionId)
                || !root.TryGetProperty("input", out JsonElement input)
                || input.ValueKind != JsonValueKind.Object
                || !TryRequiredString(input, "kind", 32, out string kindText)
                || !TryActionKind(kindText, out MacInputAction.Kind kind))
            {
                return Invalid("invalid_dispatch");
            }

            string? text = OptionalString(input, "text", MaximumTextCharacters, out bool textValid);
            string? key = OptionalString(input, "key", 64, out bool keyValid);
            IReadOnlyList<string>? modifiers = OptionalStrings(input, "modifiers", 8, 16, out bool modifiersValid);
            if (!textValid || !keyValid || !modifiersValid
                || !OptionalInt(input, "displayX", out int? displayX)
                || !OptionalInt(input, "displayY", out int? displayY)
                || !OptionalInt(input, "dragEndX", out int? dragEndX)
                || !OptionalInt(input, "dragEndY", out int? dragEndY)
                || !OptionalInt(input, "deltaX", out int? deltaX)
                || !OptionalInt(input, "deltaY", out int? deltaY)
                || !OptionalInt(input, "mouseButton", out int? mouseButton)
                || mouseButton is < 0 or > 1)
            {
                return Invalid("invalid_input");
            }

            var action = new MacInputAction(
                kind,
                displayX,
                displayY,
                dragEndX,
                dragEndY,
                deltaX,
                deltaY,
                mouseButton ?? 0,
                text,
                key,
                modifiers);
            return new PrivilegedInputCommand(
                PrivilegedInputCommandKind.Dispatch,
                sessionId,
                approvalId,
                actionId,
                action,
                null);
        }
        catch (JsonException)
        {
            return Invalid("invalid_json");
        }
    }

    private static PrivilegedInputCommand Invalid(string error) =>
        new(PrivilegedInputCommandKind.Invalid, null, null, null, null, error);

    private static bool TryRequiredString(
        JsonElement owner,
        string name,
        int maximumLength,
        out string value)
    {
        value = string.Empty;
        if (!owner.TryGetProperty(name, out JsonElement element)
            || element.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = element.GetString()?.Trim() ?? string.Empty;
        return value.Length is > 0
            && value.Length <= maximumLength
            && !value.Any(char.IsControl);
    }

    private static string? OptionalString(
        JsonElement owner,
        string name,
        int maximumLength,
        out bool valid)
    {
        valid = true;
        if (!owner.TryGetProperty(name, out JsonElement element)
            || element.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (element.ValueKind != JsonValueKind.String)
        {
            valid = false;
            return null;
        }

        string? value = element.GetString();
        valid = value is null || value.Length <= maximumLength;
        return valid ? value : null;
    }

    private static IReadOnlyList<string>? OptionalStrings(
        JsonElement owner,
        string name,
        int maximumCount,
        int maximumLength,
        out bool valid)
    {
        valid = true;
        if (!owner.TryGetProperty(name, out JsonElement element)
            || element.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (element.ValueKind != JsonValueKind.Array || element.GetArrayLength() > maximumCount)
        {
            valid = false;
            return null;
        }

        var values = new List<string>();
        foreach (JsonElement item in element.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String
                || item.GetString() is not string value
                || value.Length is 0 || value.Length > maximumLength)
            {
                valid = false;
                return null;
            }
            values.Add(value);
        }
        return values;
    }

    private static bool OptionalInt(JsonElement owner, string name, out int? value)
    {
        value = null;
        if (!owner.TryGetProperty(name, out JsonElement element)
            || element.ValueKind == JsonValueKind.Null)
        {
            return true;
        }

        if (element.ValueKind != JsonValueKind.Number || !element.TryGetInt32(out int parsed))
        {
            return false;
        }
        value = parsed;
        return true;
    }

    private static string ActionKindWire(MacInputAction.Kind kind) => kind switch
    {
        MacInputAction.Kind.Click => "click",
        MacInputAction.Kind.Type => "type",
        MacInputAction.Kind.Key => "key",
        MacInputAction.Kind.Shortcut => "shortcut",
        MacInputAction.Kind.DragDrop => "drag_drop",
        MacInputAction.Kind.Scroll => "scroll",
        MacInputAction.Kind.PointerMove => "pointer_move",
        MacInputAction.Kind.PointerClick => "pointer_click",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null),
    };

    private static bool TryActionKind(string value, out MacInputAction.Kind kind)
    {
        kind = value switch
        {
            "click" => MacInputAction.Kind.Click,
            "type" => MacInputAction.Kind.Type,
            "key" => MacInputAction.Kind.Key,
            "shortcut" => MacInputAction.Kind.Shortcut,
            "drag_drop" => MacInputAction.Kind.DragDrop,
            "scroll" => MacInputAction.Kind.Scroll,
            "pointer_move" => MacInputAction.Kind.PointerMove,
            "pointer_click" => MacInputAction.Kind.PointerClick,
            _ => default,
        };
        return value is "click" or "type" or "key" or "shortcut" or "drag_drop"
            or "scroll" or "pointer_move" or "pointer_click";
    }
}

public sealed record PrivilegedInputResponse(bool Ok, string Detail)
{
    public byte[] Encode() => JsonSerializer.SerializeToUtf8Bytes(new { ok = Ok, detail = Detail });

    public static PrivilegedInputResponse Parse(ReadOnlySpan<byte> payload)
    {
        if (payload.Length is 0 or > 4 * 1024)
        {
            return new PrivilegedInputResponse(false, "invalid_response");
        }
        try
        {
            using JsonDocument document = JsonDocument.Parse(payload.ToArray());
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("ok", out JsonElement okElement)
                || okElement.ValueKind is not (JsonValueKind.True or JsonValueKind.False)
                || !root.TryGetProperty("detail", out JsonElement detailElement)
                || detailElement.ValueKind != JsonValueKind.String
                || detailElement.GetString() is not string detail
                || detail.Length is <= 0 or > 128
                || detail.Any(char.IsControl))
            {
                return new PrivilegedInputResponse(false, "invalid_response");
            }
            return new PrivilegedInputResponse(okElement.GetBoolean(), detail);
        }
        catch (JsonException)
        {
            return new PrivilegedInputResponse(false, "invalid_response");
        }
    }
}

/// <summary>Transport seam used by the production run executor and portable tests.</summary>
public interface IPrivilegedInputDispatcher
{
    Task<PrivilegedInputResponse> DispatchAsync(
        string sessionId,
        string approvalId,
        string actionId,
        MacInputAction action,
        int timeoutMilliseconds = 5_000,
        CancellationToken cancellationToken = default);
}

/// <summary>Execution-leaf policy used inside the isolated Windows input broker.</summary>
public sealed class PrivilegedInputExecutionService
{
    private readonly IUiInspector _inspector;
    private readonly IInputSynthesizer _synthesizer;
    private readonly IKillSwitchFlag _killSwitch;
    private readonly IPrivilegedInputReceiptStore _receipts;
    private readonly ScopeMatcher _scopeMatcher = new();

    public PrivilegedInputExecutionService(
        IUiInspector inspector,
        IInputSynthesizer synthesizer,
        IKillSwitchFlag killSwitch,
        IPrivilegedInputReceiptStore? receipts = null)
    {
        _inspector = inspector ?? throw new ArgumentNullException(nameof(inspector));
        _synthesizer = synthesizer ?? throw new ArgumentNullException(nameof(synthesizer));
        _killSwitch = killSwitch ?? throw new ArgumentNullException(nameof(killSwitch));
        _receipts = receipts ?? new InMemoryPrivilegedInputReceiptStore();
    }

    public PrivilegedInputResponse Execute(PrivilegedInputCommand command)
    {
        ArgumentNullException.ThrowIfNull(command);
        if (command.Kind != PrivilegedInputCommandKind.Dispatch
            || command.Action is null
            || string.IsNullOrWhiteSpace(command.SessionId)
            || string.IsNullOrWhiteSpace(command.ApprovalId)
            || string.IsNullOrWhiteSpace(command.ActionId))
        {
            return new PrivilegedInputResponse(false, command.Error ?? "invalid_dispatch");
        }

        if (KillSwitchActive())
        {
            return new PrivilegedInputResponse(false, "kill_switch");
        }

        UiElementInfo target;
        try
        {
            target = ShouldInspectPoint(command.Action)
                ? _inspector.InspectPoint(command.Action.DisplayX!.Value, command.Action.DisplayY!.Value)
                : _inspector.InspectFrontmost();
        }
        catch (Exception)
        {
            return new PrivilegedInputResponse(false, "target_unavailable");
        }

        if (string.IsNullOrWhiteSpace(target.ProcessImageName))
        {
            return new PrivilegedInputResponse(false, "target_unavailable");
        }

        if (target.ClassifyDenyRegion() is not null)
        {
            return new PrivilegedInputResponse(false, "protected_target");
        }

        ScopeOutcome scope = _scopeMatcher.Evaluate(
            DenyRegistry.BuiltInRules,
            target.ToScopeContext(),
            DateTimeOffset.UtcNow);
        if (scope.Result == ScopeOutcome.Kind.Denied)
        {
            return new PrivilegedInputResponse(false, "protected_target");
        }

        if (KillSwitchActive())
        {
            return new PrivilegedInputResponse(false, "kill_switch");
        }

        PrivilegedInputReceiptReservation reservation;
        try
        {
            reservation = _receipts.Reserve(command.ActionId);
        }
        catch (Exception error) when (error is System.IO.IOException
            or UnauthorizedAccessException
            or InvalidOperationException)
        {
            return new PrivilegedInputResponse(false, "receipt_store_unavailable");
        }
        if (reservation.State == PrivilegedInputReceiptState.Completed)
        {
            return reservation.Response!;
        }
        if (reservation.State == PrivilegedInputReceiptState.Indeterminate)
        {
            return new PrivilegedInputResponse(false, "dispatch_indeterminate");
        }

        InputSynthesisResult result = _synthesizer.Synthesize(command.Action);
        PrivilegedInputResponse response = result.Dispatched
            ? new PrivilegedInputResponse(true, "dispatched")
            : new PrivilegedInputResponse(false, NormalizeDetail(result.Detail));
        try
        {
            _receipts.Complete(command.ActionId, response);
            return response;
        }
        catch (Exception error) when (error is System.IO.IOException
            or UnauthorizedAccessException
            or InvalidOperationException)
        {
            return new PrivilegedInputResponse(false, "dispatch_indeterminate");
        }
    }

    private bool KillSwitchActive()
    {
        try
        {
            return _killSwitch.IsActive;
        }
        catch (Exception)
        {
            return true;
        }
    }

    private static bool ShouldInspectPoint(MacInputAction action) =>
        action.DisplayX is not null
        && action.DisplayY is not null
        && action.ActionKind is MacInputAction.Kind.Click
            or MacInputAction.Kind.DragDrop
            or MacInputAction.Kind.Scroll
            or MacInputAction.Kind.PointerMove;

    private static string NormalizeDetail(string detail)
    {
        string normalized = detail.Trim();
        return normalized.Length is > 0 and <= 64
            && normalized.All(character => char.IsAsciiLetterOrDigit(character) || character is '_' or '-')
                ? normalized
                : "dispatch_failed";
    }
}
