using System;
using System.Globalization;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using OpenBurnBar.App.Presentation.Budget;

namespace OpenBurnBar.App.Budget;

// Windows implementation of the portable IBudgetNotifier seam: a WinRT AppNotification (toast)
// on budget thresholds. The Windows peer of AgentLens/Services/DataStore/BudgetNotificationCenter.swift
// (which schedules UNUserNotifications). The DEBOUNCE + routing live in the portable
// BudgetEnforcementCoordinator (unit-tested on macOS); this class only renders a decision that
// already passed the debounce as an OS toast.
//
// Windows-only + dev-host-deferred: AppNotificationManager needs a live Windows runtime, so the
// actual toast is exercised on the dev host / Windows CI. On the macOS authoring host this file
// is Roslyn syntax-checked and the app build reaches the XamlCompiler gate (the WindowsAppSDK
// reference assemblies resolve the AppNotification API surface).

/// <summary>
/// Raises OS toasts for budget warnings + blocks via the Windows App SDK AppNotifications.
/// Self-registers on first use so wiring stays contained to the Budget surface.
/// </summary>
public sealed class BudgetToastNotifier : IBudgetNotifier
{
    private bool _registered;

    /// <summary>Register the notifier with the OS exactly once (idempotent).</summary>
    public void EnsureRegistered()
    {
        if (_registered)
        {
            return;
        }

        AppNotificationManager.Default.Register();
        _registered = true;
    }

    public void EmitWarning(BudgetRule rule, double used, double limit, DateTimeOffset? periodStart)
    {
        int usedPercent = limit > 0 ? (int)(used / limit * 100) : 0;
        string body = string.Format(
            CultureInfo.InvariantCulture,
            "${0:F2} of ${1:F2} ({2}%) — heading toward the cap.",
            used, limit, usedPercent);

        Show($"Budget warning · {rule.DisplayLabel}", body);
    }

    public void EmitBlock(BudgetRule rule, double used, double limit)
    {
        string body = string.Format(
            CultureInfo.InvariantCulture,
            "${0:F2} ≥ ${1:F2}. New requests on this scope are blocked until you raise the limit or the period resets.",
            used, limit);

        Show($"Budget reached · {rule.DisplayLabel}", body);
    }

    private void Show(string title, string body)
    {
        EnsureRegistered();

        AppNotification notification = new AppNotificationBuilder()
            .AddText(title)
            .AddText(body)
            .BuildNotification();

        AppNotificationManager.Default.Show(notification);
    }
}
