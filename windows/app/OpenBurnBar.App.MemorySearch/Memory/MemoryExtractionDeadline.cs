using System;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.MemorySearch.Memory;

// PORTED (faithful) from AgentLens/Services/Memory/MemoryExtractionDeadline.swift.
//
// Races an async operation against a wall-clock deadline: operation-wins returns its result and
// cancels the timer; deadline-wins cancels the operation (cooperatively, via the token) and throws
// MemoryExtractionDeadlineException. A non-positive deadline runs the operation with no timer.
// The Swift peer uses Task.sleep (no injectable clock); tests use a short deadline. The operation
// receives the CancellationToken so it can observe cooperative cancellation like Swift's
// Task.isCancelled.

/// <summary>Thrown when an operation exceeds its wall-clock deadline. Swift:
/// <c>struct MemoryExtractionDeadlineError</c>.</summary>
public sealed class MemoryExtractionDeadlineException : Exception
{
    public double Seconds { get; }

    public MemoryExtractionDeadlineException(double seconds)
        : base($"Memory extraction exceeded its {seconds}s deadline.")
    {
        Seconds = seconds;
    }
}

/// <summary>The throwing-deadline race. Swift: <c>func withThrowingDeadline</c>.</summary>
public static class MemoryExtractionDeadline
{
    /// <summary>
    /// Runs <paramref name="operation"/>, throwing <see cref="MemoryExtractionDeadlineException"/>
    /// if it does not complete within <paramref name="seconds"/>. A non-positive deadline runs the
    /// operation with no timer. Swift: <c>withThrowingDeadline(seconds:operation:)</c>.
    /// </summary>
    public static async Task<T> WithThrowingDeadlineAsync<T>(
        double seconds,
        Func<CancellationToken, Task<T>> operation,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(operation);
        if (!(seconds > 0))
        {
            return await operation(cancellationToken).ConfigureAwait(false);
        }

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        Task<T> operationTask = operation(linked.Token);
        Task delayTask = Task.Delay(TimeSpan.FromSeconds(seconds), linked.Token);

        Task finished = await Task.WhenAny(operationTask, delayTask).ConfigureAwait(false);
        if (finished == operationTask)
        {
            // Operation won: cancel the timer and surface the result (or its exception).
            linked.Cancel();
            return await operationTask.ConfigureAwait(false);
        }

        // Deadline fired: cancel the operation cooperatively and throw.
        linked.Cancel();
        throw new MemoryExtractionDeadlineException(seconds);
    }
}
