using System;

namespace OpenBurnBar.CloudSync.Gateway;

/// <summary>
/// Port of the Swift <c>CloudSyncGatewayError</c> plus the REST/HTTP failure
/// surface. Maps Firestore REST status codes onto the same categories the macOS
/// circuit breaker + backoff policy reason about (<c>permissionDenied</c>,
/// <c>unavailable</c>, <c>notFound</c>).
/// </summary>
public sealed class CloudSyncGatewayException : Exception
{
    public CloudSyncGatewayException(CloudSyncGatewayErrorKind kind, string message, int? httpStatus = null, Exception? inner = null)
        : base(message, inner)
    {
        Kind = kind;
        HttpStatus = httpStatus;
    }

    public CloudSyncGatewayErrorKind Kind { get; }
    public int? HttpStatus { get; }

    public static CloudSyncGatewayException DocumentImplementationMismatch(string expected) =>
        new(CloudSyncGatewayErrorKind.DocumentImplementationMismatch,
            $"Cloud sync gateway document implementation mismatch; expected {expected}.");

    public static CloudSyncGatewayException FromHttpStatus(int status, string body)
    {
        CloudSyncGatewayErrorKind kind = status switch
        {
            401 or 403 => CloudSyncGatewayErrorKind.PermissionDenied,
            404 => CloudSyncGatewayErrorKind.NotFound,
            409 => CloudSyncGatewayErrorKind.Aborted,
            429 => CloudSyncGatewayErrorKind.ResourceExhausted,
            >= 500 => CloudSyncGatewayErrorKind.Unavailable,
            _ => CloudSyncGatewayErrorKind.Unknown,
        };
        return new CloudSyncGatewayException(kind, $"Firestore REST error {status}: {Trim(body)}", status);
    }

    private static string Trim(string body) => body.Length <= 512 ? body : body[..512];
}

public enum CloudSyncGatewayErrorKind
{
    Unknown,
    DocumentImplementationMismatch,
    PermissionDenied,
    NotFound,
    Aborted,
    ResourceExhausted,
    Unavailable,
    /// <summary>An E2EE invariant was violated (fail-closed); the write was refused.</summary>
    E2EEFailClosed,
}
