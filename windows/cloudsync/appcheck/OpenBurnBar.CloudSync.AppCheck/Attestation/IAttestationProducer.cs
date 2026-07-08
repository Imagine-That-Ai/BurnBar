using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.CloudSync.AppCheck.Attestation;

/// <summary>
/// Produces a fresh <see cref="WindowsAttestationClaim"/> bound to an App Check
/// app id. This is the seam between the portable mint pipeline and the
/// platform-specific proof of a genuine, unmodified app.
/// </summary>
/// <remarks>
/// Two implementations exist:
/// <list type="bullet">
///   <item>
///     <see cref="MockAttestationProducer"/> — portable, deterministic-testable;
///     emits the Phase-0 <c>"mock"</c> claim the server's mock verifier accepts
///     under non-production config. Drives all macOS <c>dotnet test</c> coverage.
///   </item>
///   <item>
///     <c>OpenBurnBar.CloudSync.AppCheck.Windows.TpmAttestationProducer</c> — the
///     REAL TPM CNG <c>NCryptCreateClaim</c> producer. It emits a <c>"tpm"</c>
///     claim that AC-013's server verifier accepts in ALL configs (prod included).
///     It is a <c>net8.0-windows</c> / dev-host adapter: R14/AC-013-deferred, it
///     does not run off-Windows.
///   </item>
/// </list>
/// The producer NEVER weakens the server gate: it only assembles a claim. The
/// server decides whether that claim's kind has a registered verifier and whether
/// the proof holds. A forged/replayed/stale claim is rejected server-side.
/// </remarks>
public interface IAttestationProducer
{
    /// <summary>
    /// The attestation <see cref="WindowsAttestationClaim.Kind"/> this producer
    /// emits (e.g. <c>"mock"</c> or <c>"tpm"</c>). Surfaced so callers can log /
    /// assert which producer is wired without producing a claim.
    /// </summary>
    string Kind { get; }

    /// <summary>
    /// Produce a fresh attestation claim bound to <paramref name="appId"/>, with a
    /// single-use nonce and a client-asserted issue time of <paramref name="nowMillis"/>.
    /// </summary>
    ValueTask<WindowsAttestationClaim> ProduceAsync(
        string appId,
        long nowMillis,
        CancellationToken cancellationToken = default);
}
