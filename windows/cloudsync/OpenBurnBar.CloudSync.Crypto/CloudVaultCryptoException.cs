using System;

namespace OpenBurnBar.CloudSync.Crypto
{
    /// <summary>
    /// The failure modes of the CloudVault crypto, mirroring the Swift
    /// <c>CloudVaultCryptoError</c> cases. Every one is a fail-closed refusal —
    /// an invalid envelope, a tag / KDF / AAD mismatch, a bad key length, or a
    /// malformed public key throws rather than returning partial or plaintext.
    /// </summary>
    public enum CloudVaultCryptoErrorCode
    {
        InvalidKeyLength,
        SealedBoxUnavailable,
        InvalidEnvelope,
        InvalidPublicKey,
    }

    /// <summary>
    /// Thrown by every CloudVault crypto operation on any integrity, format, or
    /// key failure. Carries the <see cref="Code"/> so callers can distinguish a
    /// malformed envelope from a wrong key length without string matching.
    /// </summary>
    public sealed class CloudVaultCryptoException : Exception
    {
        public CloudVaultCryptoErrorCode Code { get; }

        public CloudVaultCryptoException(CloudVaultCryptoErrorCode code, string message)
            : base(message)
        {
            Code = code;
        }

        public CloudVaultCryptoException(CloudVaultCryptoErrorCode code, string message, Exception inner)
            : base(message, inner)
        {
            Code = code;
        }

        internal static CloudVaultCryptoException InvalidKeyLength() =>
            new(CloudVaultCryptoErrorCode.InvalidKeyLength, "Cloud vault keys must be 32 bytes.");

        internal static CloudVaultCryptoException InvalidEnvelope() =>
            new(CloudVaultCryptoErrorCode.InvalidEnvelope, "The encrypted cloud vault envelope is invalid.");

        internal static CloudVaultCryptoException InvalidEnvelope(Exception inner) =>
            new(CloudVaultCryptoErrorCode.InvalidEnvelope, "The encrypted cloud vault envelope is invalid.", inner);

        internal static CloudVaultCryptoException InvalidPublicKey() =>
            new(CloudVaultCryptoErrorCode.InvalidPublicKey, "The device public key is invalid.");
    }
}
