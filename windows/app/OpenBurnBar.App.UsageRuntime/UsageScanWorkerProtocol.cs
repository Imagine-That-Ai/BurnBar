using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.UsageRuntime;

/// <summary>
/// Length-independent JSON protocol used between the long-lived WinUI process
/// and the short-lived native parser worker.
/// </summary>
public static class UsageScanWorkerProtocol
{
    public const string WorkerArgument = "--internal-usage-scan-worker";
    private const int RuntimeFailureExitCodeBase = 16;

    internal static int ExitCodeForFailure(UsageRuntimeFailureKind kind)
    {
        if (!Enum.IsDefined(typeof(UsageRuntimeFailureKind), kind))
        {
            throw new ArgumentOutOfRangeException(nameof(kind));
        }
        return RuntimeFailureExitCodeBase + (int)kind;
    }

    internal static bool TryFailureKindForExitCode(
        int exitCode,
        out UsageRuntimeFailureKind kind)
    {
        int rawKind = exitCode - RuntimeFailureExitCodeBase;
        if (rawKind >= 0 && Enum.IsDefined(typeof(UsageRuntimeFailureKind), rawKind))
        {
            kind = (UsageRuntimeFailureKind)rawKind;
            return true;
        }

        kind = default;
        return false;
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        Converters = { new JsonStringEnumConverter() },
    };

    public static async ValueTask WriteRequestAsync(
        Stream destination,
        UsageEngineScanRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(destination);
        ArgumentNullException.ThrowIfNull(request);
        await JsonSerializer.SerializeAsync(
            destination,
            request,
            JsonOptions,
            cancellationToken).ConfigureAwait(false);
        await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public static async ValueTask<UsageEngineScanRequest> ReadRequestAsync(
        Stream source,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(source);
        return await JsonSerializer.DeserializeAsync<UsageEngineScanRequest>(
            source,
            JsonOptions,
            cancellationToken).ConfigureAwait(false)
            ?? throw new JsonException("The usage scan worker received a null request.");
    }

    public static async ValueTask WriteResponseAsync(
        Stream destination,
        UsageEngineScanResponse response,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(destination);
        ArgumentNullException.ThrowIfNull(response);
        await JsonSerializer.SerializeAsync(
            destination,
            response,
            JsonOptions,
            cancellationToken).ConfigureAwait(false);
        await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public static async ValueTask<UsageEngineScanResponse> ReadResponseAsync(
        Stream source,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(source);
        return await JsonSerializer.DeserializeAsync<UsageEngineScanResponse>(
            source,
            JsonOptions,
            cancellationToken).ConfigureAwait(false)
            ?? throw new JsonException("The usage scan worker returned a null response.");
    }
}

/// <summary>Runs one native scan and exits so the OS reclaims the Swift heap.</summary>
public static class UsageScanWorkerHost
{
    public static async Task<int> RunAsync(
        IUsageEngine engine,
        Stream input,
        Stream output,
        TextWriter error,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(engine);
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);

        try
        {
            UsageEngineScanRequest request = await UsageScanWorkerProtocol
                .ReadRequestAsync(input, cancellationToken)
                .ConfigureAwait(false);
            UsageEngineScanResponse response = await engine
                .ScanAsync(request, cancellationToken)
                .ConfigureAwait(false);
            await UsageScanWorkerProtocol
                .WriteResponseAsync(output, response, cancellationToken)
                .ConfigureAwait(false);
            return 0;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            await error.WriteLineAsync("usage_scan_worker_cancelled").ConfigureAwait(false);
            return 2;
        }
        catch (UsageRuntimeException exception)
        {
            await error.WriteLineAsync(
                $"usage_scan_worker_failed: {exception.GetType().Name}: {exception.Message}")
                .ConfigureAwait(false);
            return UsageScanWorkerProtocol.ExitCodeForFailure(exception.Kind);
        }
        catch (Exception exception)
        {
            await error.WriteLineAsync(
                $"usage_scan_worker_failed: {exception.GetType().Name}: {exception.Message}")
                .ConfigureAwait(false);
            return 1;
        }
    }
}
