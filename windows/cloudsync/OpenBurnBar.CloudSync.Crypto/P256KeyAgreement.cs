using System;
using Org.BouncyCastle.Asn1.Sec;
using Org.BouncyCastle.Asn1.X9;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Crypto.Agreement;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Math;
using Org.BouncyCastle.Security;

namespace OpenBurnBar.CloudSync.Crypto
{
    /// <summary>
    /// P-256 (secp256r1 / NIST P-256) ECDH key agreement for the escrow key-wrap,
    /// on the pure-managed cross-platform BouncyCastle provider.
    ///
    /// The agreed secret is the 32-byte big-endian X-coordinate of
    /// <c>scalar · peerPoint</c> — byte-for-byte identical to CryptoKit
    /// <c>sharedSecretFromKeyAgreement</c>, WebCrypto <c>deriveBits(ECDH, 256)</c>,
    /// and .NET <c>ECDiffieHellman.DeriveRawSecretAgreement</c> (all three parities
    /// are asserted in the test suite). Public keys are the uncompressed X9.63
    /// encoding <c>0x04 || X(32) || Y(32)</c>. Using BouncyCastle lets the seal
    /// direction pin a deterministic ephemeral scalar for the KAT.
    /// </summary>
    internal static class P256KeyAgreement
    {
        internal const int X963PublicKeyLength = 65;

        private static readonly X9ECParameters Curve = SecNamedCurves.GetByName("secp256r1");
        private static readonly ECDomainParameters Domain =
            new(Curve.Curve, Curve.G, Curve.N, Curve.H);

        /// <summary>Uncompressed X9.63 public key for a raw 32-byte private scalar.</summary>
        internal static byte[] PublicX963FromScalar(byte[] scalar)
        {
            var d = ScalarFromBytes(scalar);
            return Curve.G.Multiply(d).Normalize().GetEncoded(false);
        }

        /// <summary>
        /// The 32-byte big-endian ECDH X-coordinate shared secret between a private
        /// scalar and a peer's uncompressed X9.63 public key.
        /// </summary>
        internal static byte[] SharedSecretX(byte[] privateScalar, byte[] peerX963)
        {
            var peerPoint = DecodePoint(peerX963);
            var agreement = new ECDHBasicAgreement();
            agreement.Init(new ECPrivateKeyParameters(ScalarFromBytes(privateScalar), Domain));
            var z = agreement.CalculateAgreement(new ECPublicKeyParameters(peerPoint, Domain));
            return ToFixedLength(z, 32);
        }

        /// <summary>A fresh, cryptographically-random ephemeral P-256 key pair.</summary>
        internal static (byte[] Scalar, byte[] PublicX963) GenerateEphemeral()
        {
            var generator = new ECKeyPairGenerator();
            generator.Init(new ECKeyGenerationParameters(Domain, new SecureRandom()));
            var pair = generator.GenerateKeyPair();
            var priv = (ECPrivateKeyParameters)pair.Private;
            var pub = (ECPublicKeyParameters)pair.Public;
            return (ToFixedLength(priv.D, 32), pub.Q.Normalize().GetEncoded(false));
        }

        /// <summary>
        /// Validate an uncompressed X9.63 public key (length, 0x04 prefix, and that
        /// the point actually lies on the curve). Throws
        /// <see cref="CloudVaultCryptoException"/> with
        /// <see cref="CloudVaultCryptoErrorCode.InvalidPublicKey"/> otherwise.
        /// </summary>
        internal static void ValidateX963(byte[] x963)
        {
            if (x963.Length != X963PublicKeyLength || x963[0] != 0x04)
            {
                throw CloudVaultCryptoException.InvalidPublicKey();
            }
            _ = DecodePoint(x963);
        }

        private static Org.BouncyCastle.Math.EC.ECPoint DecodePoint(byte[] x963)
        {
            if (x963.Length != X963PublicKeyLength || x963[0] != 0x04)
            {
                throw CloudVaultCryptoException.InvalidPublicKey();
            }
            try
            {
                var point = Curve.Curve.DecodePoint(x963);
                if (!point.IsValid())
                {
                    throw CloudVaultCryptoException.InvalidPublicKey();
                }
                return point;
            }
            catch (CloudVaultCryptoException)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw new CloudVaultCryptoException(
                    CloudVaultCryptoErrorCode.InvalidPublicKey, "The device public key is invalid.", ex);
            }
        }

        private static BigInteger ScalarFromBytes(byte[] scalar)
        {
            var d = new BigInteger(1, scalar);
            if (d.SignValue <= 0 || d.CompareTo(Curve.N) >= 0)
            {
                throw CloudVaultCryptoException.InvalidPublicKey();
            }
            return d;
        }

        private static byte[] ToFixedLength(BigInteger value, int length)
        {
            var raw = value.ToByteArrayUnsigned();
            if (raw.Length == length)
            {
                return raw;
            }
            if (raw.Length > length)
            {
                throw CloudVaultCryptoException.InvalidEnvelope();
            }
            var padded = new byte[length];
            Array.Copy(raw, 0, padded, length - raw.Length, raw.Length);
            return padded;
        }

        private sealed class ECDhBasicAgreementCompat
        {
            private readonly ECDHBasicAgreement _inner = new();

            internal void Init(ICipherParameters parameters) => _inner.Init(parameters);

            internal BigInteger CalculateAgreement(ICipherParameters publicKey) =>
                _inner.CalculateAgreement(publicKey);
        }
    }
}
