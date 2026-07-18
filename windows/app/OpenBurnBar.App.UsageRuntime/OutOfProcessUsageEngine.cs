using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;

namespace OpenBurnBar.App.UsageRuntime;

/// <summary>
/// Executes the Swift parser in the signed companion process. Each scan gets a
/// fresh native heap, preventing parser allocation high-water from accumulating
/// in the tray application's long-lived process.
/// </summary>
public sealed class OutOfProcessUsageEngine : IUsageEngine
{
    private const int MaxErrorBytes = 32 * 1024;
    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromMinutes(5);

    private readonly Func<string?> _workerPathResolver;
    private readonly TimeSpan _timeout;

    public OutOfProcessUsageEngine(
        Func<string?>? workerPathResolver = null,
        TimeSpan? timeout = null)
    {
        _workerPathResolver = workerPathResolver ?? ResolveWorkerPath;
        _timeout = timeout ?? DefaultTimeout;
        if (_timeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }
    }

    public async ValueTask<UsageEngineScanResponse> ScanAsync(
        UsageEngineScanRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        cancellationToken.ThrowIfCancellationRequested();

        string? workerPath = _workerPathResolver();
        if (string.IsNullOrWhiteSpace(workerPath) || !File.Exists(workerPath))
        {
            throw new UsageRuntimeException(
                UsageRuntimeFailureKind.NativeEngineUnavailable,
                "The isolated usage scanner is not installed. Repair or reinstall OpenBurnBar.");
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_timeout);
        ProcessStartInfo startInfo = CreateStartInfo(Path.GetFullPath(workerPath));
        using Process process = StartProcess(startInfo);
        Task<string> stderrTask = ReadBoundedErrorAsync(
            process.StandardError.BaseStream,
            timeout.Token);
        Task<UsageEngineScanResponse> responseTask = UsageScanWorkerProtocol
            .ReadResponseAsync(process.StandardOutput.BaseStream, timeout.Token)
            .AsTask();

        try
        {
            await UsageScanWorkerProtocol
                .WriteRequestAsync(process.StandardInput.BaseStream, request, timeout.Token)
                .ConfigureAwait(false);
            process.StandardInput.Close();

            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            string error = await stderrTask.ConfigureAwait(false);
            if (process.ExitCode != 0)
            {
                await ObserveFailureAsync(responseTask).ConfigureAwait(false);
                UsageRuntimeFailureKind failureKind =
                    UsageScanWorkerProtocol.TryFailureKindForExitCode(
                        process.ExitCode,
                        out UsageRuntimeFailureKind workerFailureKind)
                        ? workerFailureKind
                        : UsageRuntimeFailureKind.NativeEngineFailure;
                throw new UsageRuntimeException(
                    failureKind,
                    string.IsNullOrWhiteSpace(error)
                        ? $"The isolated usage scanner exited with code {process.ExitCode}."
                        : error);
            }

            return await responseTask.ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested)
        {
            await TerminateAsync(process).ConfigureAwait(false);
            await ObserveFailureAsync(responseTask).ConfigureAwait(false);
            await ObserveFailureAsync(stderrTask).ConfigureAwait(false);
            if (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            throw new UsageRuntimeException(
                UsageRuntimeFailureKind.NativeEngineFailure,
                "The isolated usage scanner exceeded its time limit.");
        }
        catch (JsonException exception)
        {
            await TerminateAsync(process).ConfigureAwait(false);
            await ObserveFailureAsync(stderrTask).ConfigureAwait(false);
            throw new UsageRuntimeException(
                UsageRuntimeFailureKind.InvalidEngineResponse,
                "The isolated usage scanner returned an invalid response.",
                exception);
        }
        catch (IOException exception)
        {
            await TerminateAsync(process).ConfigureAwait(false);
            await ObserveFailureAsync(responseTask).ConfigureAwait(false);
            await ObserveFailureAsync(stderrTask).ConfigureAwait(false);
            throw new UsageRuntimeException(
                UsageRuntimeFailureKind.NativeEngineFailure,
                "The isolated usage scanner communication channel failed.",
                exception);
        }
    }

    internal static ProcessStartInfo CreateStartInfo(string workerPath)
    {
        var requiredEnvironment = new List<KeyValuePair<string, string?>>
        {
            new("OPENBURNBAR_CORE_CABI_PATH", Environment.GetEnvironmentVariable("OPENBURNBAR_CORE_CABI_PATH")),
            new("OPENBURNBAR_CORE_PACKAGE_PATH", Environment.GetEnvironmentVariable("OPENBURNBAR_CORE_PACKAGE_PATH")),
        };
        return ChildProcessLaunchPolicy.CreateStartInfo(
            ChildProcessProfile.UsageScanner,
            workerPath,
            new[] { UsageScanWorkerProtocol.WorkerArgument },
            workingDirectory: Path.GetDirectoryName(workerPath),
            redirectStandardInput: true,
            redirectStandardOutput: true,
            redirectStandardError: true,
            standardInputEncoding: Encoding.UTF8,
            standardOutputEncoding: Encoding.UTF8,
            standardErrorEncoding: Encoding.UTF8,
            requiredEnvironment: requiredEnvironment);
    }

    public static string? ResolveWorkerPath()
    {
        string? explicitPath = Environment.GetEnvironmentVariable("OPENBURNBAR_USAGE_SCAN_WORKER_PATH");
        if (!string.IsNullOrWhiteSpace(explicitPath) && File.Exists(explicitPath))
        {
            return Path.GetFullPath(explicitPath);
        }

        string fileName = OperatingSystem.IsWindows()
            ? "OpenBurnBar.Cli.exe"
            : "OpenBurnBar.Cli";
        string candidate = Path.Combine(AppContext.BaseDirectory, fileName);
        return File.Exists(candidate) ? candidate : null;
    }

    private static Process StartProcess(ProcessStartInfo startInfo)
    {
        try
        {
            return ChildProcessLaunchPolicy.Start(startInfo, ChildProcessProfile.UsageScanner);
        }
        catch (Exception exception) when (exception is InvalidOperationException
                                           or System.ComponentModel.Win32Exception
                                           or UnauthorizedAccessException)
        {
            throw new UsageRuntimeException(
                UsageRuntimeFailureKind.NativeEngineUnavailable,
                "The isolated usage scanner could not be started.",
                exception);
        }
    }

    private static async Task<string> ReadBoundedErrorAsync(
        Stream source,
        CancellationToken cancellationToken)
    {
        using var result = new MemoryStream();
        var buffer = new byte[4096];
        while (true)
        {
            int read = await source.ReadAsync(
                buffer,
                cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }
            int remaining = MaxErrorBytes - (int)result.Length;
            if (remaining > 0)
            {
                result.Write(buffer, 0, Math.Min(read, remaining));
            }
        }
        return Encoding.UTF8.GetString(result.GetBuffer(), 0, (int)result.Length).Trim();
    }

    private static async Task TerminateAsync(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is InvalidOperationException
                                           or System.ComponentModel.Win32Exception
                                           or NotSupportedException
                                           or TimeoutException)
        {
            // Cleanup is best effort; the original typed scan failure is authoritative.
        }
    }

    private static async Task ObserveFailureAsync(Task task)
    {
        try
        {
            await task.ConfigureAwait(false);
        }
        catch (Exception)
        {
            // This task is already on a failure path and is observed only to drain it.
        }
    }
}
