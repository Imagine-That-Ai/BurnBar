using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using OpenBurnBar.App.Interop;
using OpenBurnBar.App.Shell;
using Windows.UI.ViewManagement;

namespace OpenBurnBar.App.Theme;

/// <summary>
/// The shell-wide theme + appearance authority — the Windows analog of the macOS
/// <c>ThemeManager</c> (<c>AgentLens/Theme/ThemeManager.swift</c>) plus the appearance
/// plumbing driven by <c>AppearanceMode</c> / <c>AppearanceModePickerView</c>.
///
/// Responsibilities:
///   • Own the current <see cref="AppearanceMode"/> and push the matching
///     <see cref="ElementTheme"/> onto every registered window root.
///   • Resolve the effective reduced-transparency state (explicit override, else the OS
///     <see cref="UISettings.AdvancedEffectsEnabled"/>) and enable/disable the window
///     backdrop accordingly — the reduced-transparency + high-contrast path.
///   • Persist choices via <see cref="AppStatePersistence"/> and raise <see cref="Changed"/>.
///
/// It deliberately does <b>not</b> own the per-card Liquid-Glass transparency slider
/// (t∈[-1,1]); that math lives in the glass shim (#1200, <c>Theme/LiquidGlass.cs</c>).
/// This service owns only the window-level backdrop on/off decision, which is shell chrome.
/// </summary>
public sealed class ThemeService
{
    private readonly AppStatePersistence _persistence;
    private readonly List<Window> _windows = new();
    private readonly UISettings _uiSettings = new();

    private AppearanceMode _mode;
    private bool? _reduceTransparencyOverride;

    public ThemeService(AppStatePersistence persistence)
    {
        _persistence = persistence;
        // First-run / empty preference: lock Dark so the shell matches macOS Pensieve
        // instead of light Fluent. Explicit "system"/"light"/"dark" still parse as chosen.
        string? rawMode = persistence.State.AppearanceMode;
        if (string.IsNullOrWhiteSpace(rawMode))
        {
            _mode = AppearanceMode.Dark;
            _persistence.State.AppearanceMode = "dark";
            _persistence.Save();
        }
        else
        {
            _mode = AppearanceModeExtensions.ParseOrSystem(rawMode);
        }

        _reduceTransparencyOverride = persistence.State.ReduceTransparency;
        // Glass transparency / content-surfaces changes re-apply window backdrops.
        LiquidGlassEnvironment.PreferencesChanged += (_, _) => ApplyToAll();
    }

    /// <summary>Raised after any appearance change is applied, so surfaces can re-render dependent chrome.</summary>
    public event EventHandler? Changed;

    /// <summary>The active appearance mode. Setting it re-applies to all windows and persists.</summary>
    public AppearanceMode Mode
    {
        get => _mode;
        set
        {
            if (_mode == value)
            {
                return;
            }

            _mode = value;
            _persistence.State.AppearanceMode = value.ToString().ToLowerInvariant();
            _persistence.Save();
            ApplyToAll();
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>
    /// Explicit reduced-transparency override. <c>null</c> follows the OS
    /// (<see cref="UISettings.AdvancedEffectsEnabled"/> inverted). Setting it persists + re-applies.
    /// </summary>
    public bool? ReduceTransparencyOverride
    {
        get => _reduceTransparencyOverride;
        set
        {
            if (_reduceTransparencyOverride == value)
            {
                return;
            }

            _reduceTransparencyOverride = value;
            _persistence.State.ReduceTransparency = value;
            _persistence.Save();
            ApplyToAll();
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>
    /// The effective reduced-transparency decision: the explicit override if set, otherwise the
    /// OS transparency-effects toggle. High-contrast mode always reduces transparency too.
    /// </summary>
    public bool EffectiveReduceTransparency
    {
        get
        {
            if (_mode == AppearanceMode.HighContrast)
            {
                return true;
            }

            if (_reduceTransparencyOverride is bool forced)
            {
                return forced;
            }

            // AdvancedEffectsEnabled == false means the user asked the OS to reduce transparency.
            return !_uiSettings.AdvancedEffectsEnabled;
        }
    }

    /// <summary>Track a window and apply the current appearance immediately; auto-untracks on close.</summary>
    public void Register(Window window)
    {
        if (window is null || _windows.Contains(window))
        {
            return;
        }

        _windows.Add(window);
        window.Closed += (_, _) => _windows.Remove(window);
        Apply(window);
    }

    /// <summary>Re-apply the current appearance to every tracked window.</summary>
    public void ApplyToAll()
    {
        foreach (var window in _windows.ToArray())
        {
            Apply(window);
        }
    }

    private void Apply(Window window)
    {
        // 1. Element theme on the window content root (Dark by default for Pensieve parity).
        if (window.Content is FrameworkElement root)
        {
            root.RequestedTheme = _mode.ToElementTheme();
        }

        // 2. Backdrop through the Liquid Glass chokepoint when allowed.
        var backdropEnabled = _mode.AllowsBackdrop() && !EffectiveReduceTransparency;
        WindowChrome.ApplyBackdrop(window, backdropEnabled);
    }
}
