using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Chat;

public sealed record ChatProcessLimits(int MaxCombinedBytes, int MaxRecordBytes)
{
    public static ChatProcessLimits ContractDefault { get; } =
        new(32 * 1024 * 1024, 1024 * 1024);
}

public sealed record ApprovedChatExecutable(string Id, string Path, string Sha256);

public sealed record ChatExecutableResolution(string Id, string Path, string Sha256);

public sealed class ApprovedChatExecutableCatalog
{
    private readonly IReadOnlyList<ApprovedChatExecutable> _executables;

    public ApprovedChatExecutableCatalog(IEnumerable<ApprovedChatExecutable> executables)
    {
        _executables = executables.ToArray();
    }

    public bool HasEntries => _executables.Count > 0;

    public ChatExecutableResolution Resolve(string requestedExecutable)
    {
        if (string.IsNullOrWhiteSpace(requestedExecutable))
        {
            throw new ChatProcessException(ChatFailureKind.ExecutableDenied, "Chat executable is empty.");
        }

        string requested = requestedExecutable.Trim();
        string? requestedFullPath = FullyQualifiedPathOrNull(requested);
        string requestedFileName = System.IO.Path.GetFileName(requested);
        ApprovedChatExecutable? approved = _executables.FirstOrDefault(entry =>
            PathMatches(entry, requested, requestedFullPath, requestedFileName));
        if (approved is null)
        {
            throw new ChatProcessException(
                ChatFailureKind.ExecutableDenied,
                _executables.Count == 0
                    ? "No chat executable has been approved in the protected inventory."
                    : "Chat executable is not in the approved identity catalog.");
        }

        string approvedPath = System.IO.Path.GetFullPath(approved.Path);
        if (!File.Exists(approvedPath))
        {
            throw new ChatProcessException(
                ChatFailureKind.ExecutableUnavailable,
                "Approved chat executable is unavailable: " + approvedPath);
        }

        string actualSha = ComputeSha256(approvedPath);
        if (!string.Equals(actualSha, approved.Sha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new ChatProcessException(
                ChatFailureKind.ExecutableReplaced,
                "Approved chat executable hash changed after approval.");
        }

        return new ChatExecutableResolution(approved.Id, approvedPath, actualSha);
    }

    public static string ComputeSha256(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private static bool PathMatches(
        ApprovedChatExecutable approved,
        string requested,
        string? requestedFullPath,
        string requestedFileName)
    {
        string approvedPath = approved.Path;
        string fullApproved = System.IO.Path.GetFullPath(approvedPath);
        if (requestedFullPath is not null)
        {
            return string.Equals(fullApproved, requestedFullPath, PathComparison);
        }

        if (string.Equals(approved.Id, requested, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        string approvedFileName = System.IO.Path.GetFileName(fullApproved);
        if (string.Equals(approvedFileName, requestedFileName, FileNameComparison))
        {
            return true;
        }

        return OperatingSystem.IsWindows()
            && string.Equals(
                System.IO.Path.GetFileNameWithoutExtension(approvedFileName),
                requestedFileName,
                StringComparison.OrdinalIgnoreCase);
    }

    private static string? FullyQualifiedPathOrNull(string value)
    {
        if (!System.IO.Path.IsPathFullyQualified(value))
        {
            return null;
        }

        return System.IO.Path.GetFullPath(value);
    }

    private static StringComparison PathComparison =>
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    private static StringComparison FileNameComparison =>
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
}

public sealed class ChatProcessException : Exception
{
    public ChatFailureKind Kind { get; }

    public int? ExitCode { get; }

    public ChatProcessException(ChatFailureKind kind, string message, int? exitCode = null, Exception? innerException = null)
        : base(message, innerException)
    {
        Kind = kind;
        ExitCode = exitCode;
    }
}

public sealed record ChatProcessLine(string? Line, ChatFailureKind? FailureKind = null, string? FailureMessage = null)
{
    public bool IsFailure => FailureKind is not null;
}

public static class ChatProcessRunner
{
    public static async IAsyncEnumerable<ChatProcessLine> StreamStdoutLinesAsync(
        ChildProcessSpec spec,
        ApprovedChatExecutableCatalog? catalog = null,
        ChatProcessLimits? limits = null,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        limits ??= ChatProcessLimits.ContractDefault;
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        Process? process = null;
        Channel<ChatProcessLine> channel = Channel.CreateUnbounded<ChatProcessLine>();
        var stderr = new ConcurrentQueue<string>();
        var accounting = new BoundedOutputAccounting(limits);

        ChatProcessException? startFailure = null;
        try
        {
            ApprovedChatExecutableCatalog resolvedCatalog =
                catalog ?? ProtectedChatExecutableInventoryStore.CreateDefault().LoadCatalog();
            ProcessStartInfo startInfo = CreateStartInfo(spec, resolvedCatalog);
            process = ChildProcessLaunchPolicy.Start(startInfo, ChildProcessProfile.Chat);

            if (spec.StandardInput is not null)
            {
                await process.StandardInput.WriteAsync(spec.StandardInput.AsMemory(), linkedCts.Token).ConfigureAwait(false);
                process.StandardInput.Close();
            }
        }
        catch (Exception ex)
        {
            startFailure = ToTypedException(ex, ChatFailureKind.ProcessStartFailed);
        }

        if (startFailure is not null)
        {
            yield return new ChatProcessLine(null, startFailure.Kind, startFailure.Message);
            yield break;
        }
        Process runningProcess = process ?? throw new InvalidOperationException("Chat process was not started.");

        Task stdoutTask = DrainAsync(
            runningProcess.StandardOutput,
            isStdout: true,
            channel.Writer,
            stderr,
            accounting,
            linkedCts.Token);
        Task stderrTask = DrainAsync(
            runningProcess.StandardError,
            isStdout: false,
            channel.Writer,
            stderr,
            accounting,
            linkedCts.Token);
        Task completionTask = CompleteWhenDoneAsync(
            runningProcess,
            stdoutTask,
            stderrTask,
            channel.Writer,
            stderr,
            linkedCts);

        await foreach (ChatProcessLine line in channel.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            yield return line;
        }

        await completionTask.ConfigureAwait(false);
    }

    internal static ProcessStartInfo CreateStartInfo(
        ChildProcessSpec spec,
        ApprovedChatExecutableCatalog catalog)
    {
        ChatExecutableResolution executable = catalog.Resolve(spec.FileName);
        return ChildProcessLaunchPolicy.CreateStartInfo(
            ChildProcessProfile.Chat,
            executable.Path,
            spec.Arguments,
            redirectStandardInput: spec.StandardInput is not null,
            redirectStandardOutput: true,
            redirectStandardError: true,
            standardInputEncoding: spec.StandardInput is not null ? Encoding.UTF8 : null,
            standardOutputEncoding: Encoding.UTF8,
            standardErrorEncoding: Encoding.UTF8);
    }

    private static async Task CompleteWhenDoneAsync(
        Process process,
        Task stdoutTask,
        Task stderrTask,
        ChannelWriter<ChatProcessLine> writer,
        ConcurrentQueue<string> stderr,
        CancellationTokenSource linkedCts)
    {
        try
        {
            Task waitTask = process.WaitForExitAsync(linkedCts.Token);
            Task drainsTask = Task.WhenAll(stdoutTask, stderrTask);
            var pendingDrains = new List<Task> { stdoutTask, stderrTask };
            while (!waitTask.IsCompleted && pendingDrains.Count > 0)
            {
                Task first = await Task.WhenAny(pendingDrains.Append(waitTask)).ConfigureAwait(false);
                if (first == waitTask)
                {
                    break;
                }

                pendingDrains.Remove(first);
                await first.ConfigureAwait(false);
            }

            await waitTask.ConfigureAwait(false);
            await drainsTask.ConfigureAwait(false);
            if (process.ExitCode != 0)
            {
                string message = "CLI exited " + process.ExitCode + StderrSuffix(stderr);
                writer.TryWrite(new ChatProcessLine(null, ChatFailureKind.NonZeroExit, message));
            }
        }
        catch (OperationCanceledException)
        {
            TryKillProcessTree(process);
            writer.TryWrite(new ChatProcessLine(null, ChatFailureKind.Cancelled, "Chat process was cancelled."));
        }
        catch (Exception ex)
        {
            TryKillProcessTree(process);
            ChatProcessException typed = ToTypedException(ex, ChatFailureKind.StreamError);
            writer.TryWrite(new ChatProcessLine(null, typed.Kind, typed.Message));
        }
        finally
        {
            process.Dispose();
            writer.TryComplete();
            linkedCts.Dispose();
        }
    }

    private static async Task DrainAsync(
        StreamReader reader,
        bool isStdout,
        ChannelWriter<ChatProcessLine> writer,
        ConcurrentQueue<string> stderr,
        BoundedOutputAccounting accounting,
        CancellationToken cancellationToken)
    {
        char[] buffer = new char[4096];
        var current = new StringBuilder();
        var recordBytes = 0;

        while (true)
        {
            int read = await reader.ReadAsync(buffer.AsMemory(0, buffer.Length), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            accounting.AddCombinedBytes(Encoding.UTF8.GetByteCount(buffer, 0, read));
            for (var i = 0; i < read; i++)
            {
                char ch = buffer[i];
                if (ch == '\n')
                {
                    FlushRecord(isStdout, writer, stderr, current);
                    recordBytes = 0;
                    continue;
                }

                if (ch == '\r')
                {
                    continue;
                }

                current.Append(ch);
                recordBytes += Encoding.UTF8.GetByteCount(buffer, i, 1);
                accounting.AssertRecordWithinLimit(recordBytes);
            }
        }

        FlushRecord(isStdout, writer, stderr, current);
    }

    private static void FlushRecord(
        bool isStdout,
        ChannelWriter<ChatProcessLine> writer,
        ConcurrentQueue<string> stderr,
        StringBuilder current)
    {
        if (current.Length == 0)
        {
            return;
        }

        string line = current.ToString();
        current.Clear();
        if (isStdout)
        {
            writer.TryWrite(new ChatProcessLine(line));
        }
        else if (stderr.Count < 12)
        {
            stderr.Enqueue(line.Length <= 400 ? line : line[..400]);
        }
    }

    private static string StderrSuffix(ConcurrentQueue<string> stderr)
    {
        if (stderr.IsEmpty)
        {
            return ".";
        }

        string joined = string.Join(" ", stderr.Take(3));
        return ": " + SecretRedactor.Shared.Redact(joined);
    }

    private static ChatProcessException ToTypedException(Exception ex, ChatFailureKind fallbackKind)
    {
        if (ex is ChatProcessException typed)
        {
            return typed;
        }

        return new ChatProcessException(fallbackKind, SecretRedactor.Shared.Redact(ex.Message), innerException: ex);
    }

    private static void TryKillProcessTree(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
            // Best effort; Windows host evidence validates absence from the process table.
        }
    }

    private sealed class BoundedOutputAccounting
    {
        private readonly ChatProcessLimits _limits;
        private long _combinedBytes;

        public BoundedOutputAccounting(ChatProcessLimits limits)
        {
            _limits = limits;
        }

        public void AddCombinedBytes(int bytes)
        {
            long total = Interlocked.Add(ref _combinedBytes, bytes);
            if (total > _limits.MaxCombinedBytes)
            {
                throw new ChatProcessException(
                    ChatFailureKind.OutputLimitExceeded,
                    "Chat output exceeded the 32 MiB combined stdout/stderr limit.");
            }
        }

        public void AssertRecordWithinLimit(int recordBytes)
        {
            if (recordBytes > _limits.MaxRecordBytes)
            {
                throw new ChatProcessException(
                    ChatFailureKind.OutputLimitExceeded,
                    "Chat output record exceeded the 1 MiB logical-record limit.");
            }
        }
    }
}
