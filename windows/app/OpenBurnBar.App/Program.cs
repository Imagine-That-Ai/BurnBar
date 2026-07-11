using System;
using System.Threading;
using Microsoft.Windows.AppLifecycle;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.Dist.Hardening;

namespace OpenBurnBar.App;

public static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        DllSearchHardeningResult hardening = DllSearchHardening.ApplyWinUICompatible();
        AppDiagnostics.LogEvent("process.start", hardening.Detail);

        if (!RedirectToRunningInstance())
        {
            return;
        }

        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            new App();
        });
    }

    private static bool RedirectToRunningInstance()
    {
        try
        {
            AppActivationArguments activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            AppInstance instance = AppInstance.FindOrRegisterForKey("OpenBurnBar");
            if (instance.IsCurrent)
            {
                return true;
            }

            instance.RedirectActivationToAsync(activation).AsTask().GetAwaiter().GetResult();
            AppDiagnostics.LogEvent("activation.redirect", activation.Kind.ToString());
            return false;
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("activation.single-instance", ex);
            return true;
        }
    }
}
