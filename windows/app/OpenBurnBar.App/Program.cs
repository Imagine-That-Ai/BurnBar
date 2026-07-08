using System;
using System.Threading;
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
        DllSearchHardeningResult hardening = DllSearchHardening.Apply();
        AppDiagnostics.LogEvent("process.start", hardening.Detail);

        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
    }
}
