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
            routes.Add(new InputRouteEvidence(
                kind.ToString(),
                route.ToString(),
                InputActionClassifier.AuditKind(kind),
                route == InputDispatchRoute.NonBypassable));
        }

        return routes;
    }
}
