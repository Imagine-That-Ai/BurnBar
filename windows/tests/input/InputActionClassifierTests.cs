// Advisory-vs-non-bypassable classification (R17): every action kind maps to the correct
// route + the canonical macOS audit-kind string.

using OpenBurnBar.Pal.Input;
using Xunit;

namespace OpenBurnBar.Pal.Input.Tests;

public sealed class InputActionClassifierTests
{
    [Theory]
    [InlineData(InputActionKind.Click, InputDispatchRoute.NonBypassable)]
    [InlineData(InputActionKind.Type, InputDispatchRoute.NonBypassable)]
    [InlineData(InputActionKind.Key, InputDispatchRoute.NonBypassable)]
    [InlineData(InputActionKind.Shortcut, InputDispatchRoute.NonBypassable)]
    [InlineData(InputActionKind.DragDrop, InputDispatchRoute.NonBypassable)]
    [InlineData(InputActionKind.PointerClick, InputDispatchRoute.NonBypassable)]
    [InlineData(InputActionKind.Scroll, InputDispatchRoute.Advisory)]
    [InlineData(InputActionKind.PointerMove, InputDispatchRoute.Advisory)]
    [InlineData(InputActionKind.Inspect, InputDispatchRoute.Advisory)]
    public void Classify_maps_every_kind_to_its_route(InputActionKind kind, InputDispatchRoute expected)
    {
        Assert.Equal(expected, InputActionClassifier.Classify(kind));
        Assert.Equal(expected == InputDispatchRoute.NonBypassable, InputActionClassifier.IsNonBypassable(kind));
    }

    [Theory]
    [InlineData(InputActionKind.Click, "mac.input.click")]
    [InlineData(InputActionKind.Type, "mac.input.type")]
    [InlineData(InputActionKind.Key, "mac.input.key")]
    [InlineData(InputActionKind.Shortcut, "mac.input.shortcut")]
    [InlineData(InputActionKind.DragDrop, "mac.input.drag_drop")]
    [InlineData(InputActionKind.Scroll, "mac.input.scroll")]
    [InlineData(InputActionKind.PointerMove, "mac.input.pointer_move")]
    [InlineData(InputActionKind.PointerClick, "mac.input.pointer_click")]
    [InlineData(InputActionKind.Inspect, "mac.inspect.accessibility")]
    public void AuditKind_matches_the_macOS_wire_strings(InputActionKind kind, string expected)
    {
        Assert.Equal(expected, InputActionClassifier.AuditKind(kind));
    }

    [Fact]
    public void Request_defaults_capability_action_kind_to_audit_kind()
    {
        var request = VirtualHidInputRequest.For(new VirtualHidInputReport(InputActionKind.Type));
        Assert.Equal("mac.input.type", request.CapabilityActionKind);
    }

    [Fact]
    public void Every_non_bypassable_kind_commits_input_and_every_advisory_kind_only_navigates()
    {
        // Guard the security-relevant partition: the non-bypassable set is exactly the
        // input-committing actions; the advisory set is exactly navigation/observation.
        var nonBypassable = new[]
        {
            InputActionKind.Click, InputActionKind.Type, InputActionKind.Key,
            InputActionKind.Shortcut, InputActionKind.DragDrop, InputActionKind.PointerClick,
        };
        var advisory = new[]
        {
            InputActionKind.Scroll, InputActionKind.PointerMove, InputActionKind.Inspect,
        };

        foreach (var kind in nonBypassable)
        {
            Assert.True(InputActionClassifier.IsNonBypassable(kind), $"{kind} should be non-bypassable");
        }
        foreach (var kind in advisory)
        {
            Assert.False(InputActionClassifier.IsNonBypassable(kind), $"{kind} should be advisory");
        }
    }
}
