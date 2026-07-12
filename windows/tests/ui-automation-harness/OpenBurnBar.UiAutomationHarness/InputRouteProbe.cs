using System;
using System.Collections.Generic;
using OpenBurnBar.Pal.Input;
using OpenBurnBar.UiAutomationHarness.Core;

namespace OpenBurnBar.UiAutomationHarness;

internal static class InputRouteProbe
{
    public static IReadOnlyList<InputRouteEvidence> Capture()
    {
        var routes = new List<InputRouteEvidence>();
        foreach (InputActionKind kind in Enum.GetValues<InputActionKind>())
        {
            InputDispatchRoute route = InputActionClassifier.Classify(kind);
            InputDispatchRoute expected = ExpectedRoute(kind);
            bool expectedToken = expected == InputDispatchRoute.NonBypassable;
            bool tokenRequired = route == InputDispatchRoute.NonBypassable;
            var verdict = route == expected && tokenRequired == expectedToken
                ? HarnessVerdict.Pass
                : HarnessVerdict.Fail;
            routes.Add(new InputRouteEvidence(
                kind.ToString(),
                route.ToString(),
                InputActionClassifier.AuditKind(kind),
                tokenRequired,
                verdict,
                verdict == HarnessVerdict.Pass
                    ? null
                    : $"Expected {expected} with tokenRequired={expectedToken}; got {route} with tokenRequired={tokenRequired}."));
        }

        return routes;
    }

    private static InputDispatchRoute ExpectedRoute(InputActionKind kind) => kind switch
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
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "Unknown input action kind.")
    };
}
