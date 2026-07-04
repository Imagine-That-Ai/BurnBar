using System;
using System.Security.Cryptography;

namespace OpenBurnBar.CloudSync.Crypto
{
    /// <summary>
    /// AES-256-GCM in the exact wire shape CryptoKit / WebCrypto produce:
    /// the "combined" box is <c>nonce(12) || ciphertext || tag(16)</c>, and the
    /// "detached" form exposes the three parts separately (used by the sealed-text
    /// envelope). The 16-byte (128-bit) tag length is pinned to match
    /// <c>AES.GCM</c>. Opening is fail-closed: any authentication-tag mismatch
    /// throws <see cref="CloudVaultCryptoException"/> with
    /// <see cref="CloudVaultCryptoErrorCode.InvalidEnvelope"/> — never a partial or
    /// unauthenticated plaintext.
    /// </summary>
    internal static class AesGcmBox
    {
        internal const int NonceLength = 12;
        internal const int TagLength = 16;

        internal static (byte[] Nonce, byte[] Ciphertext, byte[] Tag, byte[] Combined) SealDetached(
            byte[] plaintext, byte[] key, byte[] aad, byte[]? nonce)
        {
            var n = nonce ?? RandomNumberGenerator.GetBytes(NonceLength);
            if (n.Length != NonceLength)
            {
                throw CloudVaultCryptoException.InvalidEnvelope();
            }
            var ciphertext = new byte[plaintext.Length];
            var tag = new byte[TagLength];
            using (var gcm = new AesGcm(key, TagLength))
            {
                gcm.Encrypt(n, plaintext, ciphertext, tag, aad);
            }
            var combined = new byte[NonceLength + ciphertext.Length + TagLength];
            Buffer.BlockCopy(n, 0, combined, 0, NonceLength);
            Buffer.BlockCopy(ciphertext, 0, combined, NonceLength, ciphertext.Length);
            Buffer.BlockCopy(tag, 0, combined, NonceLength + ciphertext.Length, TagLength);
            return (n, ciphertext, tag, combined);
        }

        internal static byte[] SealCombined(byte[] plaintext, byte[] key, byte[] aad, byte[]? nonce) =>
            SealDetached(plaintext, key, aad, nonce).Combined;

        internal static byte[] OpenDetached(byte[] nonce, byte[] ciphertext, byte[] tag, byte[] key, byte[] aad)
        {
            if (nonce.Length != NonceLength || tag.Length != TagLength)
            {
                throw CloudVaultCryptoException.InvalidEnvelope();
            }
            var plaintext = new byte[ciphertext.Length];
            try
            {
                using var gcm = new AesGcm(key, TagLength);
                gcm.Decrypt(nonce, ciphertext, tag, plaintext, aad);
            }
            catch (CryptographicException ex)
            {
                throw CloudVaultCryptoException.InvalidEnvelope(ex);
            }
            catch (ArgumentException ex)
            {
                throw CloudVaultCryptoException.InvalidEnvelope(ex);
            }
            return plaintext;
        }

        internal static byte[] OpenCombined(byte[] combined, byte[] key, byte[] aad)
        {
            if (combined.Length < NonceLength + TagLength)
            {
                throw CloudVaultCryptoException.InvalidEnvelope();
            }
            var nonce = new byte[NonceLength];
            var tag = new byte[TagLength];
            var ciphertext = new byte[combined.Length - NonceLength - TagLength];
            Buffer.BlockCopy(combined, 0, nonce, 0, NonceLength);
            Buffer.BlockCopy(combined, NonceLength, ciphertext, 0, ciphertext.Length);
            Buffer.BlockCopy(combined, NonceLength + ciphertext.Length, tag, 0, TagLength);
            return OpenDetached(nonce, ciphertext, tag, key, aad);
        }
    }
}
