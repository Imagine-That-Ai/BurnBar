using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.UsageRuntime;

namespace OpenBurnBar.Cli;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        using var cancellation = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            cancellation.Cancel();
        };

        if (args.Length == 1
            && string.Equals(args[0], UsageScanWorkerProtocol.WorkerArgument, StringComparison.Ordinal))
        {
            using var engine = new CAbiUsageEngine();
            return await UsageScanWorkerHost.RunAsync(
                engine,
                Console.OpenStandardInput(),
                Console.OpenStandardOutput(),
                Console.Error,
                cancellation.Token).ConfigureAwait(false);
        }

        var application = new CompanionCliApplication(
            options => new CompanionCliClient(options, ReadProtectedAccessToken));
        return await application.RunAsync(
            args,
            Console.In,
            Console.Out,
            Console.Error,
            cancellation.Token).ConfigureAwait(false);
    }

    private static string? ReadProtectedAccessToken()
    {
        string secretName = AppSecretNames.ProviderSecret("settings", "model-proxy", "auth-token");
        return ProtectedFileSecretStore.CreateDefault().Read(secretName);
    }
}
