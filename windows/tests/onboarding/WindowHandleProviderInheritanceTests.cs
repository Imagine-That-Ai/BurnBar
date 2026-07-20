using System;
using OpenBurnBar.App.Onboarding;
using OpenBurnBar.App.Theme;
using Xunit;

namespace OpenBurnBar.App.Onboarding.Tests;

/// <summary>
/// Regression tests for <see cref="OnboardingContext.WindowHandleProvider"/> — the
/// injected HWND resolver that fixes the dead file-picker bug (Operation 9 · P-CQ-4).
/// Step pages call <c>WinRT.Interop.InitializeWithWindow.Initialize</c> with the handle
/// this <c>Func&lt;IntPtr&gt;</c> returns instead of <c>IntPtr.Zero</c>. These tests
/// assert the property exists, is init-only, defaults to null, and forwards the
/// expected handle when set — and they fail to compile if the property is removed.
/// </summary>
public sealed class WindowHandleProviderInheritanceTests
{
    // MARK: - Property existence + shape

    [Fact]
    public void WindowHandleProvider_IsInitOnly_FuncIntPtr()
    {
        // Construct via init syntax — if WindowHandleProvider were absent or not
        // init-accessible this would not compile, proving the regression guard.
        OnboardingContext context = new(new OnboardingWizardModel())
        {
            WindowHandleProvider = () => new IntPtr(123),
        };

        Assert.NotNull(context.WindowHandleProvider);
        Assert.Equal(new IntPtr(123), context.WindowHandleProvider!());
    }

    // MARK: - Forwards the expected handle when set

    [Fact]
    public void WindowHandleProvider_WhenSet_ReturnsExpectedHandle()
    {
        var expected = new IntPtr(42);
        OnboardingContext context = new(new OnboardingWizardModel())
        {
            WindowHandleProvider = () => expected,
        };

        Assert.NotNull(context.WindowHandleProvider);
        Assert.Equal(expected, context.WindowHandleProvider!());
    }

    // MARK: - Defaults to null when not set

    [Fact]
    public void WindowHandleProvider_WhenNotSet_DefaultsToNull()
    {
        OnboardingContext context = new(new OnboardingWizardModel());

        Assert.Null(context.WindowHandleProvider);
    }

    // MARK: - Can be constructed via init syntax alongside the required model

    [Fact]
    public void WindowHandleProvider_ConstructedWithInitSyntax_AlongsideModel()
    {
        var model = new OnboardingWizardModel();
        OnboardingContext context = new(model)
        {
            WindowHandleProvider = () => new IntPtr(123),
        };

        Assert.Same(model, context.Model);
        Assert.NotNull(context.WindowHandleProvider);
        Assert.Equal(new IntPtr(123), context.WindowHandleProvider!());
    }
}