namespace OpenBurnBar.CloudSync.AppCheck.Verifier.Windows;

internal static class TpmVerificationInputValidator
{
    private const int MaxClaimBytes = 64 * 1024;
    private const int EcdsaP256PublicBlobBytes = 72;

    internal static bool TryValidate(
        TpmVerificationRequest input,
        string expectedAppId,
        out byte[] publicKey,
        out byte[] platformClaim)
    {
        publicKey = Array.Empty<byte>();
        platformClaim = Array.Empty<byte>();
        if (
            input.Version != 1 ||
            input.AppId != expectedAppId ||
            string.IsNullOrWhiteSpace(input.Uid) || input.Uid.Length > 256 ||
            string.IsNullOrWhiteSpace(input.ChallengeId) || input.ChallengeId.Length is < 16 or > 256 ||
            string.IsNullOrWhiteSpace(input.Nonce) || input.Nonce.Length is < 16 or > 256 ||
            input.IssuedAtMs <= 0 ||
            string.IsNullOrWhiteSpace(input.PlatformClaim) ||
            string.IsNullOrWhiteSpace(input.SubjectPublicKey))
        {
            return false;
        }

        try
        {
            publicKey = Convert.FromBase64String(input.SubjectPublicKey);
            platformClaim = Convert.FromBase64String(input.PlatformClaim);
            return publicKey.Length == EcdsaP256PublicBlobBytes &&
                platformClaim.Length is > 0 and <= MaxClaimBytes;
        }
        catch (FormatException)
        {
            return false;
        }
    }
}

internal sealed record TpmVerificationRequest(
    int Version,
    string Uid,
    string AppId,
    string ChallengeId,
    string Nonce,
    long IssuedAtMs,
    string PlatformClaim,
    string SubjectPublicKey);
