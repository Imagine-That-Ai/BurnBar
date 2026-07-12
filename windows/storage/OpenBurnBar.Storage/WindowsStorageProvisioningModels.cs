using System;
using System.Collections.Generic;

namespace OpenBurnBar.Storage;

public enum WindowsStorageFailureKind
{
    WrongKey,
    CorruptDatabase,
    LockedFile,
    InterruptedMigration,
    UnsupportedSchema,
    FullDisk,
    AccessDenied,
}

public enum WindowsStorageRecoveryAction
{
    Retry,
    Archive,
    Reset,
    RevealRedactedLog,
}

public sealed record WindowsStorageRecoveryState(
    WindowsStorageFailureKind Kind,
    string Title,
    string Message,
    IReadOnlyList<WindowsStorageRecoveryAction> Actions,
    string DatabasePath,
    string? JournalPath,
    string? RedactedLogPath);

public sealed class WindowsStorageProvisioningException : Exception
{
    public WindowsStorageRecoveryState RecoveryState { get; }

    public WindowsStorageProvisioningException(WindowsStorageRecoveryState recoveryState, Exception? innerException = null)
        : base(recoveryState.Message, innerException)
    {
        RecoveryState = recoveryState;
    }
}

public sealed record WindowsStorageProvisioningReport(
    string DatabasePath,
    string JournalPath,
    string RedactedLogPath,
    string KeyProvenance,
    string PathOwner,
    string CipherVersion,
    string SchemaEndpoint,
    long MigrationCount,
    long UserVersion,
    string SchemaHash,
    bool Created,
    bool RetriedInterruptedMigration);

public enum WindowsStorageProvisioningFaultKind
{
    LockedFile,
    InterruptedMigration,
    FullDisk,
    AccessDenied,
}

public sealed record WindowsStorageProvisioningFault(WindowsStorageProvisioningFaultKind Kind, string? Message = null);

public sealed record WindowsStorageArchiveResult(
    string ArchiveDirectory,
    string ArchivedDatabasePath,
    WindowsStorageProvisioningReport NewDatabase);
