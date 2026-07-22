using System;
using System.Text;

namespace OpenBurnBar.CloudSync.Crypto
{
    /// <summary>
    /// The path-bound Additional Authenticated Data context for a v2 CloudVault
    /// envelope — the C# mirror of Swift <c>CloudVaultAADContext</c> and the TS
    /// <c>CloudVaultAADContext</c>. Binds a ciphertext to its exact
    /// <c>uid | collection | docID | field | schemaVersion | purpose</c> slot so a
    /// backend that can move sealed blobs between schema-equivalent slots cannot
    /// make one open in the wrong place (the AEAD tag fails).
    ///
    /// The canonical serialization is
    /// <c>OpenBurnBar-CloudVault-aad-v2|uid|collection|docID|field|schemaVersion|purpose</c>,
    /// byte-for-byte identical to <see cref="StringValue"/> on every platform.
    /// </summary>
    public sealed class CloudVaultAadContext
    {
        public const string ContextPrefix = "OpenBurnBar-CloudVault-aad-v2";
        public const string LegacyContextPrefix = "OpenBurnBar-CloudVault-aad-v1";

        public string Uid { get; }
        public string Collection { get; }
        public string DocId { get; }
        public string Field { get; }
        public int SchemaVersion { get; }
        public string Purpose { get; }

        public CloudVaultAadContext(
            string uid,
            string collection,
            string docId,
            string field,
            int schemaVersion = 2,
            string? purpose = null)
        {
            var resolvedPurpose = purpose ?? field;
            var stringValue = DomainCoreCloudVaultBridge.AadV2(
                uid,
                collection,
                docId,
                field,
                schemaVersion,
                resolvedPurpose,
                () => LegacyV2(uid, collection, docId, field, schemaVersion, resolvedPurpose));
            var legacyV1StringValue = DomainCoreCloudVaultBridge.AadV1(
                uid,
                collection,
                docId,
                field,
                () => LegacyV1(uid, collection, docId, field));

            Uid = uid;
            Collection = collection;
            DocId = docId;
            Field = field;
            SchemaVersion = schemaVersion;
            Purpose = resolvedPurpose;
            StringValue = stringValue;
            LegacyV1StringValue = legacyV1StringValue;
        }

        /// <summary>The v2 AAD string; the AEAD authenticates exactly these bytes.</summary>
        public string StringValue { get; }

        /// <summary>The weaker legacy v1 AAD string (no schemaVersion/purpose).</summary>
        public string LegacyV1StringValue { get; }

        public byte[] Data => Encoding.UTF8.GetBytes(StringValue);

        public byte[] LegacyV1Data => Encoding.UTF8.GetBytes(LegacyV1StringValue);

        private static string ValidatedPart(string value, string name)
        {
            if (string.IsNullOrEmpty(value))
            {
                throw CloudVaultCryptoException.InvalidEnvelope();
            }
            foreach (var rune in value.EnumerateRunes())
            {
                if (rune.Value < 0x20 || rune.Value == 0x7f || rune.Value == '|')
                {
                    throw CloudVaultCryptoException.InvalidEnvelope();
                }
            }
            return value;
        }

        private static string LegacyV2(
            string uid,
            string collection,
            string docId,
            string field,
            int schemaVersion,
            string purpose)
        {
            var validatedUid = ValidatedPart(uid, nameof(uid));
            var validatedCollection = ValidatedPart(collection, nameof(collection));
            var validatedDocId = ValidatedPart(docId, nameof(docId));
            var validatedField = ValidatedPart(field, nameof(field));
            if (schemaVersion < 2)
            {
                throw CloudVaultCryptoException.InvalidEnvelope();
            }
            var validatedPurpose = ValidatedPart(purpose, nameof(purpose));
            return $"{ContextPrefix}|{validatedUid}|{validatedCollection}|{validatedDocId}|{validatedField}|{schemaVersion}|{validatedPurpose}";
        }

        private static string LegacyV1(string uid, string collection, string docId, string field) =>
            $"{LegacyContextPrefix}|{ValidatedPart(uid, nameof(uid))}|{ValidatedPart(collection, nameof(collection))}|{ValidatedPart(docId, nameof(docId))}|{ValidatedPart(field, nameof(field))}";
    }

    /// <summary>
    /// Post-backfill cutover gate for the weaker v1 (global) AAD path, mirroring
    /// Swift <c>CloudVaultV1AADRejectionFlag</c>. On by default: once every at-rest
    /// record is re-sealed to v2, any envelope still carrying the v1 AAD is refused
    /// (fail closed) rather than silently downgraded.
    /// </summary>
    public static class CloudVaultV1AadRejection
    {
        /// <summary>On by default after the RR-8 cutover.</summary>
        public static bool DefaultEnabled = true;
    }
}
