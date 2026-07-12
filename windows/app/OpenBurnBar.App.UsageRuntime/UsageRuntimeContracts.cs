using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.UsageRuntime;

public interface IUsageRuntime : IAsyncDisposable
{
    event EventHandler<UsageRuntimeStateChangedEventArgs>? StateChanged;

    UsageRuntimeState State { get; }

    Task StartAsync(CancellationToken cancellationToken = default);

    Task ScanAsync(UsageScanReason reason, CancellationToken cancellationToken = default);

    Task StopAsync(CancellationToken cancellationToken = default);
}

public enum UsageScanReason
{
    Startup,
    Manual,
    FileChanged,
    Periodic,
}

public enum UsageRuntimePhase
{
    NotStarted,
    Scanning,
    Ready,
    NoData,
    Degraded,
    Unavailable,
    Failed,
    Stopped,
}

public enum UsageRuntimeFailureKind
{
    NativeEngineUnavailable,
    NativeEngineFailure,
    InvalidEngineResponse,
    Storage,
    PathDiscovery,
    Cancelled,
    Unexpected,
}

public sealed record UsageRuntimeSnapshot(
    IReadOnlyList<UsageEngineRecord> Usages,
    IReadOnlyList<UsageEngineConversation> Conversations,
    DateTimeOffset CapturedAt)
{
    public static UsageRuntimeSnapshot Empty { get; } = new(
        Array.Empty<UsageEngineRecord>(),
        Array.Empty<UsageEngineConversation>(),
        DateTimeOffset.MinValue);
}

public sealed record UsageRuntimeState(
    UsageRuntimePhase Phase,
    UsageScanReason? Reason,
    UsageRuntimeSnapshot Snapshot,
    IReadOnlyList<UsageProviderScanResult> Providers,
    DateTimeOffset? LastSuccessfulScan,
    UsageRuntimeFailureKind? FailureKind,
    string StatusMessage)
{
    public static UsageRuntimeState NotStarted { get; } = new(
        UsageRuntimePhase.NotStarted,
        null,
        UsageRuntimeSnapshot.Empty,
        Array.Empty<UsageProviderScanResult>(),
        null,
        null,
        "Usage runtime has not started.");

    public bool IsScanning => Phase == UsageRuntimePhase.Scanning;
}

public sealed class UsageRuntimeStateChangedEventArgs : EventArgs
{
    public UsageRuntimeStateChangedEventArgs(UsageRuntimeState previous, UsageRuntimeState current)
    {
        Previous = previous;
        Current = current;
    }

    public UsageRuntimeState Previous { get; }

    public UsageRuntimeState Current { get; }
}

public sealed class UsageRuntimeException : Exception
{
    public UsageRuntimeException(UsageRuntimeFailureKind kind, string message)
        : base(message)
    {
        Kind = kind;
    }

    public UsageRuntimeException(UsageRuntimeFailureKind kind, string message, Exception innerException)
        : base(message, innerException)
    {
        Kind = kind;
    }

    public UsageRuntimeFailureKind Kind { get; }
}
