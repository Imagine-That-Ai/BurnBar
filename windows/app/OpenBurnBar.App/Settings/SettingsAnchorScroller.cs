// The WinUI realization of the macOS ScrollViewReader + anchor/highlight behavior
// (SettingsAnchorModifiers.swift + the destination-view `.id(anchorID)` + pulse).
//
// A leaf Settings page registers each anchored row's FrameworkElement under its
// SettingsAnchor id; when the router hands the page a pending anchor, ScrollTo
// brings that row into view and runs a brief attention pulse. Optional focus targets
// (text boxes, number boxes) are registered too so a focusID can latch the caret.

using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;

namespace OpenBurnBar.App.Settings.Winui;

/// <summary>A Settings leaf page that can scroll to + highlight one of its anchored rows.</summary>
public interface ISettingsAnchorTarget
{
    /// <summary>Scroll to <paramref name="anchorId"/>, pulse it, and focus <paramref name="focusId"/> if set.</summary>
    void ScrollToAnchor(string anchorId, string? focusId);
}

/// <summary>Registers anchored rows + focus controls and drives bring-into-view + a pulse.</summary>
public sealed class SettingsAnchorScroller
{
    private readonly Dictionary<string, FrameworkElement> _anchors = new();
    private readonly Dictionary<string, Control> _focusables = new();

    /// <summary>Register the row element that <paramref name="anchorId"/> should scroll to.</summary>
    public void RegisterAnchor(string anchorId, FrameworkElement element) => _anchors[anchorId] = element;

    /// <summary>Register a control a <paramref name="focusId"/> should focus once scrolled into view.</summary>
    public void RegisterFocusable(string focusId, Control control) => _focusables[focusId] = control;

    /// <summary>
    /// Bring the anchored row into view, run a short opacity pulse, and focus the matching
    /// control. Returns <c>true</c> when the anchor was known to this page.
    /// </summary>
    public bool ScrollTo(string anchorId, string? focusId = null)
    {
        if (!_anchors.TryGetValue(anchorId, out var element))
        {
            return false;
        }

        element.StartBringIntoView(new BringIntoViewOptions
        {
            AnimationDesired = true,
            VerticalAlignmentRatio = 0.15,
        });

        Pulse(element);

        if (focusId is not null && _focusables.TryGetValue(focusId, out var focusable))
        {
            focusable.Focus(FocusState.Programmatic);
        }

        return true;
    }

    /// <summary>A brief attention flash on the arrival row (the WinUI stand-in for the macOS highlight).</summary>
    private static void Pulse(FrameworkElement element)
    {
        var animation = new DoubleAnimationUsingKeyFrames
        {
            EnableDependentAnimation = true,
        };
        animation.KeyFrames.Add(new DiscreteDoubleKeyFrame
        {
            KeyTime = KeyTime.FromTimeSpan(TimeSpan.Zero),
            Value = 1.0,
        });
        animation.KeyFrames.Add(new LinearDoubleKeyFrame
        {
            KeyTime = KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(120)),
            Value = 0.35,
        });
        animation.KeyFrames.Add(new LinearDoubleKeyFrame
        {
            KeyTime = KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(650)),
            Value = 1.0,
        });

        var storyboard = new Storyboard();
        Storyboard.SetTarget(animation, element);
        Storyboard.SetTargetProperty(animation, "Opacity");
        storyboard.Children.Add(animation);
        storyboard.Begin();
    }
}
