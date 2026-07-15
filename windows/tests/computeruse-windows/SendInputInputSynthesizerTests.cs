using System;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Windows;
using Xunit;

namespace OpenBurnBar.ComputerUse.Windows.Tests;

public sealed class SendInputInputSynthesizerTests
{
    private readonly SendInputInputSynthesizer _sut = new();

    [Fact]
    public void SendInputIsExplicitlyAdvisory()
    {
        Assert.False(_sut.RoutesThroughSignedDriver);
    }

    [Fact]
    public void UnsupportedKeyFailsClosedBeforeNativeCall()
    {
        var result = _sut.Synthesize(new MacInputAction(MacInputAction.Kind.Key, key: "launch-secret-shell"));

        Assert.False(result.Dispatched);
        Assert.Equal("unsupported_key", result.Detail);
    }

    [Fact]
    public void UnsupportedModifierFailsClosedBeforeNativeCall()
    {
        var result = _sut.Synthesize(new MacInputAction(
            MacInputAction.Kind.Shortcut,
            key: "C",
            modifiers: new[] { "hyper" }));

        Assert.False(result.Dispatched);
        Assert.Equal("unsupported_modifier", result.Detail);
    }

    [Fact]
    public void DragRequiresBothEndpoints()
    {
        var result = _sut.Synthesize(new MacInputAction(
            MacInputAction.Kind.DragDrop,
            displayX: 10,
            displayY: 20,
            dragEndX: 30));

        Assert.False(result.Dispatched);
        Assert.Equal("missing_coordinates", result.Detail);
    }

    [Fact]
    public void ZeroScrollFailsClosed()
    {
        var result = _sut.Synthesize(new MacInputAction(MacInputAction.Kind.Scroll));

        Assert.False(result.Dispatched);
        Assert.Equal("zero_scroll", result.Detail);
    }

    [Fact]
    public void OversizedTextFailsClosed()
    {
        var result = _sut.Synthesize(new MacInputAction(
            MacInputAction.Kind.Type,
            text: new string('x', 64 * 1024 + 1)));

        Assert.False(result.Dispatched);
        Assert.Equal("text_too_large", result.Detail);
    }

    [Fact]
    public void EmptyTextFailsClosed()
    {
        var result = _sut.Synthesize(new MacInputAction(MacInputAction.Kind.Type, text: String.Empty));

        Assert.False(result.Dispatched);
        Assert.Equal("empty_text", result.Detail);
    }
}
