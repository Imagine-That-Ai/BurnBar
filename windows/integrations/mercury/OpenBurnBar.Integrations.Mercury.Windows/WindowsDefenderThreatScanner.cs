using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Mercury.FileTransfer;

namespace OpenBurnBar.Integrations.Mercury.Windows;

/// <summary>Runs a bounded Windows Defender custom scan with shell-free arguments.</summary>
public sealed class WindowsDefenderThreatScanner : IInboundFileThreatScanner
{
    public const string ProviderName = "Microsoft Defender MpCmdRun";
    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromMinutes(2);
    private static readonly SemaphoreSlim ScanGate = new(1, 1);

    private readonly string? _executablePath;
    private readonly TimeSpan _timeout;

    public WindowsDefenderThreatScanner(string? executablePath = null, TimeSpan? timeout = null)
    {
        _executablePath = executablePath ?? TryLocateExecutable();
        _timeout = timeout ?? DefaultTimeout;
    }

    public bool IsAvailable => OperatingSystem.IsWindows()
        && !string.IsNullOrWhiteSpace(_executablePath)
        && File.Exists(_executablePath);

    public async ValueTask<FileThreatScanResult> ScanAsync(
        string filePath,
        CancellationToken cancellationToken = default)
    {
        if (!IsAvailable)
        {
            return new FileThreatScanResult(FileThreatScanStatus.Unavailable, ProviderName, "Defender command-line scanner is unavailable.");
        }

        string fullPath = Path.GetFullPath(filePath);
        if (!File.Exists(fullPath))
        {
            return new FileThreatScanResult(FileThreatScanStatus.Error, ProviderName, "Quarantined file is missing.");
        }

        await ScanGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await ScanCoreAsync(fullPath, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            ScanGate.Release();
        }
    }

    private async ValueTask<FileThreatScanResult> ScanCoreAsync(
        string fullPath,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = _executablePath!,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Path.GetDirectoryName(_executablePath!)!,
        };
        startInfo.ArgumentList.Add("-Scan");
        startInfo.ArgumentList.Add("-ScanType");
        startInfo.ArgumentList.Add("3");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(fullPath);
        startInfo.ArgumentList.Add("-DisableRemediation");

        using var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start())
            {
                return new FileThreatScanResult(FileThreatScanStatus.Error, ProviderName, "Defender process did not start.");
            }

            Task<string> output = process.StandardOutput.ReadToEndAsync();
            Task<string> error = process.StandardError.ReadToEndAsync();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(_timeout);
            try
            {
                await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                TryKill(process);
                await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
                await Task.WhenAll(output, error).ConfigureAwait(false);
                return new FileThreatScanResult(FileThreatScanStatus.Error, ProviderName, "Defender scan timed out.");
            }
            catch (OperationCanceledException)
            {
                TryKill(process);
                await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
                await Task.WhenAll(output, error).ConfigureAwait(false);
                throw;
            }

            await Task.WhenAll(output, error).ConfigureAwait(false);
            int exitCode = process.ExitCode;
            return exitCode switch
            {
                0 => new FileThreatScanResult(FileThreatScanStatus.Clean, ProviderName, "Defender reported no threat.", exitCode),
                2 => new FileThreatScanResult(FileThreatScanStatus.ThreatDetected, ProviderName, "Defender reported a threat or incomplete remediation.", exitCode),
                _ => new FileThreatScanResult(FileThreatScanStatus.Error, ProviderName, "Defender scan failed.", exitCode),
            };
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception or IOException)
        {
            return new FileThreatScanResult(FileThreatScanStatus.Error, ProviderName, ex.GetType().Name);
        }
    }

    public static string? TryLocateExecutable()
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }

        var candidates = new List<string>();
        string? programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        if (!string.IsNullOrWhiteSpace(programData))
        {
            string platformRoot = Path.Combine(programData, "Microsoft", "Windows Defender", "Platform");
            try
            {
                if (Directory.Exists(platformRoot))
                {
                    candidates.AddRange(Directory
                        .EnumerateDirectories(platformRoot)
                        .OrderByDescending(path => Path.GetFileName(path), StringComparer.OrdinalIgnoreCase)
                        .Select(path => Path.Combine(path, "MpCmdRun.exe")));
                }
            }
            catch (UnauthorizedAccessException)
            {
            }
            catch (IOException)
            {
            }
        }

        string? programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        if (!string.IsNullOrWhiteSpace(programFiles))
        {
            candidates.Add(Path.Combine(programFiles, "Windows Defender", "MpCmdRun.exe"));
        }

        return candidates.FirstOrDefault(File.Exists);
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
        }
        catch (System.ComponentModel.Win32Exception)
        {
        }
    }
}
