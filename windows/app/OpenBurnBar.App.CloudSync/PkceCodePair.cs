using System;
using System.Security.Cryptography;
using System.Text;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// A PKCE (RFC 7636) verifier/challenge pair plus an anti-forgery <c>state</c>. The
/// verifier is a high-entropy URL-safe secret held by the client; the challenge is
/// <c>BASE64URL(SHA256(verifier))</c> and travels in the authorization URL. Only the
/// holder of the verifier can redeem the code at the token endpoint, so a public
/// (secret-less) desktop client stays safe from code-interception.
/// </summary>
public sealed class PkceCodePair
{
    public string CodeVerifier { get; }
    public string CodeChallenge { get; }
    public string State { get; }

    public const string ChallengeMethod = "S256";

    private PkceCodePair(string verifier, string challenge, string state)
    {
        CodeVerifier = verifier;
        CodeChallenge = challenge;
        State = state;
    }

    /// <summary>Generate a fresh verifier (96 bytes → 128 base64url chars), its S256 challenge, and a random state.</summary>
    public static PkceCodePair Generate()
    {
        string verifier = Base64Url(RandomNumberGenerator.GetBytes(96));
        string challenge = ChallengeFor(verifier);
        string state = Base64Url(RandomNumberGenerator.GetBytes(32));
        return new PkceCodePair(verifier, challenge, state);
    }

    /// <summary>Compute the S256 challenge for a given verifier (exposed for parity tests).</summary>
    public static string ChallengeFor(string verifier)
    {
        byte[] hash = SHA256.HashData(Encoding.ASCII.GetBytes(verifier));
        return Base64Url(hash);
    }

    private static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
