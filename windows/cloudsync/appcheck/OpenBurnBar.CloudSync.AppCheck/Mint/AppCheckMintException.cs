using System;

namespace OpenBurnBar.CloudSync.AppCheck.Mint;

/// <summary>
/// Why a mint attempt failed. Every value is a FAIL-CLOSED outcome: no App Check
/// token is installed and no outbound request may attach one.
/// </summary>
public enum AppCheckMintFailure
{
    /// <summary>Could not reach the mint endpoint (connection/DNS/TLS fault).</summary>
    Transport,

    /// <summary>The request exceeded its timeout.</summary>
    Timeout,

    /// <summary>The caller could not supply a Firebase ID token to authenticate the mint.</summary>
    MissingIdToken,

    /// <summary>
    /// The server rejected the attestation or the request (HTTP non-2xx, or a
    /// callable <c>error</c> envelope). This includes the production fence: a mock
    /// claim finds no accepting verifier and is denied.
    /// </summary>
    Rejected,

    /// <summary>The response was not the expected callable success envelope.</summary>
    MalformedResponse,

    /// <summary>
    /// The platform attestation producer could not produce a claim (e.g. no TPM,
    /// CNG failure, or not running on Windows). Fail-closed like any other:
    /// no token is minted, no request may proceed on a fresh mint.
    /// </summary>
    AttestationUnavailable,
}

/// <summary>
/// Raised on any failure of the mint pipeline. The pipeline is fail-closed: a
/// thrown <see cref="AppCheckMintException"/> means NO token was installed and the
/// caller must NOT proceed with an App-Check-gated request.
/// </summary>
public sealed class AppCheckMintException : Exception
{
    public AppCheckMintFailure Failure { get; }

    /// <summary>The HTTP status code, when the failure was an HTTP rejection (else null).</summary>
    public int? StatusCode { get; }

    public AppCheckMintException(AppCheckMintFailure failure, string message, int? statusCode = null, Exception? inner = null)
        : base(message, inner)
    {
        Failure = failure;
        StatusCode = statusCode;
    }

    public static AppCheckMintException Transport(string detail, Exception? inner = null) =>
        new(AppCheckMintFailure.Transport, $"App Check mint transport failed: {detail}", inner: inner);

    public static AppCheckMintException Timeout() =>
        new(AppCheckMintFailure.Timeout, "App Check mint request timed out.");

    public static AppCheckMintException MissingIdToken() =>
        new(AppCheckMintFailure.MissingIdToken, "No Firebase ID token available to authenticate the App Check mint.");

    public static AppCheckMintException Rejected(int statusCode, string detail) =>
        new(AppCheckMintFailure.Rejected, $"App Check mint rejected (HTTP {statusCode}): {detail}", statusCode);

    public static AppCheckMintException Malformed(string detail) =>
        new(AppCheckMintFailure.MalformedResponse, $"App Check mint response malformed: {detail}");

    public static AppCheckMintException AttestationUnavailable(string detail, Exception? inner = null) =>
        new(AppCheckMintFailure.AttestationUnavailable, $"Platform attestation unavailable: {detail}", inner: inner);
}
