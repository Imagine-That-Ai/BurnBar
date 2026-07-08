using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.MemorySearch.Memory;
using Xunit;

namespace OpenBurnBar.App.MemorySearch.Tests;

/// <summary>
/// The throwing-deadline race. Swift: <c>withThrowingDeadline</c>. Operation-wins returns and
/// cancels the timer; deadline-wins cancels the operation and throws; non-positive runs untimed.
/// </summary>
public sealed class MemoryExtractionDeadlineTests
{
    [Fact]
    public async Task OperationCompletesInTime_ReturnsResult()
    {
        int result = await MemoryExtractionDeadline.WithThrowingDeadlineAsync(
            seconds: 5,
            operation: async _ =>
            {
                await Task.Delay(1);
                return 42;
            });
        Assert.Equal(42, result);
    }

    [Fact]
    public async Task DeadlineFires_ThrowsAndCancelsOperation()
    {
        bool observedCancellation = false;
        var ex = await Assert.ThrowsAsync<MemoryExtractionDeadlineException>(() =>
            MemoryExtractionDeadline.WithThrowingDeadlineAsync<int>(
                seconds: 0.05,
                operation: async token =>
                {
                    try
                    {
                        await Task.Delay(TimeSpan.FromSeconds(30), token);
                    }
                    catch (OperationCanceledException)
                    {
                        observedCancellation = true;
                        throw;
                    }

                    return 1;
                }));

        Assert.Equal(0.05, ex.Seconds, 12);
        // Give the cooperative cancellation a moment to propagate.
        await Task.Delay(50);
        Assert.True(observedCancellation);
    }

    [Fact]
    public async Task NonPositiveDeadline_RunsWithoutTimer()
    {
        int result = await MemoryExtractionDeadline.WithThrowingDeadlineAsync(
            seconds: 0,
            operation: _ => Task.FromResult(7));
        Assert.Equal(7, result);
    }

    [Fact]
    public async Task OperationThrows_PropagatesItsException()
    {
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            MemoryExtractionDeadline.WithThrowingDeadlineAsync<int>(
                seconds: 5,
                operation: _ => throw new InvalidOperationException("boom")));
    }
}
