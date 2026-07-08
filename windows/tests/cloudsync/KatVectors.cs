using System;
using System.IO;
using System.Text.Json;

namespace OpenBurnBar.CloudSync.Crypto.Tests
{
    /// <summary>
    /// Loads the committed Apple-CryptoKit-origin KAT vector
    /// (Fixtures/cloudvault-kat-vectors.json) and exposes small hex/base64 helpers.
    /// The file is copied next to the test assembly at build time.
    /// </summary>
    internal static class KatVectors
    {
        private static readonly Lazy<JsonDocument> Document = new(Load);

        internal static JsonElement Root => Document.Value.RootElement;

        internal static JsonElement Section(string name) => Root.GetProperty(name);

        private static JsonDocument Load()
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "cloudvault-kat-vectors.json");
            if (!File.Exists(path))
            {
                throw new FileNotFoundException($"KAT vector not found next to the test assembly: {path}");
            }
            return JsonDocument.Parse(File.ReadAllBytes(path));
        }

        internal static byte[] Hex(this JsonElement element, string property) =>
            HexToBytes(element.GetProperty(property).GetString()!);

        internal static byte[] Base64(this JsonElement element, string property) =>
            Convert.FromBase64String(element.GetProperty(property).GetString()!);

        internal static string Str(this JsonElement element, string property) =>
            element.GetProperty(property).GetString()!;

        internal static int Int(this JsonElement element, string property) =>
            element.GetProperty(property).GetInt32();

        internal static byte[] HexToBytes(string hex)
        {
            var bytes = new byte[hex.Length / 2];
            for (var i = 0; i < bytes.Length; i++)
            {
                bytes[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
            }
            return bytes;
        }

        internal static string ToHex(byte[] bytes)
        {
            var chars = new char[bytes.Length * 2];
            for (var i = 0; i < bytes.Length; i++)
            {
                var b = bytes[i];
                chars[i * 2] = (char)(b >> 4 < 10 ? '0' + (b >> 4) : 'a' + (b >> 4) - 10);
                chars[i * 2 + 1] = (char)((b & 0xf) < 10 ? '0' + (b & 0xf) : 'a' + (b & 0xf) - 10);
            }
            return new string(chars);
        }

        /// <summary>Build the AAD context declared under a vector's "aadContext" key.</summary>
        internal static CloudVaultAadContext AadContext(this JsonElement vector)
        {
            var ctx = vector.GetProperty("aadContext");
            return new CloudVaultAadContext(
                uid: ctx.Str("uid"),
                collection: ctx.Str("collection"),
                docId: ctx.Str("docID"),
                field: ctx.Str("field"),
                schemaVersion: ctx.Int("schemaVersion"),
                purpose: ctx.Str("purpose"));
        }

        internal static bool Has(this JsonElement element, string property) =>
            element.TryGetProperty(property, out _);

        internal static CloudVaultSealedText SealedText(JsonElement envelope) =>
            new(
                SchemaVersion: envelope.Has("schemaVersion") ? envelope.Int("schemaVersion") : (int?)null,
                Algorithm: envelope.Str("algorithm"),
                KeyVersion: envelope.Int("keyVersion"),
                Nonce: envelope.Str("nonce"),
                Ciphertext: envelope.Str("ciphertext"),
                Tag: envelope.Str("tag"),
                Aad: envelope.Has("aad") ? envelope.Str("aad") : null);

        internal static CloudVaultBlobEnvelope BlobEnvelope(JsonElement envelope) =>
            new(
                SchemaVersion: envelope.Int("schemaVersion"),
                Algorithm: envelope.Str("algorithm"),
                KeyVersion: envelope.Int("keyVersion"),
                PlaintextSha256: envelope.Has("plaintextSHA256") ? envelope.Str("plaintextSHA256") : null,
                PlaintextHmac: envelope.Has("plaintextHMAC") ? envelope.Str("plaintextHMAC") : null,
                IntegrityHashVersion: envelope.Has("integrityHashVersion") ? envelope.Int("integrityHashVersion") : (int?)null,
                SealedBoxBase64: envelope.Str("sealedBoxBase64"),
                Aad: envelope.Has("aad") ? envelope.Str("aad") : null);

        internal static CloudVaultSealedPayload PayloadEnvelope(JsonElement envelope) =>
            new(
                SchemaVersion: envelope.Int("schemaVersion"),
                Algorithm: envelope.Str("algorithm"),
                KeyVersion: envelope.Int("keyVersion"),
                VaultKeyId: envelope.Str("vaultKeyID"),
                SealedBoxBase64: envelope.Str("sealedBoxBase64"),
                Aad: envelope.Has("aad") ? envelope.Str("aad") : null);
    }
}
