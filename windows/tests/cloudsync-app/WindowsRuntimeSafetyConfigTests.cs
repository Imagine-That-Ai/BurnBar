using OpenBurnBar.App.CloudSync.RuntimeSafety;
using Xunit;

namespace OpenBurnBar.App.CloudSync.Tests;

public sealed class WindowsRuntimeSafetyConfigTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_750_000_000);

    [Fact]
    public void SecureDefault_DisablesFeaturesAndActivatesKillSwitches()
    {
        WindowsRuntimeSafetySnapshot snapshot = WindowsRuntimeSafetySnapshot.SecureDefault(Now);

        Assert.False(snapshot.IsResolved);
        Assert.False(snapshot.ComputerUseWatchEnabled);
        Assert.False(snapshot.ComputerUseBrowserEnabled);
        Assert.False(snapshot.ComputerUseSystemEnabled);
        Assert.False(snapshot.ComputerUsePhoneControlEnabled);
        Assert.True(snapshot.ComputerUseKillSwitch);
        Assert.True(snapshot.ComputerUsePhoneControlRespectsDenyRegions);
        Assert.True(snapshot.MediaKillSwitch);
    }

    [Fact]
    public void TryCreate_RequiresEveryFieldAndFreshServerTimestamp()
    {
        WindowsRuntimeSafetyConfigResponse response = ValidResponse() with
        {
            ComputerUseSystemEnabled = null,
        };

        Assert.False(WindowsRuntimeSafetySnapshot.TryCreate(response, Now, out WindowsRuntimeSafetySnapshot invalid));
        Assert.True(invalid.ComputerUseKillSwitch);

        response = ValidResponse() with
        {
            FetchedAtEpochMillis = Now.AddMinutes(-2).ToUnixTimeMilliseconds(),
            MaxAgeSeconds = 60,
        };
        Assert.False(WindowsRuntimeSafetySnapshot.TryCreate(response, Now, out _));
    }

    [Fact]
    public void TryCreate_AcceptsFreshCompleteResponse()
    {
        Assert.True(WindowsRuntimeSafetySnapshot.TryCreate(ValidResponse(), Now, out WindowsRuntimeSafetySnapshot snapshot));

        Assert.True(snapshot.IsResolved);
        Assert.True(snapshot.ComputerUseBrowserEnabled);
        Assert.True(snapshot.ComputerUseSystemEnabled);
        Assert.False(snapshot.ComputerUseKillSwitch);
        Assert.False(snapshot.MediaKillSwitch);
        Assert.True(snapshot.AllowsSystemComputerUse(Now));
    }

    [Fact]
    public async Task Monitor_PublishesSecureDefaultOnFetchFailure()
    {
        var state = new WindowsRuntimeSafetyState();
        var monitor = new WindowsRuntimeSafetyConfigMonitor(
            _ => Task.FromException<WindowsRuntimeSafetyConfigResponse>(new IOException("offline")),
            state,
            new FixedTimeProvider(Now));

        await monitor.RefreshOnceAsync();

        Assert.False(state.Current.IsResolved);
        Assert.True(state.Current.ComputerUseKillSwitch);
        Assert.True(state.Current.MediaKillSwitch);
        await monitor.DisposeAsync();
    }

    [Fact]
    public async Task Monitor_PublishesValidatedResponse()
    {
        var state = new WindowsRuntimeSafetyState();
        var monitor = new WindowsRuntimeSafetyConfigMonitor(
            _ => Task.FromResult(ValidResponse()),
            state,
            new FixedTimeProvider(Now));

        await monitor.RefreshOnceAsync();

        Assert.True(state.Current.IsResolved);
        Assert.True(state.Current.AllowsSystemComputerUse(Now));
        await monitor.DisposeAsync();
    }

    [Fact]
    public async Task Monitor_InvalidatePreventsInflightResponseFromReopeningState()
    {
        var state = new WindowsRuntimeSafetyState();
        var response = new TaskCompletionSource<WindowsRuntimeSafetyConfigResponse>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var monitor = new WindowsRuntimeSafetyConfigMonitor(
            _ => response.Task,
            state,
            new FixedTimeProvider(Now));

        Task refresh = monitor.RefreshOnceAsync();
        monitor.Invalidate();
        response.SetResult(ValidResponse());
        await refresh;

        Assert.False(state.Current.IsResolved);
        Assert.True(state.Current.ComputerUseKillSwitch);
        await monitor.DisposeAsync();
    }

    private static WindowsRuntimeSafetyConfigResponse ValidResponse() => new()
    {
        SchemaVersion = WindowsRuntimeSafetySnapshot.ExpectedSchemaVersion,
        FetchedAtEpochMillis = Now.ToUnixTimeMilliseconds(),
        MaxAgeSeconds = 90,
        ComputerUseWatchEnabled = true,
        ComputerUseBrowserEnabled = true,
        ComputerUseSystemEnabled = true,
        ComputerUsePhoneControlEnabled = true,
        ComputerUsePhoneControlAttestationRequired = true,
        ComputerUseTrustModesEnabled = true,
        ComputerUsePolishEnabled = true,
        ComputerUseKillSwitch = false,
        ComputerUsePhoneControlRespectsDenyRegions = true,
        MediaKillSwitch = false,
    };

    private sealed class FixedTimeProvider(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }
}
